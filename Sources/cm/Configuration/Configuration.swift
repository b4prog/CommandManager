import Foundation

func isIdentifier(_ value: String) -> Bool {
    value.range(of: "\\A[A-Za-z_][A-Za-z0-9_]*\\z", options: .regularExpression) != nil
}

func isFunctionName(_ value: String) -> Bool {
    value.range(of: "\\A[A-Za-z_][A-Za-z0-9_-]*\\z", options: .regularExpression) != nil
}

struct FunctionDefinition: Decodable {
    let description: String
    let parameters: [String]
    let settings: [String]
    let steps: [Step]
    let options: [String: String]
    let requireAnyOption: Bool

    enum CodingKeys: String, CodingKey {
        case description, parameters, settings, steps, options, requireAnyOption
    }

    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: JSONKey.self)
        if keys.allKeys.contains(where: { $0.stringValue == "entryPoint" }) {
            throw CommandError(
                "The entryPoint field is no longer supported. Move public definitions into entryPoints and keep internal helpers in functions."
            )
        }
        try rejectUnknownKeys(
            decoder,
            allowed: ["description", "parameters", "settings", "steps", "options", "requireAnyOption"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decode(String.self, forKey: .description)
        parameters = try container.decodeIfDefined([String].self, forKey: .parameters) ?? []
        settings = try container.decodeIfDefined([String].self, forKey: .settings) ?? []
        steps = try container.decode([Step].self, forKey: .steps)
        options = try container.decodeIfDefined([String: String].self, forKey: .options) ?? [:]
        requireAnyOption = try container.decodeIfDefined(Bool.self, forKey: .requireAnyOption) ?? false
    }

    var usage: String {
        (parameters.map { "<\($0)>" } + options.keys.sorted().map { "[--\($0)]" }).joined(separator: " ")
    }
}

struct SettingDefinition: Decodable {
    let name: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case name, value
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["name", "value"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
    }
}

struct Configuration: Decodable {
    let settings: [SettingDefinition]
    let entryPoints: [String: FunctionDefinition]
    let functions: [String: FunctionDefinition]
    let definitions: [String: FunctionDefinition]

    enum CodingKeys: String, CodingKey {
        case minimumVersion, settings, entryPoints, functions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try validateMinimumVersion(container.decodeIfDefined(String.self, forKey: .minimumVersion))
        try rejectUnknownKeys(decoder, allowed: ["minimumVersion", "settings", "entryPoints", "functions"])
        settings = try container.decodeIfDefined([SettingDefinition].self, forKey: .settings) ?? []
        entryPoints = try container.decodeIfDefined([String: FunctionDefinition].self, forKey: .entryPoints) ?? [:]
        functions = try container.decodeIfDefined([String: FunctionDefinition].self, forKey: .functions) ?? [:]
        let duplicates = Set(entryPoints.keys).intersection(functions.keys).sorted()
        guard duplicates.isEmpty else {
            throw CommandError(
                "Names must be unique across entryPoints and functions; duplicates: \(duplicates.joined(separator: ", "))."
            )
        }
        definitions = entryPoints.merging(functions, uniquingKeysWith: { entry, _ in entry })
    }

    func validate() throws {
        try validateSettings()
        for name in definitions.keys.sorted() {
            guard let function = definitions[name] else { continue }
            try validateDefinition(name, function: function)
            try validateSteps(name, function: function)
        }
        var visited = Set<String>()
        for name in definitions.keys.sorted() {
            try validateCycles(name, path: [], visited: &visited)
        }
    }

    private func validateSettings() throws {
        let names = settings.map(\.name)
        guard names.allSatisfy(isIdentifier), Set(names).count == names.count else {
            throw CommandError(
                "Settings must have unique names using letters, digits, and underscores, starting with a letter or underscore."
            )
        }
        try validateProcessArguments(settings.map(\.value))
    }

