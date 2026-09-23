#!/usr/bin/env swift
import Darwin
import Foundation

let commandManagerVersion = "0.2"

struct CommandError: Error, CustomStringConvertible {
    let description: String
    let status: Int32

    init(_ message: String, status: Int32 = 1) {
        description = message
        self.status = status
    }
}

struct Version: Comparable {
    private let components: [UInt]

    init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt($0) }
        guard text.range(of: "\\A[0-9]+\\.[0-9]+(?:\\.[0-9]+)?\\z", options: .regularExpression) != nil,
            numbers.count == parts.count
        else {
            throw CommandError(
                "Invalid version '\(text)'; expected major.minor or major.minor.patch using nonnegative integers.")
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

func validateMinimumVersion(_ minimum: String?) throws {
    guard let minimum else { return }
    guard try Version(commandManagerVersion) >= Version(minimum) else {
        throw CommandError(
            "This configuration requires CommandManager \(minimum) or later; installed version is \(commandManagerVersion). Upgrade cm before using this configuration."
        )
    }
}

struct JSONKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

extension KeyedDecodingContainer {
    func decodeIfDefined<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}

func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: JSONKey.self)
    let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        let location = decoder.codingPath.map(\.stringValue).joined(separator: ".")
        throw CommandError(
            "Unknown JSON field(s) at \(location.isEmpty ? "root" : location): \(unknown.sorted().joined(separator: ", "))."
        )
    }
}

func isIdentifier(_ value: String) -> Bool {
    value.range(of: "\\A[A-Za-z_][A-Za-z0-9_]*\\z", options: .regularExpression) != nil
}

func isFunctionName(_ value: String) -> Bool {
    value.range(of: "\\A[A-Za-z_][A-Za-z0-9_-]*\\z", options: .regularExpression) != nil
}

struct FunctionDefinition: Decodable {
    let description: String
    let entryPoint: Bool
    let parameters: [String]
    let steps: [Step]

    enum CodingKeys: String, CodingKey {
        case description, entryPoint, parameters, steps
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["description", "entryPoint", "parameters", "steps"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decode(String.self, forKey: .description)
        entryPoint = try container.decodeIfDefined(Bool.self, forKey: .entryPoint) ?? false
        parameters = try container.decodeIfDefined([String].self, forKey: .parameters) ?? []
        steps = try container.decode([Step].self, forKey: .steps)
    }

    var usage: String {
        parameters.map { "<\($0)>" }.joined(separator: " ")
    }
}

struct Step: Decodable {
    enum Target {
        case command(String)
        case function(String)
        case builtin(String)
    }

    let target: Target
    let args: [String]

    enum CodingKeys: String, CodingKey {
        case command, function, builtin, args
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["command", "function", "builtin", "args"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let targets: [Target] = try [
            container.decodeIfDefined(String.self, forKey: .command).map(Target.command),
            container.decodeIfDefined(String.self, forKey: .function).map(Target.function),
            container.decodeIfDefined(String.self, forKey: .builtin).map(Target.builtin),
        ].compactMap { $0 }
        guard targets.count == 1, let target = targets.first else {
            throw CommandError("Each step must specify exactly one of command, function, or builtin.")
        }
        self.target = target
        args = try container.decodeIfDefined([String].self, forKey: .args) ?? []
    }
}

enum Builtin: String, CaseIterable {
    case inFolder
    case assertGitRoot
    case assertGitRepository

    var argumentCount: Int {
        self == .inFolder ? 1 : 0
    }
}

/// Arguments are templates, never shell programs. Inserted values are not parsed again.
struct ArgumentTemplate {
    enum Part {
        case text(String)
        case parameter(String)
    }

    private var parts: [Part] = []

    init(_ source: String) throws {
        var remaining = source[...]
        while let dollar = remaining.firstIndex(of: "$") {
            parts.append(.text(String(remaining[..<dollar])))
            remaining = remaining[remaining.index(after: dollar)...]
            try consumeDollar(from: &remaining)
        }
        parts.append(.text(String(remaining)))
    }

    private mutating func consumeDollar(from remaining: inout Substring) throws {
        switch remaining.first {
        case "$":
            remaining.removeFirst()
            parts.append(.text("$"))
        case "{":
            remaining.removeFirst()
            guard let end = remaining.firstIndex(of: "}") else {
                throw CommandError("Unclosed parameter placeholder; expected ${name}.")
            }
            parts.append(.parameter(String(remaining[..<end])))
            remaining = remaining[remaining.index(after: end)...]
        default:
            parts.append(.text("$"))
        }
    }

    func validate(parameters: Set<String>) throws {
        for case .parameter(let name) in parts {
            guard parameters.contains(name) else {
                throw CommandError("Unknown parameter '${\(name)}'. Use $$ to escape a literal dollar sign.")
            }
        }
    }

    func render(values: [String: String]) throws -> String {
        try parts.map { part in
            switch part {
            case .text(let value):
                return value
            case .parameter(let name):
                guard let value = values[name] else {
                    throw CommandError("Missing parameter '\(name)'.")
                }
                return value
            }
        }.joined()
    }
}

struct Configuration: Decodable {
    let functions: [String: FunctionDefinition]

