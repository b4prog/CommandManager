import Foundation
import Testing

final class EntryPointTests: CMTestCase {
    @Test func testEntryPointsCanCallHelpersAndOtherEntryPoints() throws {
        try configure(
            [
                "main": function([["function": "helper", "args": ["value"]]]),
                "public-leaf": function([printStep("${value}")], parameters: ["value"]),
            ],
            functions: [
                "helper": function([["function": "public-leaf", "args": ["${value}"]]], parameters: ["value"])
            ])
        assertSuccess(try runCM(["main"]), output: "value\n")
        assertSuccess(try runCM(["public-leaf", "direct"]), output: "direct\n")
        let help = try runCM()
        #expect(help.stdout.contains("public-leaf"))
        #expect(!help.stdout.contains("helper"))
        assertFailure(try runCM(["--help", "helper"]))
    }

    @Test func testDuplicateNamesAcrossSectionsFailBeforeExecution() throws {
        try configure(["main": function([markerStep()])], functions: ["main": function([])])
        let result = try runCM(["main"])
        assertFailure(result)
        #expect(result.stderr.contains("unique across entryPoints and functions"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testLegacyEntryPointFieldExplainsMigrationInEitherSection() throws {
        for section in ["entryPoints", "functions"] {
            for value in [true, false] {
                var legacy = function([markerStep()])
                legacy["entryPoint"] = value
                try JSONSerialization.data(withJSONObject: [section: ["main": legacy]]).write(to: config)
                let result = try runCM(["main"])
                assertFailure(result)
                #expect(result.stderr.contains("Move public definitions into entryPoints"))
                #expect(!FileManager.default.fileExists(atPath: marker.path))
            }
        }
    }

    @Test func testDefinitionSectionsCanBeOmittedButNotNullOrWrongTypes() throws {
        let valid: [[String: Any]] = [
            [:],
            ["entryPoints": ["main": function([])]],
            ["functions": ["helper": function([])]],
        ]
        for document in valid {
            try JSONSerialization.data(withJSONObject: document).write(to: config)
            assertSuccess(try runCM())
        }
        let invalid: [Any] = [NSNull(), [], "invalid", true]
        for section in ["entryPoints", "functions"] {
            for value in invalid {
                try JSONSerialization.data(withJSONObject: [section: value]).write(to: config)
                assertFailure(try runCM())
            }
        }
    }

    @Test func testCyclesAndUnusedInvalidEntryPointsAreRejected() throws {
        try assertInvalidConfiguration(
            [
                "main": function([markerStep(), ["function": "helper"]]),
                "other": function([["function": "main"]]),
            ], functions: ["helper": function([["function": "other"]])])
        try assertInvalidConfiguration([
            "main": function([markerStep()]),
            "unused": function([["function": "missing"]]),
        ])
    }

    @Test func testTrackedExampleUsesOrderedSectionsAndValidates() throws {
        let example = Self.repository.appendingPathComponent("examples/cm.json")
        let text = try String(contentsOf: example, encoding: .utf8)
        let document = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let entries = try #require(document["entryPoints"] as? [String: Any])
        let helpers = try #require(document["functions"] as? [String: Any])
        let entryPosition = try #require(text.range(of: "\"entryPoints\":"))
        let functionPosition = try #require(text.range(of: "\"functions\":"))
        #expect(entryPosition.lowerBound < functionPosition.lowerBound)
        for definitions in [entries, helpers] {
            let positions = try definitions.keys.sorted().map { name in
                try #require(text.range(of: "\"\(name)\": {"))
            }
            #expect(positions.map(\.lowerBound) == positions.map(\.lowerBound).sorted())
            for value in definitions.values {
                let definition = try #require(value as? [String: Any])
                #expect(definition["entryPoint"] == nil)
            }
        }
        let result = try runCM(["--config", example.path, "--help"], useConfig: false)
        assertSuccess(result)
        #expect(!result.stdout.contains("BuildAndTest"))
        #expect(result.stdout.contains("CheckPackage"))
    }
}
