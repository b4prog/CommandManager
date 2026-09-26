import Foundation
import Testing

final class CommandExecutionTests: CMTestCase {
    @Test func testHelpListsSortedEntryPointsAndHidesHelpers() throws {
        try configure([
            "Zulu": function([], description: "Last public function"),
            "hiddenHelper": function([], entry: false, description: "Secret helper"),
            "Alpha": function([], parameters: ["name"], description: "First public function"),
        ])
        let invocations: [[String]] = [[], ["--help"], ["-h"]]
        for arguments in invocations {
            let result = try runCM(arguments)
            assertSuccess(result)
            #expect(result.stdout.hasPrefix("CommandManager 0.4 —"))
            let alpha = try #require(result.stdout.range(of: "Alpha"))
            let zulu = try #require(result.stdout.range(of: "Zulu"))
            #expect(alpha.lowerBound < zulu.lowerBound)
            #expect(result.stdout.contains("First public function"))
            #expect(result.stdout.contains("Last public function"))
            #expect(result.stdout.contains("name"))
            #expect(!(result.stdout.contains("hiddenHelper")))
            #expect(!(result.stdout.contains("Secret helper")))
        }
    }

    @Test func testFunctionHelpDoesNotExecuteTheFunction() throws {
        try configure(["main": function([markerStep()], parameters: ["name"])])
        let result = try runCM(["--help", "main"])
        assertSuccess(result)
        #expect(result.stdout.contains("Example function"))
        #expect(result.stdout.contains("name"))
        #expect(!(FileManager.default.fileExists(atPath: marker.path)))
    }

    @Test func testMissingExplicitConfigurationFails() throws {
        assertFailure(try runCM())
    }

