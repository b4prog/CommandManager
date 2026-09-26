import Foundation
import Testing

final class VersionTests: CMTestCase {
    @Test func testCompatibleMinimumVersionsAreAccepted() throws {
        for minimum in ["0.0", "0.1", "0.1.999", "0.2", "0.2.0", "0.02", "0.3", "0.3.1", "0.4", "0.4.0"] {
            try writeConfiguration(minimum: minimum, steps: [printStep("compatible")])
            assertSuccess(try runCM(["main"]), output: "compatible\n")
        }
    }

    @Test func testNewerMinimumVersionsFailBeforeExecution() throws {
        for minimum in ["0.4.1", "0.5", "0.10", "1.0", "10.0"] {
            try writeConfiguration(minimum: minimum, steps: [markerStep()])
            let result = try runCM(["main"])
            assertFailure(result)
            #expect(result.stderr.contains("requires CommandManager \(minimum) or later"))
            #expect(result.stderr.contains("installed version is 0.4"))
            #expect(result.stdout.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func testNewerMinimumVersionAlsoFailsForHelp() throws {
        try writeConfiguration(minimum: "0.5", steps: [])
        assertFailure(try runCM())
        assertFailure(try runCM(["--help"]))
    }

    @Test func testInvalidMinimumVersionFormatsAreRejected() throws {
        let versions = [
            "", "0", "0.", ".2", "0..2", "0.2.0.0", "v0.2", "-1.0", "0.-2", "0.+2",
            " 0.2", "0.2\n", "0.2-beta", "0.2+build", "999999999999999999999999999999.0",
        ]
        for minimum in versions {
            try writeConfiguration(minimum: minimum, steps: [markerStep()])
            let result = try runCM(["main"])
            assertFailure(result)
            #expect(result.stderr.contains("Invalid version"))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func testMinimumVersionMustBeAStringWhenPresent() throws {
        let versions: [Any] = [0.2, true, NSNull(), ["0.2"], ["major": 0, "minor": 2]]
        for minimum in versions {
            try writeConfiguration(minimum: minimum, steps: [markerStep()])
            assertFailure(try runCM(["main"]))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func testFutureVersionIsReportedBeforeUnknownSchemaFields() throws {
        let document: [String: Any] = ["minimumVersion": "1.0", "futureField": true]
        try JSONSerialization.data(withJSONObject: document).write(to: config)
        let result = try runCM()
        assertFailure(result)
        #expect(result.stderr.contains("requires CommandManager 1.0 or later"))
    }

    private func writeConfiguration(minimum: Any, steps: [[String: Any]]) throws {
        let document: [String: Any] = ["minimumVersion": minimum, "entryPoints": ["main": function(steps)]]
        try JSONSerialization.data(withJSONObject: document).write(to: config)
    }
}
