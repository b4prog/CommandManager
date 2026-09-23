import Darwin
import Foundation
import Testing

final class InteractiveCommandTests: CMTestCase {
    @Test func testCommandReadsFromForegroundTerminalAndContinuesSequence() throws {
        let command = directory.appendingPathComponent("prompt.sh")
        try """
        #!/bin/sh
        group=$(/bin/ps -o pgid= -p $$) || exit 41
        foreground=$(/bin/ps -o tpgid= -p $$) || exit 41
        if ! [ "$group" -gt 0 ] || ! [ "$group" -eq "$foreground" ]; then
            printf 'WRONG_PROCESS_GROUP: group=<%s> foreground=<%s>\\n' "$group" "$foreground"
            exit 42
        fi
        printf 'CONFIRM [y/n]: '
        read answer
        [ "$answer" = y ] || exit 23
        printf 'ACCEPTED\\n'
        """.write(to: command, atomically: true, encoding: .utf8)
        try configure([
            "main": function([
                ["command": "/bin/sh", "args": [command.path]],
                printStep("NEXT_COMMAND"),
            ])
        ])
        let output = try runTerminalPrompt()
        #expect(!output.contains("WRONG_PROCESS_GROUP"))
        #expect(output.contains("ACCEPTED"))
        #expect(output.contains("\r\nNEXT_COMMAND\r\n"))
    }

    @Test func testCommandSignalStopsSequenceAndPreservesStatus() throws {
        try configure([
            "main": function([
                ["command": "/bin/sh", "args": ["-c", "kill -TERM $$$$"]],
                markerStep(),
            ])
        ])
        let result = try runCM(["main"])
        #expect(result.status == 143)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private func runTerminalPrompt() throws -> String {
        let outputURL = directory.appendingPathComponent("terminal-output")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", try executableURL().path, "--config", config.path, "main"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        defer {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.close()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            let text = try String(contentsOf: outputURL, encoding: .utf8)
            if text.contains("CONFIRM [y/n]: ") { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let promptOutput = try String(contentsOf: outputURL, encoding: .utf8)
        try #require(promptOutput.contains("CONFIRM [y/n]: "), "\(promptOutput)")
        try input.fileHandleForWriting.write(contentsOf: Data("y\n".utf8))
        try waitForProcess(process, timeout: 5)
        return try String(contentsOf: outputURL, encoding: .utf8)
    }
}
