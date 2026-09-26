import Foundation

/// Each function inherits its caller's directory and restores it when the function returns.
struct Runner {
    let configuration: Configuration

    func runEntryPoint(
        _ name: String, arguments: [String], directory: inout URL, environment: inout [String: String]
    ) throws {
        let initialEnvironment = environment
        defer { environment = initialEnvironment }
        var secrets = Set(configuration.settings.map(\.value).filter { !$0.isEmpty })
        guard let function = configuration.entryPoints[name] else { throw CommandError("Unknown function '\(name)'.") }
        let bindings = try bindArguments(arguments, function: function)
        if function.requireAnyOption && !function.options.keys.contains(where: { bindings[$0] == "true" }) {
            printFunctionHelp(name, function: function)
            return
        }
        do {
            try run(name, arguments: arguments, directory: &directory, environment: &environment, secrets: &secrets)
        } catch let error as CommandError {
            throw CommandError(redact(error.description, secrets: secrets), status: error.status)
        }
    }

    private func bindArguments(_ arguments: [String], function: FunctionDefinition) throws -> [String: String] {
        var bindings = Dictionary(uniqueKeysWithValues: function.options.keys.map { ($0, "false") })
        var positional: [String] = []
        var parseOptions = !function.options.isEmpty
        for argument in arguments {
            if parseOptions && argument == "--" {
                parseOptions = false
            } else if parseOptions && argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                guard function.options[name] != nil else {
                    throw CommandError("Unknown function option '\(argument)'.")
                }
                bindings[name] = "true"
            } else {
                positional.append(argument)
            }
        }
        try requireArguments(positional, count: function.parameters.count, target: "Function")
        bindings.merge(
            Dictionary(uniqueKeysWithValues: zip(function.parameters, positional)), uniquingKeysWith: { _, new in new })
        return bindings
    }

    private func run(
        _ name: String, arguments: [String], directory: inout URL, environment: inout [String: String],
        secrets: inout Set<String>
    ) throws {
        guard let function = configuration.definitions[name] else { throw CommandError("Unknown function '\(name)'.") }
        var functionDirectory = directory
        var values = try bindArguments(arguments, function: function)
            .merging(settingValues(for: function), uniquingKeysWith: { _, setting in setting }).mapValues(
                RuntimeValue.string)
        for (index, step) in function.steps.enumerated() {
            do {
                guard try step.when?.evaluate(values) ?? true else { continue }
                let args = try step.args.flatMap { try $0.render(values) }
                try validateProcessArguments(args)
                let result = try execute(
                    step, arguments: args, values: values, directory: &functionDirectory, environment: &environment,
                    secrets: &secrets)
                if let output = step.saveAs, let result {
                    values[output] = result
                    if step.sensitive { secrets.formUnion(result.secretStrings.filter { !$0.isEmpty }) }
                }
            } catch {
                let status = (error as? CommandError)?.status ?? 1
                let context = step.label.map { " (\($0))" } ?? ""
                throw CommandError("\(name), step \(index + 1)\(context): \(error)", status: status)
            }
        }
    }

    private func settingValues(for function: FunctionDefinition) -> [String: String] {
        let values = Dictionary(uniqueKeysWithValues: configuration.settings.map { ($0.name, $0.value) })
        return Dictionary(uniqueKeysWithValues: function.settings.map { ($0, values[$0]!) })
    }

    private func execute(
        _ step: Step, arguments: [String], values: [String: RuntimeValue], directory: inout URL,
        environment: inout [String: String], secrets: inout Set<String>
    ) throws -> RuntimeValue? {
        switch step.target {
        case .command(let executable):
            return try CommandExecutor().execute(
                executable, arguments: arguments, capture: step.capture, directory: directory, environment: environment,
                secrets: secrets)
        case .function(let name):
            try run(name, arguments: arguments, directory: &directory, environment: &environment, secrets: &secrets)
            return nil
        case .builtin(let name):
            guard let builtin = Builtin(rawValue: name) else { throw CommandError("Unknown builtin '\(name)'.") }
            return try BuiltinExecutor().execute(
                builtin, arguments: arguments, values: values, directory: &directory, environment: &environment,
                secrets: secrets)
        }
    }
}
