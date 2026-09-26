import Foundation
import Testing

final class WorkflowTests: CMTestCase {
    @Test func testOptionsConditionsAndNoSelectionHelp() throws {
        var main = function([
            ["builtin": "log", "args": ["build"], "when": ["any": ["all", "build"]]],
            ["builtin": "log", "args": ["check"], "when": ["all": ["check", ["not": "build"]]]],
        ])
        main["options"] = ["build": "Build the package", "check": "Check the package", "all": "Build everything"]
        main["requireAnyOption"] = true
        try configure(["main": main])
        assertSuccess(try runCM(["main", "--build"]), output: "build\n")
        assertSuccess(try runCM(["main", "--check"]), output: "check\n")
        assertSuccess(try runCM(["main", "--all"]), output: "build\n")
        assertSuccess(try runCM(["main", "--build", "--check"]), output: "build\n")
        let help = try runCM(["main"])
        assertSuccess(help)
        #expect(help.stdout.contains("--build  Build the package"))
        assertFailure(try runCM(["main", "--unknown"]))
    }

    @Test func testOptionTerminatorAndExplicitHelperOptions() throws {
        var helper = function(
            [
                ["builtin": "log", "args": ["${name}"], "when": "verbose"]
            ], parameters: ["name"])
        helper["options"] = ["verbose": "Print name"]
        try configure(
            [
                "main": function([["function": "helper", "args": ["--verbose", "--", "--literal"]]])
            ], functions: ["helper": helper])
        assertSuccess(try runCM(["main"]), output: "--literal\n")
    }

    @Test(arguments: ["--verbose", "--other", "--"])
    func testDynamicHelperArgumentsRemainPositional(value: String) throws {
        var helper = function(
            [["builtin": "log", "args": ["${name}|${verbose}"]]], parameters: ["name"])
        helper["options"] = ["verbose": "Print name"]
        try configure(
            [
                "main": function(
                    [
                        ["function": "helper", "args": ["${name}"]],
                        ["builtin": "set", "args": ["${name}"], "saveAs": "saved"],
                        ["function": "helper", "args": ["${saved}", "--verbose"]],
                        ["function": "helper", "args": ["--verbose", "${name}"]],
                    ], parameters: ["name"])
            ], functions: ["helper": helper])
        assertSuccess(try runCM(["main", value]), output: "\(value)|false\n\(value)|true\n\(value)|true\n")
    }