    private func validateDefinition(_ name: String, function: FunctionDefinition) throws {
        guard isFunctionName(name) else {
            throw CommandError(
                "Invalid function name '\(name)'; use letters, digits, underscores, and hyphens, starting with a letter or underscore."
            )
        }
        guard !function.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError("Function '\(name)' must have a nonempty description.")
        }
        guard function.parameters.allSatisfy(isIdentifier),
            Set(function.parameters).count == function.parameters.count
        else {
            throw CommandError(
                "Function '\(name)' must have unique parameter names using letters, digits, and underscores, starting with a letter or underscore."
            )
        }
        guard function.settings.allSatisfy(isIdentifier), Set(function.settings).count == function.settings.count else {
            throw CommandError(
                "Function '\(name)' must have unique setting names using letters, digits, and underscores, starting with a letter or underscore."
            )
        }
        guard Set(function.parameters).isDisjoint(with: function.settings) else {
            throw CommandError("Function '\(name)' cannot use the same name for a parameter and a setting.")
        }
        let definedSettings = Set(settings.map(\.name))
        guard Set(function.settings).isSubset(of: definedSettings) else {
            let unknown = Set(function.settings).subtracting(definedSettings).sorted().joined(separator: ", ")
            throw CommandError("Function '\(name)' uses unknown setting(s): \(unknown).")
        }
    }

    private func validateSteps(_ name: String, function: FunctionDefinition) throws {
        var names = Set(function.parameters + function.settings)
        for option in function.options.keys {
            guard isFunctionName(option), !names.contains(option) else {
                throw CommandError("Invalid or conflicting option '\(option)' in '\(name)'.")
            }
            names.insert(option)
        }
        guard !function.requireAnyOption || !function.options.isEmpty else {
            throw CommandError("requireAnyOption needs declared options in '\(name)'.")
        }
        for (index, step) in function.steps.enumerated() {
            do {
                try validateTarget(step)
                try step.when?.validate(names)
                for argument in step.args { try argument.validate(names) }
                if case .builtin("jsonGet") = step.target {
                    guard let source = step.args.first?.literal, names.contains(source) else {
                        throw CommandError("jsonGet requires a previously defined variable name as its first argument.")
                    }
                }
                if let output = step.saveAs {
                    guard isIdentifier(output), !names.contains(output) else {
                        throw CommandError("Output '\(output)' must be a unique local identifier.")
                    }
                    names.insert(output)
                }
            } catch {
                throw CommandError("Function '\(name)', step \(index + 1): \(error)")
            }
        }
    }

    private func validateTarget(_ step: Step) throws {
        switch step.target {
        case .command(let executable):
            try validateProcessArguments([executable])
            guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CommandError("Command executable must not be empty.")
            }
            guard (step.capture != nil) == (step.saveAs != nil) else {
                throw CommandError("Command capture and saveAs must be specified together.")
            }
        case .function(let name):
            guard let function = definitions[name] else { throw CommandError("Unknown function '\(name)'.") }
            guard step.capture == nil, step.saveAs == nil else {
                throw CommandError("Function calls cannot capture output or use saveAs.")
            }
            if function.options.isEmpty, step.args.allSatisfy({ $0.literal != nil }) {
                try requireArguments(
                    step.args.compactMap(\.literal), count: function.parameters.count, target: "Function '\(name)'")
            }
        case .builtin(let name): try validateBuiltinStep(step, name: name)
        }
        guard !step.sensitive || step.saveAs != nil else {
            throw CommandError("sensitive requires a saved result.")
        }
        if let label = step.label {
            try validateProcessArguments([label])
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CommandError("Step label must not be empty.")
            }
        }
    }

    private func validateBuiltinStep(_ step: Step, name: String) throws {
        guard let builtin = Builtin(rawValue: name) else {
            throw CommandError(
                "Unknown builtin '\(name)'. Available: \(Builtin.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard step.capture == nil, builtin.returnsValue == (step.saveAs != nil) else {
            throw CommandError(
                "Builtin '\(name)' \(builtin.returnsValue ? "requires" : "does not accept") saveAs; capture is only for commands."
            )
        }
        guard step.args.allSatisfy({ $0.literal != nil }) else {
            throw CommandError("Array expansion is supported only for commands and function calls.")
        }
        try builtin.validateCount(step.args.compactMap(\.literal))
    }

    private func validateCycles(_ name: String, path: [String], visited: inout Set<String>) throws {
        guard !path.contains(name) else {
            throw CommandError("Function call cycle: \((path + [name]).joined(separator: " -> ")).")
        }
        guard !visited.contains(name), let function = definitions[name] else { return }
        for step in function.steps {
            if case .function(let callee) = step.target {
                try validateCycles(callee, path: path + [name], visited: &visited)
            }
        }
        visited.insert(name)
    }
}
