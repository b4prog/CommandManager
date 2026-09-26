import Foundation

struct Options {
    var configPath: String?
    var help = false
    var function: String?
    var arguments: [String] = []

    init(_ arguments: [String]) throws {
        var remaining = ArraySlice(arguments)
        while let option = remaining.popFirst() {
            switch option {
            case "--config":
                guard configPath == nil, let path = remaining.popFirst(), !path.isEmpty else {
                    throw CommandError("Use --config once, followed by a configuration file path.")
                }
                configPath = path
            case "--help", "-h":
                help = true
            default:
                guard !option.hasPrefix("-") else {
                    throw CommandError("Unknown option '\(option)'. Use cm --help.")
                }
                function = option
                self.arguments = Array(remaining)
                return
            }
        }
    }
}

func printHelp(_ configuration: Configuration?, path: URL) {
    print(
        """
        CommandManager \(commandManagerVersion) — run named command sequences

        Usage: cm [--config path] [--help|-h] [function [arguments...]]
        Configuration: \(path.path)

        Entry points:
        """)
    let entries = configuration?.functions.filter { $0.value.entryPoint } ?? [:]
    for name in entries.keys.sorted() {
        guard let function = entries[name] else { continue }
        print("  \(name)\(function.usage.isEmpty ? "" : " " + function.usage) — \(function.description)")
    }
    if entries.isEmpty { print("  No entry points configured. Set entryPoint to true to expose a function.") }
    print("\nUse cm --help <function> for function help. Options precede the function name.")
}

func printFunctionHelp(_ name: String, function: FunctionDefinition) {
    print("Usage: cm \(name)\(function.usage.isEmpty ? "" : " " + function.usage)")
    print(function.description)
    for name in function.options.keys.sorted() {
        print("  --\(name)  \(function.options[name]!)")
    }
}

func main(_ arguments: [String]) throws {
    let options = try Options(arguments)
    let path = try configurationURL(options.configPath)
    if !FileManager.default.fileExists(atPath: path.path), options.configPath == nil {
        try handleMissingConfiguration(options, path: path)
        return
    }
    let configuration = try loadConfiguration(at: path)
    guard let name = options.function else {
        printHelp(configuration, path: path)
        return
    }
    guard let function = configuration.functions[name] else {
        throw CommandError("Unknown function '\(name)'. Run cm to list entry points.")
    }
    guard function.entryPoint else {
        throw CommandError("Function '\(name)' is internal; only entry points can be run directly.")
    }
    if options.help {
        printFunctionHelp(name, function: function)
        return
    }
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var environment = ProcessInfo.processInfo.environment
    try Runner(configuration: configuration).runEntryPoint(
        name, arguments: options.arguments, directory: &directory, environment: &environment)
}

func handleMissingConfiguration(_ options: Options, path: URL) throws {
    guard options.function == nil else {
        throw CommandError(
            "Configuration file not found: \(path.path). Create it from examples/cm.json; run cm --help for usage.")
    }
    printHelp(nil, path: path)
    print("\nConfiguration file not found. Create the directory and copy examples/cm.json here to get started.")
}