    @Test func testSpreadHelperArgumentsRemainPositional() throws {
        var helper = function(
            [["builtin": "log", "args": ["${first}|${second}|${third}|${verbose}"]]],
            parameters: ["first", "second", "third"])
        helper["options"] = ["verbose": "Print values"]
        try configure(
            [
                "main": function([
                    [
                        "command": "/usr/bin/printf", "args": ["%s", #"["--verbose","--other","--"]"#],
                        "capture": "json", "saveAs": "items",
                    ],
                    ["function": "helper", "args": [["spread": "items"]]],
                    ["function": "helper", "args": [["spread": "items"], "--verbose"]],
                ])
            ], functions: ["helper": helper])
        assertSuccess(try runCM(["main"]), output: "--verbose|--other|--|false\n--verbose|--other|--|true\n")
    }

    @Test func testInterpolatedHelperOptionIsPositionalAndLiteralUnknownOptionFails() throws {
        var helper = function(
            [["builtin": "log", "args": ["${name}|${verbose}"]]], parameters: ["name"])
        helper["options"] = ["verbose": "Print name"]
        try configure(
            ["main": function([["function": "helper", "args": ["--${name}"]]], parameters: ["name"])],
            functions: ["helper": helper])
        assertSuccess(try runCM(["main", "verbose"]), output: "--verbose|false\n")
        try configure(
            ["main": function([["function": "helper", "args": ["--other", "value"]]])],
            functions: ["helper": helper])
        let result = try runCM(["main"])
        assertFailure(result)
        #expect(result.stderr.contains("Unknown function option '--other'."))
    }

    @Test func testCaptureTextTrimmedJSONAndStderr() throws {
        try configure([
            "main": function([
                ["command": "/usr/bin/printf", "args": ["  hello\n"], "capture": "text", "saveAs": "raw"],
                ["command": "/usr/bin/printf", "args": ["  hello\n"], "capture": "trimmed", "saveAs": "trimmed"],
                [
                    "command": "/bin/sh",
                    "args": ["-c", "printf '{\"items\":[{\"id\":9007199254740993}]}'; printf diagnostic >&2"],
                    "capture": "json", "saveAs": "data",
                ],
                ["builtin": "jsonGet", "args": ["data", "/items/0/id"], "saveAs": "id"],
                printStep("${raw}|${trimmed}|${id}"),
            ])
        ])
        let result = try runCM(["main"])
        assertSuccess(result, output: "  hello\n|hello|9007199254740993\n")
        #expect(result.stderr == "diagnostic")
    }

    @Test func testFailedCaptureStopsBeforeLaterCommandsAndPreservesStatus() throws {
        try configure([
            "main": function([
                [
                    "command": "/bin/sh", "args": ["-c", "printf partial; exit 17"], "capture": "trimmed",
                    "saveAs": "result", "label": "Read account",
                ],
                markerStep(),
            ])
        ])
        let result = try runCM(["main"])
        #expect(result.status == 17)
        #expect(result.stderr.contains("Read account"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testLargeCaptureDoesNotDeadlock() throws {
        try configure([
            "main": function([
                [
                    "command": "/usr/bin/head", "args": ["-c", "2000000", "/dev/zero"], "capture": "text",
                    "saveAs": "large",
                ],
                ["builtin": "log", "args": ["finished"]],
            ])
        ])
        assertSuccess(try runCM(["main"]), output: "finished\n")
    }

    @Test func testJSONReadingPointersAndArrayExpansionPreserveArguments() throws {
        let data: [String: Any] = ["a/b": ["~key": ["two words", "", "$(touch must-not-exist)", "*.swift"]]]
        let file = directory.appendingPathComponent("data.json")
        try JSONSerialization.data(withJSONObject: data).write(to: file)
        try configure([
            "main": function([
                ["builtin": "readJson", "args": ["data.json"], "saveAs": "data"],
                ["builtin": "jsonGet", "args": ["data", "/a~1b/~0key"], "saveAs": "arguments"],
                ["command": "/usr/bin/printf", "args": ["<%s>\n", ["spread": "arguments"]]],
            ])
        ])
        assertSuccess(try runCM(["main"]), output: "<two words>\n<>\n<$(touch must-not-exist)>\n<*.swift>\n")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testMissingInvalidAndEmptyJSONValuesFail() throws {
        for pointer in ["/missing", "/null", "/empty", "/items/01", "/items/4", "/items/-1", "/bad~2key", "items"] {
            try configure([
                "main": function([
                    [
                        "command": "/usr/bin/printf", "args": ["%s", "{\"null\":null,\"empty\":\"  \",\"items\":[1]}"],
                        "capture": "json", "saveAs": "data",
                    ],
                    ["builtin": "jsonGet", "args": ["data", pointer], "saveAs": "value"],
                    markerStep(),
                ])
            ])
            assertFailure(try runCM(["main"]))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
        try configure([
            "main": function([
                ["command": "/usr/bin/printf", "args": ["invalid JSON"], "capture": "json", "saveAs": "data"],
                markerStep(),
            ])
        ])
        assertFailure(try runCM(["main"]))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testConditionalOutputsFailClearlyWhenMissing() throws {
        var main = function([
            ["builtin": "set", "args": ["ready"], "saveAs": "value", "when": "enabled"],
            printStep("${value}"),
            markerStep(),
        ])
        main["options"] = ["enabled": "Enable value"]
        try configure(["main": main])
        let result = try runCM(["main"])
        assertFailure(result)
        #expect(result.stderr.contains("Missing parameter 'value'"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        assertSuccess(try runCM(["main", "--enabled"]))
    }

    @Test func testVariablesAreLocalAndExplicitlyPassed() throws {
        try configure(
            [
                "main": function([
                    ["builtin": "set", "args": ["parent"], "saveAs": "value"],
                    ["function": "helper", "args": ["${value}"]],
                    ["builtin": "log", "args": ["${value}"]],
                ])
            ],
            functions: [
                "helper": function(
                    [
                        ["builtin": "set", "args": ["child-${input}"], "saveAs": "value"],
                        ["builtin": "log", "args": ["${value}"]],
                    ], parameters: ["input"])
            ])
        assertSuccess(try runCM(["main"]), output: "child-parent\nparent\n")
    }

    @Test func testSensitiveResultsAreRedactedInLogsEchoesAndErrors() throws {
        let file = directory.appendingPathComponent("secret.json")
        try Data(#"{"token":"private-token"}"#.utf8).write(to: file)
        try configure([
            "main": function([
                ["builtin": "readJson", "args": ["secret.json"], "saveAs": "data", "sensitive": true],
                ["builtin": "jsonGet", "args": ["data", "/token"], "saveAs": "token"],
                ["builtin": "log", "args": ["token=${token}"]],
                ["command": "/bin/test", "args": ["${token}", "=", "private-token"]],
                ["builtin": "inDirectory", "args": ["${token}"]],
            ])
        ])
        let result = try runCM(["main"])
        assertFailure(result)
        #expect(!result.stdout.contains("private-token"))
        #expect(!result.stderr.contains("private-token"))
        #expect(result.stdout.contains("token=*****"))
    }

    @Test func testPathsAndScopedDirectoryRestoration() throws {
        let child = directory.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try configure(
            [
                "main": function([
                    ["builtin": "pathJoin", "args": [directory.path, "child"], "saveAs": "child"],
                    ["builtin": "assertPath", "args": ["${child}", "directory"]],
                    ["builtin": "assertPath", "args": [config.path, "file"]],
                    ["builtin": "assertDirectChild", "args": ["${child}", directory.path]],
                    ["function": "helper", "args": ["${child}"]],
                    ["command": "/bin/pwd"],
                ])
            ],
            functions: [
                "helper": function(
                    [
                        ["builtin": "inDirectory", "args": ["${path}"]],
                        ["command": "/bin/pwd"],
                    ], parameters: ["path"])
            ])
        assertSuccess(try runCM(["main"]), output: "\(child.path)\n\(directory.path)\n")
        try configure(["main": function([["builtin": "assertDirectChild", "args": [directory.path, directory.path]]])])
        assertFailure(try runCM(["main"]))
    }

    @Test func testGitRootAndCleanAssertionIncludingUntrackedFiles() throws {
        let repository = directory.appendingPathComponent("repository")
        let nested = repository.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try initializeRepository(cwd: repository)
        try configure([
            "main": function([
                ["builtin": "gitRoot", "saveAs": "root"],
                ["builtin": "log", "args": ["${root}"]],
                ["builtin": "assertGitClean"],
            ])
        ])
        assertSuccess(try runCM(["main"], cwd: nested), output: "\(repository.path)\n")
        try Data("changed".utf8).write(to: repository.appendingPathComponent("untracked"))
        assertFailure(try runCM(["main"], cwd: nested))
        try git(["add", "untracked"], cwd: repository)
        assertFailure(try runCM(["main"], cwd: nested))
    }

    @Test func testInvalidWorkflowSchemaIsRejectedBeforeExecution() throws {
        let invalid: [[String: Any]] = [
            ["builtin": "set", "args": ["value"]],
            ["builtin": "log", "args": ["value"], "saveAs": "result"],
            ["command": "/bin/echo", "saveAs": "result"],
            ["command": "/bin/echo", "capture": "text"],
            ["command": "/bin/echo", "capture": "invalid", "saveAs": "result"],
            ["builtin": "set", "args": ["value"], "saveAs": "bad name"],
            ["builtin": "log", "args": ["value"], "when": "unknown"],
            ["builtin": "log", "args": ["value"], "when": ["any": []]],
            ["builtin": "log", "args": ["value"], "when": ["any": [], "not": "unknown"]],
            ["command": "/bin/echo", "args": [["spread": "missing"]]],
            ["builtin": "jsonGet", "args": ["missing", "/id"], "saveAs": "id"],
            ["builtin": "log", "args": ["value"], "sensitive": true],
            ["builtin": "pathJoin", "saveAs": "path"],
        ]
        for step in invalid {
            try assertInvalidConfiguration(["main": function([markerStep(), step])])
        }
    }

    @Test func testInvalidArraySpreadsAndStructuredSubstitutionFail() throws {
        let variants: [(String, [Any])] = [
            ("[1]", [["spread": "data"]]),
            ("{}", [["spread": "data"]]),
            ("[]", ["${data}"]),
            (#"["\u0000"]"#, [["spread": "data"]]),
        ]
        for (json, args) in variants {
            try configure([
                "main": function([
                    ["command": "/usr/bin/printf", "args": ["%s", json], "capture": "json", "saveAs": "data"],
                    ["command": "/usr/bin/touch", "args": args],
                    markerStep(),
                ])
            ])
            assertFailure(try runCM(["main"]))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func testCapturedValueExportsAndStdinArePreserved() throws {
        try configure([
            "main": function([
                ["command": "/bin/cat", "capture": "trimmed", "saveAs": "input", "sensitive": true],
                ["builtin": "export", "args": ["CM_CAPTURED", "${input}"]],
                [
                    "command": "/bin/sh", "args": ["-c", "printf '%s' \"$CM_CAPTURED\""], "capture": "text",
                    "saveAs": "copied",
                ],
                ["builtin": "log", "args": ["${copied}"]],
            ])
        ])
        assertSuccess(try runCM(["main"], input: "input-value\n"), output: "*****\n")
    }

    @Test func testJSONBooleanConditionAndSkippedArguments() throws {
        try configure([
            "main": function([
                ["command": "/usr/bin/printf", "args": ["false"], "capture": "json", "saveAs": "enabled"],
                ["builtin": "set", "args": ["unused"], "saveAs": "missing", "when": "enabled"],
                ["builtin": "log", "args": ["${missing}"], "when": "enabled"],
                ["builtin": "log", "args": ["done"], "when": ["not": "enabled"]],
            ])
        ])
        assertSuccess(try runCM(["main"]), output: "done\n")
    }

    @Test func testForwardAndDuplicateOutputsAreRejected() throws {
        try assertInvalidConfiguration([
            "main": function([
                markerStep(), printStep("${later}"),
                ["builtin": "set", "args": ["value"], "saveAs": "later"],
            ])
        ])
        try assertInvalidConfiguration([
            "main": function([
                markerStep(),
                ["builtin": "set", "args": ["one"], "saveAs": "value"],
                ["builtin": "set", "args": ["two"], "saveAs": "value"],
            ])
        ])
    }
}
