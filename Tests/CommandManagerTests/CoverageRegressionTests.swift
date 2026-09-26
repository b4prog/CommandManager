import Foundation
import Testing

final class CoverageRegressionTests: CMTestCase {
    @Test func testParameterlessFunctionHelpDoesNotExecuteSteps() throws {
        try configure(["main": function([markerStep()])])
        let result = try runCM(["--help", "main"])
        assertSuccess(result)
        #expect(result.stdout.hasPrefix("Usage: cm main\n"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testExecutableSearchUsesDefaultAndEmptyPathComponents() throws {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PATH")
        try configure(["main": function([["command": "printf", "args": ["default path"]]])])
        assertSuccess(try runCM(["main"], environment: environment), output: "default path")
        let executable = directory.appendingPathComponent("local-command")
        try Data("#!/bin/sh\nprintf 'local path'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        environment["PATH"] = ""
        try configure(["main": function([["command": "local-command"]])])
        assertSuccess(try runCM(["main"], environment: environment), output: "local path")
    }

    @Test func testGitProbeLaunchFailurePreservesStatus() throws {
        let executable = directory.appendingPathComponent("git")
        try Data("#!\(directory.path)/missing-interpreter\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        try configure(["main": function([["builtin": "assertGitRepository"], markerStep()])])
        let result = try runCM(["main"], environment: environment)
        #expect(result.status == 126)
        #expect(result.stderr.contains("Cannot run command 'git'"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testJSONGetReportsSkippedSourceAndRendersFalse() throws {
        var main = function([
            ["command": "/usr/bin/printf", "args": ["false"], "capture": "json", "saveAs": "flag"],
            ["builtin": "log", "args": ["${flag}"]],
            ["builtin": "set", "args": ["unused"], "saveAs": "missing", "when": "enabled"],
            ["builtin": "jsonGet", "args": ["missing", ""], "saveAs": "result"], markerStep(),
        ])
        main["options"] = ["enabled": "Enable source"]
        try configure(["main": main])
        let result = try runCM(["main"])
        assertFailure(result)
        #expect(result.outputWithoutEcho == "false\n")
        #expect(result.stderr.contains("Missing JSON variable 'missing'"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testInvalidCLIOptionsExplainTheFailure() throws {
        for arguments in [["--config"], ["--config", ""], ["--config", config.path, "--config", config.path]] {
            let result = try runCM(arguments, useConfig: false)
            #expect(result.status == 1)
            #expect(result.stderr.contains("Use --config once, followed by a configuration file path."))
        }
        let result = try runCM(["--unknown"], useConfig: false)
        #expect(result.status == 1)
        #expect(result.stderr.contains("Unknown option '--unknown'"))
    }

    @Test func testDefaultConfigurationIsLoadedFromAnIsolatedHome() throws {
        let destination = directory.appendingPathComponent("Library/Application Support/CommandManager/cm.json")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configure(["main": function([printStep("isolated configuration")])])
        try FileManager.default.copyItem(at: config, to: destination)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = directory.path
        environment["CFFIXED_USER_HOME"] = directory.path
        assertSuccess(
            try runCM(["main"], environment: environment, useConfig: false), output: "isolated configuration\n")
    }

    @Test func testInvalidFunctionOptionsAndSettingsFailBeforeExecution() throws {
        let variants: [([String: Any], String)] = [
            (["options": ["bad name": "Invalid"]], "Invalid or conflicting option"),
            (["parameters": ["value"], "options": ["value": "Conflict"]], "Invalid or conflicting option"),
            (["settings": ["token"], "options": ["token": "Conflict"]], "Invalid or conflicting option"),
            (["requireAnyOption": true], "requireAnyOption needs declared options"),
            (["settings": ["token", "token"]], "must have unique setting names"),
            (["settings": ["bad name"]], "must have unique setting names"),
        ]
        for (fields, message) in variants {
            let main = function([markerStep()]).merging(fields, uniquingKeysWith: { _, new in new })
            try configure(["main": main], settings: [["name": "token", "value": "secret"]])
            try expectFailure(message)
        }
    }

    @Test func testInvalidStepCombinationsFailBeforeExecution() throws {
        let variants: [([String: Any], String)] = [
            (["function": "helper", "capture": "text", "saveAs": "value"], "Function calls cannot capture"),
            (["function": "helper", "saveAs": "value"], "Function calls cannot capture"),
            (["builtin": "log", "args": ["hello"], "label": "  "], "Step label must not be empty"),
            (["builtin": "log", "args": ["hello"], "label": "bad\0label"], "cannot contain a NUL"),
            (["builtin": "log", "args": [["spread": "value"]]], "Array expansion is supported only"),
            (
                ["builtin": "set", "args": ["hello"], "capture": "text", "saveAs": "value"],
                "capture is only for commands"
            ),
        ]
        for (step, message) in variants {
            try configure(["main": function([markerStep(), step])], functions: ["helper": function([])])
            try expectFailure(message)
        }
    }

    @Test func testPathAndEnvironmentValidationStopsLaterCommands() throws {
        let variants: [([String: Any], String)] = [
            (["builtin": "pathJoin", "args": [""], "saveAs": "path"], "requires a nonempty base path"),
            (
                ["builtin": "pathJoin", "args": ["base", ""], "saveAs": "path"], "requires nonempty relative components"
            ),
            (
                ["builtin": "pathJoin", "args": ["base", "/absolute"], "saveAs": "path"],
                "requires nonempty relative components"
            ),
            (["builtin": "assertPath", "args": [directory.path, "link"]], "kind must be file or directory"),
            (["builtin": "assertPath", "args": [directory.path, "file"]], "Expected file"),
            (["builtin": "assertPath", "args": [config.path, "directory"]], "Expected directory"),
            (["builtin": "export", "args": ["BAD-NAME", "value"]], "export requires an environment variable name"),
        ]
        for (step, message) in variants {
            try configure(["main": function([step, markerStep()])])
            try expectFailure(message)
        }
    }

    @Test func testNonExecutableCommandPreservesLaunchFailureStatus() throws {
        let executable = directory.appendingPathComponent("not-executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        try configure(["main": function([["command": executable.path], markerStep()])])
        try expectFailure("Cannot run command", status: 126)
    }

    @Test func testMissingCommandPreservesNotFoundStatus() throws {
        try configure(["main": function([["command": "cm-nonexistent-command"], markerStep()])])
        try expectFailure("was not found in PATH", status: 127)
    }

    @Test func testCaptureRejectsInvalidUTF8AndCleansTemporaryFiles() throws {
        let bytes = directory.appendingPathComponent("invalid-utf8")
        try Data([0xff, 0xfe]).write(to: bytes)
        for mode in ["text", "trimmed"] {
            try assertCaptureCleanup(
                command: "/bin/cat", arguments: [bytes.path], mode: mode, status: 1, message: "not valid UTF-8")
        }
    }

    @Test func testCaptureCleansTemporaryFilesAfterSuccessAndCommandFailure() throws {
        try assertCaptureCleanup(command: "/usr/bin/printf", arguments: ["hello"], mode: "text", status: 0)
        try assertCaptureCleanup(
            command: "/bin/sh", arguments: ["-c", "printf partial; exit 17"], mode: "text", status: 17)
        try assertCaptureCleanup(
            command: "/usr/bin/printf", arguments: ["invalid"], mode: "json", status: 1,
            message: "Cannot decode JSON result")
    }

    @Test func testSensitiveArraysAndOverlappingSecretsAreRedactedAcrossHelpers() throws {
        let secrets = directory.appendingPathComponent("secrets.json")
        try Data(#"["private","private-token",{"nested":[true,42,null,""]}]"#.utf8).write(to: secrets)
        try configure(
            [
                "main": function([
                    ["builtin": "readJson", "args": [secrets.path], "saveAs": "data", "sensitive": true],
                    ["function": "helper"],
                ])
            ],
            functions: [
                "helper": function(
                    [
                        ["builtin": "log", "args": ["private-token|private|true|42|visible"]],
                        ["command": "/usr/bin/true", "args": ["private-token", "private", "true", "42"]],
                        ["builtin": "inDirectory", "args": ["private-token"]],
                    ])
            ])
        let result = try runCM(["main"])
        assertFailure(result)
        #expect(result.outputWithoutEcho == "*****|*****|*****|*****|visible\n")
        #expect(result.stdout.contains("'*****' '*****' '*****' '*****'"))
        #expect(!result.stderr.contains("private"))
        #expect(!result.stderr.contains("-token"))
        #expect(result.stderr.contains("*****"))
    }

    @Test func testControlCharactersRoundTripThroughCommandEchoes() throws {
        let values = ["tab\tvalue", "carriage\rreturn", "escape\u{1b}value", "delete\u{7f}", "quote'\nand\\slash"]
        try configure(["main": function([printStep("${value}")], parameters: ["value"])])
        for value in values {
            let result = try runCM(["main", value])
            assertSuccess(result, output: value + "\n")
            let prefix = "\u{1B}[90m❯ \u{1B}[32m"
            let start = try #require(result.stdout.range(of: prefix, options: .anchored))
            let end = try #require(result.stdout.range(of: "\u{1B}[0m\n"))
            let echo = String(result.stdout[start.upperBound..<end.lowerBound])
            #expect(!echo.unicodeScalars.contains { $0.value < 32 || $0.value == 127 })
            let replay = try runProcess("/bin/bash", arguments: ["-c", "set -- " + echo + "; printf '%s' \"$3\""])
            #expect(replay.status == 0)
            #expect(replay.stdout == value)
        }
    }

    @Test func testConditionsShortCircuitMissingOutputs() throws {
        var main = function([
            ["builtin": "set", "args": ["true"], "saveAs": "missing", "when": "disabled"],
            ["builtin": "log", "args": ["any"], "when": ["any": ["enabled", "missing"]]],
            ["builtin": "log", "args": ["must not run"], "when": ["all": ["disabled", "missing"]]],
        ])
        main["options"] = ["enabled": "Enable", "disabled": "Disable"]
        try configure(["main": main])
        assertSuccess(try runCM(["main", "--enabled"]), output: "any\n")
    }

    @Test func testMissingAndNonBooleanConditionsFailClearly() throws {
        for json in ["1", "null", "[]", "{}", #""yes""#] {
            try configure([
                "main": function([
                    ["command": "/usr/bin/printf", "args": ["%s", json], "capture": "json", "saveAs": "condition"],
                    ["builtin": "log", "args": ["no"], "when": "condition"], markerStep(),
                ])
            ])
            try expectFailure("must be a boolean or the string true/false")
        }
        var main = function([
            ["builtin": "set", "args": ["true"], "saveAs": "missing", "when": "enabled"],
            ["builtin": "log", "args": ["no"], "when": "missing"], markerStep(),
        ])
        main["options"] = ["enabled": "Enable"]
        try configure(["main": main])
        try expectFailure("Missing condition value 'missing'")
    }

    @Test func testJSONRootSelectionAndScalarTraversal() throws {
        try configure([
            "main": function([
                [
                    "command": "/usr/bin/printf", "args": [#"{"":"empty key","value":true}"#], "capture": "json",
                    "saveAs": "data",
                ],
                ["builtin": "jsonGet", "args": ["data", ""], "saveAs": "root"],
                ["builtin": "jsonGet", "args": ["root", "/"], "saveAs": "emptyKey"],
                ["builtin": "jsonGet", "args": ["root", "/value"], "saveAs": "flag"],
                ["builtin": "log", "args": ["${emptyKey}|${flag}"]],
                ["builtin": "jsonGet", "args": ["flag", "/nested"], "saveAs": "invalid"], markerStep(),
            ])
        ])
        let result = try runCM(["main"])
        assertFailure(result)
        #expect(result.outputWithoutEcho == "empty key|true\n")
        #expect(result.stderr.contains("Cannot traverse JSON value"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testFunctionArraySpreadsCheckDynamicArity() throws {
        for (json, succeeds) in [(#"["two words",""]"#, true), ("[]", false), (#"["one"]"#, false)] {
            try configure(
                [
                    "main": function([
                        ["command": "/usr/bin/printf", "args": ["%s", json], "capture": "json", "saveAs": "args"],
                        ["function": "helper", "args": [["spread": "args"]]],
                    ])
                ],
                functions: [
                    "helper": function(
                        [["builtin": "log", "args": ["<${first}><${second}>"]]], parameters: ["first", "second"])
                ])
            let result = try runCM(["main"])
            if succeeds {
                assertSuccess(result, output: "<two words><>\n")
            } else {
                assertFailure(result)
                #expect(result.stderr.contains("expects 2 argument(s)"))
                #expect(result.outputWithoutEcho.isEmpty)
            }
        }
    }

    @Test func testGitCleanIgnoresIgnoredFilesButRejectsTrackedEdits() throws {
        let repository = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try initializeRepository(cwd: repository)
        try Data("ignored\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        let tracked = repository.appendingPathComponent("tracked")
        try Data("original".utf8).write(to: tracked)
        try git(["add", "."], cwd: repository)
        try git(["-c", "commit.gpgsign=false", "commit", "-m", "Track fixtures"], cwd: repository)
        try Data("ignored".utf8).write(to: repository.appendingPathComponent("ignored"))
        try configure(["main": function([["builtin": "assertGitClean"], printStep("clean")])])
        assertSuccess(try runCM(["main"], cwd: repository), output: "clean\n")
        try Data("modified".utf8).write(to: tracked)
        let result = try runCM(["main"], cwd: repository)
        assertFailure(result)
        #expect(result.stderr.contains("Git working tree has local changes"))
        #expect(result.outputWithoutEcho.isEmpty)
    }

    private func expectFailure(_ message: String, status: Int32 = 1, sourceLocation: SourceLocation = #_sourceLocation)
        throws
    {
        let result = try runCM(["main"])
        #expect(result.status == status, "\(result.stderr)", sourceLocation: sourceLocation)
        #expect(result.stderr.contains(message), "\(result.stderr)", sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: marker.path), sourceLocation: sourceLocation)
    }

    private func assertCaptureCleanup(
        command: String, arguments: [String], mode: String, status: Int32, message: String? = nil
    ) throws {
        let temporary = directory.appendingPathComponent("capture-temp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporary.path + "/"
        try configure([
            "main": function([
                ["command": command, "args": arguments, "capture": mode, "saveAs": "result"],
                ["builtin": "log", "args": ["${result}"]],
            ])
        ])
        let result = try runCM(["main"], environment: environment)
        #expect(result.status == status, "\(result.stderr)")
        if let message { #expect(result.stderr.contains(message)) }
        #expect(result.outputWithoutEcho == (status == 0 ? "hello\n" : ""))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }
}