    @Test func testMissingDefaultConfigurationExplainsSetup() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = directory.path
        environment["CFFIXED_USER_HOME"] = directory.path
        let result = try runCM(environment: environment, useConfig: false)
        assertSuccess(result)
        #expect(result.stdout.hasPrefix("CommandManager 0.4 —"))
        #expect(
            result.stdout.contains("/\(directory.lastPathComponent)/Library/Application Support/CommandManager/cm.json")
        )
        #expect(result.stdout.contains("Configuration file not found."))
        let failure = try runCM(["main"], environment: environment, useConfig: false)
        #expect(failure.status == 1)
        #expect(failure.stderr.contains("Configuration file not found:"))
    }

    @Test func testUnknownFunctionAndInternalFunctionCannotRun() throws {
        try configure(["helper": function([markerStep()], entry: false)])
        for name in ["unknown", "helper"] {
            assertFailure(try runCM([name]))
            #expect(!(FileManager.default.fileExists(atPath: marker.path)))
        }
    }

    @Test func testOmittedEntryPointDefaultsToInternal() throws {
        try configure(["helper": ["description": "An internal function", "steps": []]])
        let result = try runCM()
        assertSuccess(result)
        #expect(!(result.stdout.contains("helper")))
        assertFailure(try runCM(["helper"]))
    }

    @Test func testRequiredArgumentsHaveExactArity() throws {
        try configure(["main": function([markerStep()], parameters: ["name"])])
        let invalidArguments: [[String]] = [[], ["one", "two"]]
        for arguments in invalidArguments {
            assertFailure(try runCM(["main"] + arguments))
            #expect(!(FileManager.default.fileExists(atPath: marker.path)))
        }
    }

    @Test func testArgumentsAreLiteralAndNotShellEvaluated() throws {
        try configure(["main": function([printStep("${value}")], parameters: ["value"])])
        let values = ["hello world", "", "--help", "${other}", "$(touch \(marker.path))", "a;b|c*d"]
        for value in values {
            assertSuccess(try runCM(["main", value]), output: value + "\n")
            #expect(!(FileManager.default.fileExists(atPath: marker.path)))
        }
    }

    @Test func testParameterSubstitutionAndDollarEscaping() throws {
        try configure([
            "main": function(
                [printStep("prefix-${value}-suffix $$ $${literal}")], parameters: ["value"]
            )
        ])
        assertSuccess(try runCM(["main", "hello"]), output: "prefix-hello-suffix $ ${literal}\n")
    }

    @Test func testDeclaredSettingsAreSubstitutedInFunctionArguments() throws {
        try configure(
            ["main": function([printStep("${FIGMA_TOKEN}")], settings: ["FIGMA_TOKEN"])],
            settings: [["name": "FIGMA_TOKEN", "value": "secret-token"]])
        assertSuccess(try runCM(["main"]), output: "secret-token\n")
    }

    @Test func testSettingsAreRedactedInPrintedCommands() throws {
        try configure(
            [
                "main": function(
                    [["command": "/usr/bin/true", "args": ["prefix-${FIGMA_TOKEN}-suffix"]]],
                    settings: ["FIGMA_TOKEN"])
            ], settings: [["name": "FIGMA_TOKEN", "value": "secret-token"]])
        let result = try runCM(["main"])
        assertSuccess(result)
        #expect(result.stdout.contains("prefix-*****-suffix"))
        #expect(!result.stdout.contains("secret-token"))
    }

    @Test func testCalledFunctionsUseTheirOwnDeclaredSettings() throws {
        try configure(
            [
                "main": function([["function": "helper"]]),
                "helper": function([printStep("${FIGMA_TOKEN}")], settings: ["FIGMA_TOKEN"], entry: false),
            ], settings: [["name": "FIGMA_TOKEN", "value": "secret-token"]])
        assertSuccess(try runCM(["main"]), output: "secret-token\n")
    }

    @Test func testCommandsAreEchoedInGreenWithAGreyChevronBeforeTheirOutput() throws {
        try configure(["main": function([printStep("${value}")], parameters: ["value"])])
        for value in ["plain", "", "two words", "it's quoted", "a\"b", "first\nsecond"] {
            let result = try runCM(["main", value])
            assertSuccess(result, output: value + "\n")
            let prefix = "\u{1B}[90m❯ \u{1B}[32m"
            let beginning = try #require(result.stdout.range(of: prefix, options: .anchored))
            let reset = try #require(result.stdout.range(of: "\u{1B}[0m\n"))
            let command = String(result.stdout[beginning.upperBound..<reset.lowerBound])
            #expect(!(command.contains("\n")))
            #expect(try parseEchoedCommand(command) == ["/usr/bin/printf", "%s\n", value])
            #expect(String(result.stdout[reset.upperBound...]) == value + "\n")
        }
    }

    @Test func testEachNestedCommandIsEchoedOnce() throws {
        try configure([
            "main": function([printStep("first"), ["function": "helper"]]),
            "helper": function([printStep("second")], entry: false),
        ])
        let result = try runCM(["main"])
        assertSuccess(result, output: "first\nsecond\n")
        #expect(result.stdout.components(separatedBy: "\u{1B}[90m❯ \u{1B}[32m").count - 1 == 2)
    }

    @Test func testNestedFunctionsReceiveTheirOwnArguments() throws {
        try configure([
            "main": function(
                [["function": "helper", "args": ["${outer}"]], printStep("${outer}")],
                parameters: ["outer"]
            ),
            "helper": function([printStep("nested ${inner}")], parameters: ["inner"], entry: false),
        ])
        assertSuccess(try runCM(["main", "value"]), output: "nested value\nvalue\n")
    }

    @Test func testStepsRunInOrderAndAllowOmittedArguments() throws {
        try configure([
            "main": function([
                ["command": "/usr/bin/true"],
                printStep("one"),
                ["function": "helper"],
                printStep("three"),
            ]),
            "helper": ["description": "Helper", "steps": [printStep("two")]],
        ])
        assertSuccess(try runCM(["main"]), output: "one\ntwo\nthree\n")
    }

    @Test func testFailedCommandPreservesStatusAndStopsCallers() throws {
        try configure([
            "main": function([["function": "helper"], markerStep()]),
            "helper": function(
                [["command": "/bin/sh", "args": ["-c", "exit 23"]], markerStep()], entry: false
            ),
        ])
        let result = try runCM(["main"])
        #expect(result.status == 23)
        #expect(result.stdout.components(separatedBy: "\u{1B}[90m❯ \u{1B}[32m").count - 1 == 1)
        #expect(result.stdout.contains("exit 23"))
        #expect(!(FileManager.default.fileExists(atPath: marker.path)))
    }

    @Test func testCommandLaunchFailureStopsExecution() throws {
        try configure([
            "main": function([["command": "cm-command-that-does-not-exist"], markerStep()])
        ])
        assertFailure(try runCM(["main"]))
        #expect(!(FileManager.default.fileExists(atPath: marker.path)))
    }

    @Test func testCommandInheritsStdinAndEnvironment() throws {
        try configure([
            "main": function([
                ["command": "/bin/cat"],
                ["command": "/bin/sh", "args": ["-c", "printf \"%s\" \"$CM_TEST_VALUE\""]],
            ])
        ])
        var environment = ProcessInfo.processInfo.environment
        environment["CM_TEST_VALUE"] = "inherited"
        assertSuccess(
            try runCM(["main"], environment: environment, input: "input\n"), output: "input\ninherited"
        )
    }

    @Test func testExportBuiltinSetsEnvironmentForLaterCommands() throws {
        try configure(
            [
                "main": function(
                    [
                        ["builtin": "export", "args": ["FIGMA_TOKEN", "${FIGMA_TOKEN}"]],
                        ["command": "/usr/bin/printenv", "args": ["FIGMA_TOKEN"]],
                    ], settings: ["FIGMA_TOKEN"])
            ], settings: [["name": "FIGMA_TOKEN", "value": "secret-token"]])
        assertSuccess(try runCM(["main"]), output: "secret-token\n")
    }

    @Test func testCommandOutputChannelsArePreserved() throws {
        try configure([
            "main": function([
                ["command": "/bin/sh", "args": ["-c", "printf output; printf diagnostic >&2"]]
            ])
        ])
        let result = try runCM(["main"])
        assertSuccess(result, output: "output")
        #expect(result.stderr == "diagnostic")
    }

    @Test func testExecutablesResolveViaPathAndRelativePaths() throws {
        let executable = directory.appendingPathComponent("custom-command")
        try "#!/bin/sh\nprintf 'custom output\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "")
        for command in ["custom-command", "./custom-command", executable.path] {
            try configure(["main": function([["command": command]])])
            assertSuccess(try runCM(["main"], environment: environment), output: "custom output\n")
        }
    }

    @Test func testHyphenatedEntryPointsAndHelperNames() throws {
        try configure([
            "brew-update": function([["function": "print-message", "args": ["${value}"]]], parameters: ["value"]),
            "print-message": function([printStep("${message}")], parameters: ["message"], entry: false),
        ])
        let help = try runCM()
        assertSuccess(help)
        #expect(help.stdout.contains("brew-update <value>"))
        #expect(!help.stdout.contains("print-message"))
        let functionHelp = try runCM(["--help", "brew-update"])
        assertSuccess(functionHelp)
        #expect(functionHelp.stdout.contains("Usage: cm brew-update <value>"))
        assertSuccess(try runCM(["brew-update", "updated"]), output: "updated\n")
    }

    @Test func testHyphenatedEntryPointRunsCommandsInOrder() throws {
        try configure([
            "brew-update": function([
                ["command": "brew", "args": ["update"]],
                ["command": "brew", "args": ["upgrade", "--greedy"]],
                ["command": "brew", "args": ["cleanup", "-s"]],
            ])
        ])
        let brew = directory.appendingPathComponent("brew")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\"\n".write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        let result = try runCM(["brew-update"], environment: environment)
        assertSuccess(result, output: "update\nupgrade --greedy\ncleanup -s\n")
        #expect(result.stdout.components(separatedBy: "\u{1B}[90m❯ \u{1B}[32mbrew ").count - 1 == 3)
    }

    private func parseEchoedCommand(_ command: String) throws -> [String] {
        let result = try runProcess(
            "/bin/bash", arguments: ["-c", "set -- " + command + "\nprintf '%s\\0' \"$@\""]
        )
        #expect(result.status == 0, "\(result.stderr)")
        var arguments = result.stdout.components(separatedBy: "\0")
        #expect(arguments.popLast() == "")
        return arguments
    }
}
