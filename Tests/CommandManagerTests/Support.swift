import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var outputWithoutEcho: String {
        let expression = try! NSRegularExpression(
            pattern: "\u{1B}\\[90m❯ \u{1B}\\[32m.*?\u{1B}\\[0m\\n", options: .dotMatchesLineSeparators)
        let range = NSRange(stdout.startIndex..<stdout.endIndex, in: stdout)
        return expression.stringByReplacingMatches(in: stdout, range: range, withTemplate: "")
    }
}

enum TestProcessError: Error {
    case timedOut(String)
    case missingBinary
}

func waitForProcess(_ process: Process, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard process.isRunning else { return }
    process.terminate()
    let terminationDeadline = Date().addingTimeInterval(1)
    while process.isRunning && Date() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
    throw TestProcessError.timedOut(process.executableURL?.path ?? "process")
}

func runProcess(
    _ executable: String, arguments: [String], cwd: URL? = nil,
    environment: [String: String]? = nil, input: String? = nil, timeout: TimeInterval = 30
) throws -> CommandResult {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let outputURL = temporary.appendingPathComponent("stdout")
    let errorURL = temporary.appendingPathComponent("stderr")
    let inputURL = temporary.appendingPathComponent("stdin")
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)
    try Data((input ?? "").utf8).write(to: inputURL)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    let inputHandle = try FileHandle(forReadingFrom: inputURL)
    defer {
        try? outputHandle.close()
        try? errorHandle.close()
        try? inputHandle.close()
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = cwd
    process.environment = environment ?? ProcessInfo.processInfo.environment
    process.standardInput = inputHandle
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    try process.run()
    try waitForProcess(process, timeout: timeout)
    return CommandResult(
        status: process.terminationStatus,
        stdout: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
}

class CMTestCase {
    let directory: URL
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    var config: URL { directory.appendingPathComponent("cm.json") }
    var marker: URL { directory.appendingPathComponent("must-not-exist") }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        guard let physicalPath = realpath(temporary.path, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(physicalPath) }
        directory = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func function(
        _ steps: [[String: Any]], parameters: [String] = [], settings: [String] = [],
        description: String = "Example function"
    ) -> [String: Any] {
        [
            "description": description, "parameters": parameters, "settings": settings,
            "steps": steps,
        ]
    }

    func configure(
        _ entryPoints: [String: [String: Any]] = [:], functions: [String: [String: Any]] = [:],
        settings: [[String: Any]] = []
    ) throws {
        try JSONSerialization.data(
            withJSONObject: ["settings": settings, "entryPoints": entryPoints, "functions": functions],
            options: .sortedKeys
        )
        .write(to: config)
    }

    func executableURL() throws -> URL {
        var parent = Bundle(for: CMTestCase.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = parent.appendingPathComponent("cm")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            parent.deleteLastPathComponent()
        }
        let candidate = Self.repository.appendingPathComponent(".build/debug/cm")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw TestProcessError.missingBinary
        }
        return candidate
    }

    func runCM(
        _ arguments: [String] = [], cwd: URL? = nil, environment: [String: String]? = nil,
        input: String? = nil, useConfig: Bool = true
    ) throws -> CommandResult {
        let configurationArguments = useConfig ? ["--config", config.path] : []
        return try runProcess(
            executableURL().path, arguments: configurationArguments + arguments,
            cwd: cwd ?? directory, environment: environment, input: input)
    }

    func assertSuccess(
        _ result: CommandResult, output: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.status == 0, "\(result.stdout + result.stderr)", sourceLocation: sourceLocation)
        if let output {
            #expect(result.outputWithoutEcho == output, sourceLocation: sourceLocation)
        }
    }

    func assertFailure(
        _ result: CommandResult, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.status != 0, "\(result.stdout + result.stderr)", sourceLocation: sourceLocation)
        #expect(
            !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Failures should explain the error on stderr", sourceLocation: sourceLocation)
    }

    func printStep(_ value: String) -> [String: Any] {
        ["command": "/usr/bin/printf", "args": ["%s\n", value]]
    }

    func markerStep() -> [String: Any] {
        ["command": "/usr/bin/touch", "args": [marker.path]]
    }

    func assertInvalidConfiguration(
        _ entryPoints: [String: [String: Any]], functions: [String: [String: Any]] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try configure(entryPoints, functions: functions)
        assertFailure(try runCM(["main"]), sourceLocation: sourceLocation)
        #expect(
            !FileManager.default.fileExists(atPath: marker.path),
            "Validation must finish before commands run", sourceLocation: sourceLocation)
    }

    func git(_ arguments: [String], cwd: URL? = nil) throws {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment.merge(
            [
                "GIT_AUTHOR_NAME": "CommandManager Tests",
                "GIT_AUTHOR_EMAIL": "cm-tests@example.invalid",
                "GIT_COMMITTER_NAME": "CommandManager Tests",
                "GIT_COMMITTER_EMAIL": "cm-tests@example.invalid",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            ], uniquingKeysWith: { _, new in new })
        let paths = (environment["PATH"] ?? "").split(separator: ":")
        let hasRTK = paths.contains { FileManager.default.isExecutableFile(atPath: "\($0)/rtk") }
        let command = hasRTK ? "rtk" : "git"
        let arguments = hasRTK ? ["git"] + arguments : arguments
        let result = try runProcess(
            command, arguments: arguments, cwd: cwd ?? directory, environment: environment)
        assertSuccess(result)
    }

    func initializeRepository(cwd: URL? = nil) throws {
        try git(["init", "--quiet"], cwd: cwd)
        try git(
            ["-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "Initial"],
            cwd: cwd)
    }
}