    enum CodingKeys: String, CodingKey {
        case minimumVersion, functions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try validateMinimumVersion(container.decodeIfDefined(String.self, forKey: .minimumVersion))
        try rejectUnknownKeys(decoder, allowed: ["minimumVersion", "functions"])
        functions = try container.decode([String: FunctionDefinition].self, forKey: .functions)
    }

    func validate() throws {
        for name in functions.keys.sorted() {
            guard let function = functions[name] else { continue }
            try validateDefinition(name, function: function)
            try validateSteps(name, function: function)
        }
        var visited = Set<String>()
        for name in functions.keys.sorted() {
            try validateCycles(name, path: [], visited: &visited)
        }
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
    }

    private func validateSteps(_ name: String, function: FunctionDefinition) throws {
        for (index, step) in function.steps.enumerated() {
            do {
                try validateTarget(step)
                for argument in step.args {
                    try ArgumentTemplate(argument).validate(parameters: Set(function.parameters))
                }
            } catch {
                throw CommandError("Function '\(name)', step \(index + 1): \(error)")
            }
        }
    }

    private func validateTarget(_ step: Step) throws {
        try validateProcessArguments(step.args)
        switch step.target {
        case .command(let executable):
            try validateProcessArguments([executable])
            guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CommandError("Command executable must not be empty.")
            }
        case .function(let name):
            guard let function = functions[name] else {
                throw CommandError("Unknown function '\(name)'.")
            }
            try requireArguments(step.args, count: function.parameters.count, target: "Function '\(name)'")
        case .builtin(let name):
            guard let builtin = Builtin(rawValue: name) else {
                throw CommandError(
                    "Unknown builtin '\(name)'. Available: \(Builtin.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            try requireArguments(step.args, count: builtin.argumentCount, target: "Builtin '\(name)'")
        }
    }

    private func validateCycles(_ name: String, path: [String], visited: inout Set<String>) throws {
        guard !path.contains(name) else {
            throw CommandError("Function call cycle: \((path + [name]).joined(separator: " -> ")).")
        }
        guard !visited.contains(name), let function = functions[name] else { return }
        for step in function.steps {
            if case .function(let callee) = step.target {
                try validateCycles(callee, path: path + [name], visited: &visited)
            }
        }
        visited.insert(name)
    }
}

func requireArguments(_ arguments: [String], count: Int, target: String) throws {
    guard arguments.count == count else {
        throw CommandError("\(target) expects \(count) argument(s), received \(arguments.count).")
    }
}

/// All calls share the entry point's directory; the host process never changes cwd.
struct Runner {
    let configuration: Configuration

    func run(_ name: String, arguments: [String], directory: inout URL) throws {
        guard let function = configuration.functions[name] else {
            throw CommandError("Unknown function '\(name)'.")
        }
        try requireArguments(arguments, count: function.parameters.count, target: "Function '\(name)'")
        let values = Dictionary(uniqueKeysWithValues: zip(function.parameters, arguments))
        for (index, step) in function.steps.enumerated() {
            do {
                let args = try step.args.map { try ArgumentTemplate($0).render(values: values) }
                try execute(step.target, arguments: args, directory: &directory)
            } catch let error as CommandError {
                throw CommandError("\(name), step \(index + 1): \(error)", status: error.status)
            }
        }
    }

    private func execute(_ target: Step.Target, arguments: [String], directory: inout URL) throws {
        switch target {
        case .command(let executable):
            try executeCommand(executable, arguments: arguments, directory: directory)
        case .function(let name):
            try run(name, arguments: arguments, directory: &directory)
        case .builtin(let name):
            guard let builtin = Builtin(rawValue: name) else {
                throw CommandError("Unknown builtin '\(name)'.")
            }
            try executeBuiltin(builtin, arguments: arguments, directory: &directory)
        }
    }

    private func executeBuiltin(_ builtin: Builtin, arguments: [String], directory: inout URL) throws {
        switch builtin {
        case .inFolder:
            directory = try folder(named: arguments[0], from: directory)
        case .assertGitRoot:
            try assertGitRepository(directory, requireRoot: true)
        case .assertGitRepository:
            try assertGitRepository(directory, requireRoot: false)
        }
    }

    private func folder(named name: String, from directory: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw CommandError("inFolder requires a single folder name, not a path: '\(name)'.")
        }
        if directory.lastPathComponent == name { return directory }
        let child = directory.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw CommandError(
                "inFolder: '\(name)' is neither the current folder nor a child directory of '\(directory.path)'.")
        }
        return child
    }

    private func executeCommand(_ executable: String, arguments: [String], directory: URL) throws {
        printCommand(executable, arguments: arguments)
        let process = try makeProcess(executable, arguments: arguments, directory: directory)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try start(process, executable: executable)
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let status = exitStatus(process)
            throw CommandError("Command '\(executable)' failed with exit status \(status).", status: status)
        }
    }

