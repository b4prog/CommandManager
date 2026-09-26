import Foundation

enum Builtin: String, CaseIterable {
    case inFolder, assertGitRoot, assertGitRepository, export
    case set, inDirectory, pathJoin, assertPath, gitRoot, assertDirectChild, assertGitClean
    case readJson, jsonGet, log, executableHash

    var argumentCount: Int? {
        switch self {
        case .inFolder, .set, .inDirectory, .readJson, .log, .executableHash: return 1
        case .export, .assertPath, .assertDirectChild, .jsonGet: return 2
        case .assertGitRoot, .assertGitRepository, .gitRoot, .assertGitClean: return 0
        case .pathJoin: return nil
        }
    }

    var returnsValue: Bool {
        [.set, .pathJoin, .gitRoot, .readJson, .jsonGet, .executableHash].contains(self)
    }

    func validateCount(_ args: [String]) throws {
        if let count = argumentCount {
            try requireArguments(args, count: count, target: "Builtin '\(rawValue)'")
        } else if args.isEmpty {
            throw CommandError("Builtin '\(rawValue)' requires at least one path component.")
        }
    }
}

struct BuiltinExecutor {
    func execute(
        _ builtin: Builtin, arguments: [String], values: [String: RuntimeValue], directory: inout URL,
        environment: inout [String: String], secrets: Set<String>
    ) throws -> RuntimeValue? {
        try builtin.validateCount(arguments)
        switch builtin {
        case .inFolder: directory = try folder(named: arguments[0], from: directory)
        case .inDirectory:
            let destination = resolvedPath(arguments[0], from: directory)
            try assertPath(destination, kind: "directory")
            directory = destination
        case .assertGitRoot: try assertGitRepository(directory, requireRoot: true)
        case .assertGitRepository: try assertGitRepository(directory, requireRoot: false)
        case .export: try export(name: arguments[0], value: arguments[1], into: &environment)
        case .set: return .string(arguments[0])
        case .executableHash:
            return .string(try executableHash(arguments[0], directory: directory, environment: environment))
        case .pathJoin: return .string(try joinedPath(arguments))
        case .assertPath: try assertPath(resolvedPath(arguments[0], from: directory), kind: arguments[1])
        case .gitRoot:
            try assertGitRepository(directory, requireRoot: false)
            return .string(try gitOutput(["rev-parse", "--show-toplevel"], directory: directory))
        case .assertDirectChild: try assertDirectChild(arguments, directory: directory)
        case .assertGitClean:
            try assertGitRepository(directory, requireRoot: false)
            guard try gitOutput(["status", "--porcelain", "--untracked-files=all"], directory: directory).isEmpty else {
                throw CommandError(
                    "Git working tree has local changes; commit, stash, or discard them before updating.")
            }
        case .readJson:
            return try decodeJSON(Data(contentsOf: resolvedPath(arguments[0], from: directory)))
        case .jsonGet: return try jsonValue(arguments, values: values)
        case .log: FileHandle.standardOutput.write(Data((redact(arguments[0], secrets: secrets) + "\n").utf8))
        }
        return nil
    }

    private func resolvedPath(_ path: String, from directory: URL) -> URL {
        URL(fileURLWithPath: path, relativeTo: directory).absoluteURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func joinedPath(_ components: [String]) throws -> String {
        guard let first = components.first, !first.isEmpty else {
            throw CommandError("pathJoin requires a nonempty base path.")
        }
        guard components.dropFirst().allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") }) else {
            throw CommandError("pathJoin requires nonempty relative components after its base path.")
        }
        return components.dropFirst().reduce(first) { ($0 as NSString).appendingPathComponent($1) }
    }

    private func assertPath(_ path: URL, kind: String) throws {
        guard ["file", "directory"].contains(kind) else {
            throw CommandError("assertPath kind must be file or directory.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let expected: FileAttributeType = kind == "directory" ? .typeDirectory : .typeRegular
        guard attributes[.type] as? FileAttributeType == expected else {
            throw CommandError("Expected \(kind) at '\(path.path)'.")
        }
    }

    private func assertDirectChild(_ arguments: [String], directory: URL) throws {
        let child = resolvedPath(arguments[0], from: directory)
        let parent = resolvedPath(arguments[1], from: directory)
        try assertPath(child, kind: "directory")
        try assertPath(parent, kind: "directory")
        guard child != parent, child.deletingLastPathComponent() == parent else {
            throw CommandError("'\(child.path)' must be directly inside '\(parent.path)'.")
        }
    }

    private func jsonValue(_ arguments: [String], values: [String: RuntimeValue]) throws -> RuntimeValue {
        guard var value = values[arguments[0]] else { throw CommandError("Missing JSON variable '\(arguments[0])'.") }
        let pointer = arguments[1]
        guard pointer.isEmpty || pointer.hasPrefix("/") else {
            throw CommandError("jsonGet requires an RFC 6901 JSON pointer, such as /items/0/id.")
        }
        for component in pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            let key = try jsonPointerKey(String(component))
            switch value {
            case .object(let object):
                guard let field = object[key] else { throw CommandError("JSON field not found at '\(pointer)'.") }
                value = field
            case .array(let array):
                guard let index = Int(key), String(index) == key, array.indices.contains(index) else {
                    throw CommandError("Invalid JSON array index at '\(pointer)'.")
                }
                value = array[index]
            default: throw CommandError("Cannot traverse JSON value at '\(pointer)'.")
            }
        }
        if case .null = value { throw CommandError("Required JSON value is null at '\(pointer)'.") }
        if case .string(let text) = value, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CommandError("Required JSON value is empty at '\(pointer)'.")
        }
        return value
    }

    private func jsonPointerKey(_ component: String) throws -> String {
        guard component.range(of: "~(?![01])", options: .regularExpression) == nil else {
            throw CommandError("Invalid JSON pointer escape.")
        }
        return component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
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

    private func export(name: String, value: String, into environment: inout [String: String]) throws {
        guard isIdentifier(name) else {
            throw CommandError(
                "export requires an environment variable name using letters, digits, and underscores, starting with a letter or underscore."
            )
        }
        environment[name] = value
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
