import Foundation

struct CommandExecutor {
    func execute(
        _ executable: String, arguments: [String], capture: CaptureMode?, directory: URL,
        environment: [String: String], secrets: Set<String>
    ) throws -> RuntimeValue? {
        printCommand(executable, arguments: arguments.map { redact($0, secrets: secrets) })
        if let capture {
            return try captureCommand(
                executable, arguments: arguments, mode: capture, directory: directory, environment: environment)
        }
        let status = try runInheritedCommand(
            executable, arguments: arguments, directory: directory, environment: environment)
        try checkCommandStatus(status, executable: executable)
        return nil
    }

    private func captureCommand(
        _ executable: String, arguments: [String], mode: CaptureMode, directory: URL, environment: [String: String]
    ) throws -> RuntimeValue {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cm-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("stdout")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CommandError("Cannot create capture output file.")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let status = try runInheritedCommand(
            executable, arguments: arguments, directory: directory, environment: environment,
            stdoutFD: handle.fileDescriptor)
        try checkCommandStatus(status, executable: executable)
        let data = try Data(contentsOf: output)
        if mode == .json { return try decodeJSON(data) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CommandError("Captured output is not valid UTF-8.")
        }
        return .string(mode == .trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text)
    }

    private func checkCommandStatus(_ status: Int32, executable: String) throws {
        guard status == 0 else {
            throw CommandError("Command '\(executable)' failed with exit status \(status).", status: status)
        }
    }
}