    private func assertGitRepository(_ directory: URL, requireRoot: Bool) throws {
        let inside = try gitOutput(["rev-parse", "--is-inside-work-tree"], directory: directory)
        guard inside == "true" else {
            throw CommandError("Expected a Git repository working tree at '\(directory.path)'.")
        }
        guard requireRoot else { return }
        let root = try gitOutput(["rev-parse", "--show-toplevel"], directory: directory)
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        guard rootURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
            throw CommandError(
                "Expected the Git repository root; current folder is '\(directory.path)', root is '\(root)'.")
        }
    }

    private func gitOutput(_ arguments: [String], directory: URL) throws -> String {
        let process = try makeProcess("git", arguments: arguments, directory: directory)
        // Inspect the directory itself, independent of a calling Git hook or alias's repository overrides.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try start(process, executable: "git")
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CommandError("Expected a Git repository working tree at '\(directory.path)'.")
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

func printCommand(_ executable: String, arguments: [String]) {
    let command = ([executable] + arguments).map(quoteArgument).joined(separator: " ")
    FileHandle.standardOutput.write(Data("\u{1B}[90m❯ \u{1B}[32m\(command)\u{1B}[0m\n".utf8))
}

func quoteArgument(_ argument: String) -> String {
    if argument.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
        return "$'" + argument.unicodeScalars.map(quoteControlCharacter).joined() + "'"
    }
    if argument.range(of: "^[A-Za-z0-9_./:@%+=,-]+$", options: .regularExpression) != nil {
        return argument
    }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func quoteControlCharacter(_ character: Unicode.Scalar) -> String {
    switch character.value {
    case 39: return "\\'"
    case 92: return "\\\\"
    case 10: return "\\n"
    case 13: return "\\r"
    case 9: return "\\t"
    case 0...31, 127: return String(format: "\\x%02x", character.value)
    default: return String(character)
    }
}

func exitStatus(_ process: Process) -> Int32 {
    process.terminationReason == .uncaughtSignal ? min(128 + process.terminationStatus, 255) : process.terminationStatus
}

func makeProcess(_ executable: String, arguments: [String], directory: URL) throws -> Process {
    try validateProcessArguments([executable] + arguments)
    let process = Process()
    process.currentDirectoryURL = directory
    process.executableURL = try executableURL(executable, directory: directory)
    process.arguments = arguments
    return process
}

func validateProcessArguments(_ arguments: [String]) throws {
    guard !arguments.contains(where: { $0.contains("\0") }) else {
        throw CommandError("Command names and arguments cannot contain a NUL character.")
    }
}

func executableURL(_ executable: String, directory: URL) throws -> URL {
    if executable.contains("/") {
        return URL(fileURLWithPath: executable, relativeTo: directory).absoluteURL
    }
    let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for component in searchPath.components(separatedBy: ":") {
        let base = component.isEmpty ? directory : URL(fileURLWithPath: component, relativeTo: directory)
        let candidate = base.appendingPathComponent(executable)
        if isExecutableFile(candidate) { return candidate.absoluteURL }
    }
    throw CommandError("Command '\(executable)' was not found in PATH.", status: 127)
}

func isExecutableFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
}

func start(_ process: Process, executable: String) throws {
    do {
        try process.run()
    } catch {
        throw CommandError("Cannot run command '\(executable)': \(error.localizedDescription)", status: 126)
    }
}

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

func configurationURL(_ explicitPath: String?) throws -> URL {
    if let explicitPath {
        let path = (explicitPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    let directory = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    )
    return directory.appendingPathComponent("CommandManager/cm.json")
}

func loadConfiguration(at url: URL) throws -> Configuration {
    do {
        let data = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        try configuration.validate()
        return configuration
    } catch let error as CommandError {
        throw CommandError("Invalid configuration '\(url.path)': \(error)")
    } catch let error as DecodingError {
        throw CommandError("Invalid JSON configuration '\(url.path)': \(describeDecodingError(error))")
    } catch {
        throw CommandError("Cannot read configuration '\(url.path)': \(error.localizedDescription)")
    }
}

func describeDecodingError(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, let context):
        return "Missing '\(key.stringValue)' at \(decodingLocation(context))."
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        return "\(decodingLocation(context)): \(context.debugDescription)"
    @unknown default:
        return String(describing: error)
    }
}

func decodingLocation(_ context: DecodingError.Context) -> String {
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    return path.isEmpty ? "root" : path
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
    try Runner(configuration: configuration).run(name, arguments: options.arguments, directory: &directory)
}

func handleMissingConfiguration(_ options: Options, path: URL) throws {
    guard options.function == nil else {
        throw CommandError(
            "Configuration file not found: \(path.path). Create it from examples/cm.json; run cm --help for usage.")
    }
    printHelp(nil, path: path)
    print("\nConfiguration file not found. Create the directory and copy examples/cm.json here to get started.")
}

do {
    try main(Array(CommandLine.arguments.dropFirst()))
} catch let error as CommandError {
    FileHandle.standardError.write(Data("cm: \(error)\n".utf8))
    exit(error.status)
} catch {
    FileHandle.standardError.write(Data("cm: \(error.localizedDescription)\n".utf8))
    exit(1)
}
