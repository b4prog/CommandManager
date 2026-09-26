import Foundation
import Testing

final class ExecutableHashTests: CMTestCase {
    private let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private func makeExecutable(_ name: String, contents: Data) throws -> URL {
        let path = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private func configureHash(_ executable: String) throws {
        try configure([
            "main": function([
                ["builtin": "executableHash", "args": [executable], "saveAs": "hash"],
                printStep("${hash}"),
            ])
        ])
    }

    @Test func testKnownHashesAndSymlinksWithoutLaunchingExecutable() throws {
        let target = try makeExecutable("target", contents: Data("abc".utf8))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        for name in [target.path, "./target", "./link"] {
            try configureHash(name)
            assertSuccess(try runCM(["main"]), output: abcHash + "\n")
        }
        let empty = try makeExecutable("empty", contents: Data())
        try configureHash(empty.path)
        assertSuccess(try runCM(["main"]), output: emptyHash + "\n")
    }

    @Test func testHashUsesExportedPathOrderAndRelativeComponents() throws {
        let first = try makeExecutable("first/tool", contents: Data("abc".utf8))
        let second = try makeExecutable("second/tool", contents: Data())
        try configure([
            "main": function([
                ["builtin": "export", "args": ["PATH", "first:second"]],
                ["builtin": "executableHash", "args": ["tool"], "saveAs": "first"],
                ["builtin": "export", "args": ["PATH", second.deletingLastPathComponent().path]],
                ["builtin": "executableHash", "args": ["tool"], "saveAs": "second"],
                printStep("${first}|${second}"),
            ])
        ])
        assertSuccess(try runCM(["main"]), output: abcHash + "|" + emptyHash + "\n")
        try configureHash("tool")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ":/nonexistent"
        assertSuccess(
            try runCM(["main"], cwd: first.deletingLastPathComponent(), environment: environment),
            output: abcHash + "\n")
    }

    @Test func testMissingAndNonExecutableFilesReturnEmptyHash() throws {
        let file = try makeExecutable("not-executable", contents: Data("abc".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        for name in ["missing-command", "./missing-file", "not-executable", file.path, directory.path] {
            try configureHash(name)
            assertSuccess(try runCM(["main"], environment: environment), output: "\n")
        }
    }

    @Test func testUnreadableExecutableFailsInsteadOfReturningEmpty() throws {
        let file = try makeExecutable("unreadable", contents: Data("abc".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        try configure([
            "main": function([
                ["builtin": "executableHash", "args": [file.path], "saveAs": "hash"],
                markerStep(),
            ])
        ])
        assertFailure(try runCM(["main"]))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testLargeExecutableIsHashedAcrossChunks() throws {
        let file = try makeExecutable("large", contents: Data(repeating: 97, count: 1_000_000))
        try configureHash(file.path)
        assertSuccess(try runCM(["main"]), output: "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0\n")
    }

    @Test func testExecutableHashRequiresOneArgumentAndSavedResult() throws {
        let invalid: [[String: Any]] = [
            ["builtin": "executableHash", "saveAs": "hash"],
            ["builtin": "executableHash", "args": ["one", "two"], "saveAs": "hash"],
            ["builtin": "executableHash", "args": ["tool"]],
        ]
        for step in invalid {
            try assertInvalidConfiguration(["main": function([markerStep(), step])])
        }
        try configureHash("")
        assertFailure(try runCM(["main"]))
    }

    @Test func testHashComparisonDetectsNewChangedAndUnchangedExecutables() throws {
        let target = directory.appendingPathComponent("installed")
        let replacement = try makeExecutable("replacement", contents: Data("abc".utf8))
        for initial in [nil, "abc", "old"] as [String?] {
            if let initial {
                _ = try makeExecutable("installed", contents: Data(initial.utf8))
            }
            try configure([
                "main": function([
                    ["builtin": "executableHash", "args": [target.path], "saveAs": "before"],
                    ["command": "/bin/cp", "args": [replacement.path, target.path]],
                    ["builtin": "executableHash", "args": [target.path], "saveAs": "after"],
                    [
                        "command": "/usr/bin/touch", "args": [marker.path],
                        "when": [
                            "all": [
                                ["notEquals": ["${after}", ""]], ["notEquals": ["${before}", "${after}"]],
                            ]
                        ],
                    ],
                ])
            ])
            assertSuccess(try runCM(["main"]))
            #expect(FileManager.default.fileExists(atPath: marker.path) == (initial != "abc"))
            try? FileManager.default.removeItem(at: marker)
            try FileManager.default.removeItem(at: target)
        }
    }
}
