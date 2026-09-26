import Foundation
import Testing

final class ComparisonTests: CMTestCase {
    @Test func testEqualityUsesLiteralAndTemplatedStrings() throws {
        let cases = [("", "", true), ("one", "two", false), ("Case", "case", false), ("two words", "two words", true)]
        for (left, right, equal) in cases {
            try configure([
                "main": function(
                    [
                        ["builtin": "log", "args": ["equal"], "when": ["equals": ["${left}", "${right}"]]],
                        ["builtin": "log", "args": ["different"], "when": ["notEquals": ["${left}", "${right}"]]],
                    ], parameters: ["left", "right"])
            ])
            assertSuccess(try runCM(["main", left, right]), output: equal ? "equal\n" : "different\n")
        }
        try configure([
            "main": function(
                [
                    ["builtin": "log", "args": ["matched"], "when": ["equals": ["prefix-${value}", "prefix-$$value"]]]
                ], parameters: ["value"])
        ])
        assertSuccess(try runCM(["main", "$value"]), output: "matched\n")
    }

    @Test func testComparisonsComposeAndShortCircuitMissingValues() throws {
        var main = function([
            ["builtin": "set", "args": ["unused"], "saveAs": "missing", "when": "enabled"],
            [
                "builtin": "log", "args": ["any"],
                "when": [
                    "any": [
                        ["equals": ["", ""]], ["equals": ["${missing}", "value"]],
                    ]
                ],
            ],
            [
                "builtin": "log", "args": ["unreachable"],
                "when": [
                    "all": [
                        ["notEquals": ["", ""]], ["equals": ["${missing}", "value"]],
                    ]
                ],
            ],
            ["builtin": "log", "args": ["not"], "when": ["not": ["equals": ["a", "b"]]]],
        ])
        main["options"] = ["enabled": "Create optional output"]
        try configure(["main": main])
        assertSuccess(try runCM(["main"]), output: "any\nnot\n")
    }

    @Test func testComparisonSchemaAndUnknownReferencesFailBeforeCommands() throws {
        let invalid: [Any] = [
            [], ["one"], ["one", "two", "three"], [1, 1], NSNull(), "value", ["left": "a", "right": "b"],
            ["${unknown}", "value"], ["${unclosed", "value"], ["bad\0value", "value"],
        ]
        for operation in ["equals", "notEquals"] {
            for operands in invalid {
                try assertInvalidConfiguration([
                    "main": function([
                        markerStep(), ["builtin": "log", "args": ["unreachable"], "when": [operation: operands]],
                    ])
                ])
            }
        }
        try assertInvalidConfiguration([
            "main": function([
                markerStep(),
                [
                    "builtin": "log", "args": ["unreachable"],
                    "when": ["equals": ["a", "a"], "notEquals": ["a", "b"]],
                ],
            ])
        ])
    }

    @Test func testMissingOrStructuredComparisonValuesFailAtRuntime() throws {
        for json in ["{}", "[]", "null"] {
            try configure([
                "main": function([
                    ["command": "/usr/bin/printf", "args": ["%s", json], "capture": "json", "saveAs": "value"],
                    ["builtin": "log", "args": ["unreachable"], "when": ["equals": ["${value}", ""]]],
                    markerStep(),
                ])
            ])
            assertFailure(try runCM(["main"]))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
        var main = function([
            ["builtin": "set", "args": ["unused"], "saveAs": "missing", "when": "enabled"],
            ["builtin": "log", "args": ["unreachable"], "when": ["equals": ["${missing}", ""]]],
            markerStep(),
        ])
        main["options"] = ["enabled": "Create optional output"]
        try configure(["main": main])
        assertFailure(try runCM(["main"]))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testComparisonsRenderJSONScalarsLikeArguments() throws {
        for json in ["true", "false", "42"] {
            try configure([
                "main": function([
                    ["command": "/usr/bin/printf", "args": ["%s", json], "capture": "json", "saveAs": "value"],
                    ["builtin": "log", "args": ["matched"], "when": ["equals": ["${value}", json]]],
                ])
            ])
            assertSuccess(try runCM(["main"]), output: "matched\n")
        }
    }
}
