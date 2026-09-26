import Foundation
import Testing

final class ConfigurationTests: CMTestCase {
    @Test func testUnknownFieldsAreRejectedBeforeExecution() throws {
        var invalidFunction = function([markerStep()])
        invalidFunction["unexpected"] = true
        var invalidStep = markerStep()
        invalidStep["unexpected"] = true
        let variants: [[String: Any]] = [
            ["entryPoints": ["main": function([markerStep()])], "unexpected": true],
            ["entryPoints": ["main": invalidFunction]],
            ["entryPoints": ["main": function([invalidStep])]],
        ]
        for variant in variants {
            try JSONSerialization.data(withJSONObject: variant).write(to: config)
            assertFailure(try runCM(["main"]))
            #expect(!(FileManager.default.fileExists(atPath: marker.path)))
        }
    }

    @Test func testEachStepRequiresExactlyOneTarget() throws {
        let invalidSteps: [[String: Any]] = [
            [:],
            ["args": []],
            ["command": "/usr/bin/true", "function": "main"],
            ["command": "/usr/bin/true", "builtin": "assertGitRoot"],
            ["function": "main", "builtin": "assertGitRoot"],
        ]
        for step in invalidSteps {
            try assertInvalidConfiguration(["main": function([markerStep(), step])])
        }
    }

    @Test func testUnknownTargetsAreRejectedBeforeExecution() throws {
        for step in [["function": "missing"], ["builtin": "missing"]] {
            try assertInvalidConfiguration(["main": function([markerStep(), step])])
        }
    }

    @Test func testWrongNestedArgumentCountsAreRejectedBeforeExecution() throws {
        let invalidSteps: [[String: Any]] = [
            ["function": "helper"],
            ["function": "helper", "args": ["one", "two"]],
            ["builtin": "inFolder"],
            ["builtin": "inFolder", "args": ["one", "two"]],
            ["builtin": "assertGitRoot", "args": ["one"]],
            ["builtin": "assertGitRepository", "args": ["one"]],
            ["builtin": "export"],
            ["builtin": "export", "args": ["VARIABLE"]],
        ]
        for step in invalidSteps {
            try assertInvalidConfiguration(
                ["main": function([markerStep(), step])], functions: ["helper": function([], parameters: ["name"])])
        }
    }

    @Test func testUnusedFunctionsAreValidatedBeforeCommandsRun() throws {
        try assertInvalidConfiguration(
            ["main": function([markerStep()])], functions: ["unused": function([printStep("${unknown}")])])
    }

    @Test func testInvalidAndDuplicateParameterNamesAreRejected() throws {
        for parameters in [["name", "name"], [""], ["two words"], ["1number"], ["name\n"]] {
            try assertInvalidConfiguration(["main": function([markerStep()], parameters: parameters)])
        }
    }

    @Test func testInvalidSettingsAreRejectedBeforeExecution() throws {
        let functions = ["main": function([markerStep()], settings: ["known"])]
        let invalidSettings: [[[String: Any]]] = [
            [["name": "known", "value": "one"], ["name": "known", "value": "two"]],
            [["name": "invalid name", "value": "one"]],
            [["name": "known", "value": NSNull()]],
        ]
        for settings in invalidSettings {
            try configure(functions, settings: settings)
            assertFailure(try runCM(["main"]))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
        try assertInvalidConfiguration(["main": function([markerStep()], settings: ["missing"])])
    }

    @Test func testSettingsMustBeDeclaredAndCannotConflictWithParameters() throws {
        try configure(
            ["main": function([markerStep(), printStep("${token}")])],
            settings: [["name": "token", "value": "secret"]])
        assertFailure(try runCM(["main"]))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try configure(
            ["main": function([markerStep()], parameters: ["token"], settings: ["token"])],
            settings: [["name": "token", "value": "secret"]])
        assertFailure(try runCM(["main", "value"]))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testInvalidFunctionNamesAndEmptyDescriptionsAreRejected() throws {
        for name in ["", "two words", "--option", "1number", "name\n"] {
            try assertInvalidConfiguration(["main": function([markerStep()])], functions: [name: function([])])
        }
        try assertInvalidConfiguration(["main": function([markerStep()], description: " \n\t")])
    }

    @Test func testDirectAndIndirectCyclesAreRejectedBeforeExecution() throws {
        try assertInvalidConfiguration(["main": function([markerStep(), ["function": "main"]])])
        try assertInvalidConfiguration(
            ["main": function([markerStep(), ["function": "helper"]])],
            functions: ["helper": function([["function": "main"]])])
    }

    @Test func testInvalidJSONAndFieldTypesFail() throws {
        let documents = [
            "{",
            "[]",
            #"{"entryPoints": []}"#,
            #"{"entryPoints": {"main": {"description": 3, "steps": []}}}"#,
            #"{"entryPoints": {"main": {"description": "Missing steps"}}}"#,
            #"{"entryPoints": {"main": {"description": "Invalid flag", "entryPoint": "yes", "steps": []}}}"#,
        ]
        for document in documents {
            try document.write(to: config, atomically: true, encoding: .utf8)
            assertFailure(try runCM(["main"]))
        }
    }

    @Test func testExplicitNullFunctionFieldsAreRejected() throws {
        for key in ["parameters", "description", "steps"] {
            var invalidFunction = function([markerStep()])
            invalidFunction[key] = NSNull()
            try assertInvalidConfiguration(["main": invalidFunction])
        }
    }

    @Test func testExplicitNullStepFieldsAreRejected() throws {
        let steps: [[String: Any]] = [
            ["command": "/usr/bin/true", "args": NSNull()],
            ["command": NSNull()],
            ["function": NSNull()],
            ["builtin": NSNull()],
            ["command": "/usr/bin/true", "function": NSNull()],
        ]
        for step in steps {
            try assertInvalidConfiguration(["main": function([markerStep(), step])])
        }
    }

    @Test func testNULInExecutablesAndArgumentsFailsBeforeExecution() throws {
        let steps: [[String: Any]] = [
            ["command": "/usr/bin/true\0ignored"],
            ["command": "/usr/bin/printf", "args": ["hello\0world"]],
            ["function": "helper", "args": ["hello\0world"]],
            ["builtin": "inFolder", "args": ["child\0ignored"]],
        ]
        for step in steps {
            try assertInvalidConfiguration(
                ["main": function([markerStep(), step])], functions: ["helper": function([], parameters: ["value"])])
        }
    }

    @Test func testMalformedAndUnknownParameterReferencesFailBeforeExecution() throws {
        for value in ["${unclosed", "${unknown}", "${}"] {
            try assertInvalidConfiguration(["main": function([markerStep(), printStep(value)])])
        }
    }

    @Test func testEmptyExecutableIsRejectedBeforeExecution() throws {
        for command in ["", " \t\n"] {
            try assertInvalidConfiguration(["main": function([markerStep(), ["command": command]])])
        }
    }
}
