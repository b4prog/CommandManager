import Foundation
import Testing

final class DirectoryAndGitTests: CMTestCase {
    private func makeDirectory(_ path: String) throws -> URL {
        let result = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    @Test func testInFolderDescendsAndCurrentBasenameIsANoop() throws {
        let grandchild = try makeDirectory("child/grandchild")
        let child = grandchild.deletingLastPathComponent()
        try configure([
            "main": function([
                ["builtin": "inFolder", "args": [directory.lastPathComponent]],
                ["command": "/bin/pwd"],
                ["builtin": "inFolder", "args": ["child"]],
                ["builtin": "inFolder", "args": ["child"]],
                ["command": "/bin/pwd"],
                ["builtin": "inFolder", "args": ["grandchild"]],
                ["command": "/bin/pwd"],
            ])
        ])
        assertSuccess(
            try runCM(["main"]), output: "\(directory.path)\n\(child.path)\n\(grandchild.path)\n")
    }

    @Test func testDirectoryChangesContinueThroughTheEntryPoint() throws {
        let grandchild = try makeDirectory("child/grandchild")
        let child = grandchild.deletingLastPathComponent()
        try configure([
            "main": function([
                ["command": "/bin/pwd"], ["function": "helper"], ["command": "/bin/pwd"],
                ["function": "sibling"], ["command": "/bin/pwd"],
            ]),
            "helper": function(
                [["builtin": "inFolder", "args": ["child"]], ["command": "/bin/pwd"]],
                entry: false),
            "sibling": function(
                [
                    ["command": "/bin/pwd"], ["builtin": "inFolder", "args": ["grandchild"]],
                    ["command": "/bin/pwd"],
                ], entry: false),
        ])
        let expected = [directory.path, child.path, child.path, child.path, grandchild.path, grandchild.path]
        assertSuccess(try runCM(["main"]), output: expected.joined(separator: "\n") + "\n")
    }

    @Test func testInFolderRequiresASingleDirectoryName() throws {
        for name in ["", ".", "..", "/tmp", "child/nested", "missing"] {
            try configure([
                "main": function([["builtin": "inFolder", "args": [name]], markerStep()])
            ])
            assertFailure(try runCM(["main"]))
            #expect(!(FileManager.default.fileExists(atPath: marker.path)))
        }
    }

    @Test func testInFolderRejectsFiles() throws {
        try "not a directory".write(
            to: directory.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try configure([
            "main": function([["builtin": "inFolder", "args": ["file"]], markerStep()])
        ])
        assertFailure(try runCM(["main"]))
        #expect(!(FileManager.default.fileExists(atPath: marker.path)))
    }

    @Test func testGitRootAcceptsRootAndRejectsDescendant() throws {
        try initializeRepository()
        let child = try makeDirectory("child")
        try configure(["main": function([["builtin": "assertGitRoot"], printStep("root")])])
        assertSuccess(try runCM(["main"]), output: "root\n")
        assertFailure(try runCM(["main"], cwd: child))
    }

    @Test func testBuiltinGitProbesAreNotEchoed() throws {
        try initializeRepository()
        try configure([
            "main": function([["builtin": "assertGitRoot"], ["builtin": "assertGitRepository"]])
        ])
        let result = try runCM(["main"])
        assertSuccess(result)
        #expect(result.stdout == "")
    }

    @Test func testGitRepositoryAcceptsRootAndDescendant() throws {
        try initializeRepository()
        let child = try makeDirectory("child/nested")
        try configure([
            "main": function([["builtin": "assertGitRepository"], printStep("repository")])
        ])
        assertSuccess(try runCM(["main"]), output: "repository\n")
        assertSuccess(try runCM(["main"], cwd: child), output: "repository\n")
    }

    @Test func testGitAssertionsRejectOutsideRepositoryAndGitMetadata() throws {
        for builtin in ["assertGitRoot", "assertGitRepository"] {
            try configure(["main": function([["builtin": builtin], markerStep()])])
            assertFailure(try runCM(["main"]))
            #expect(!(FileManager.default.fileExists(atPath: marker.path)))
        }
        try initializeRepository()
        for builtin in ["assertGitRoot", "assertGitRepository"] {
            try configure(["main": function([["builtin": builtin], markerStep()])])
            assertFailure(try runCM(["main"], cwd: directory.appendingPathComponent(".git")))
            assertFailure(try runCM(["main"], cwd: directory.appendingPathComponent(".git/objects")))
            #expect(!(FileManager.default.fileExists(atPath: marker.path)))
        }
    }

    @Test func testGitAssertionsAcceptLinkedWorktrees() throws {
        try initializeRepository()
        let worktree = directory.appendingPathComponent("linked-worktree")
        try git(["worktree", "add", "--quiet", "-b", "test-worktree", worktree.path])
        let child = try makeDirectory("linked-worktree/child")
        try configure(["main": function([["builtin": "assertGitRoot"]])])
        assertSuccess(try runCM(["main"], cwd: worktree))
        assertFailure(try runCM(["main"], cwd: child))
        try configure(["main": function([["builtin": "assertGitRepository"]])])
        assertSuccess(try runCM(["main"], cwd: worktree))
        assertSuccess(try runCM(["main"], cwd: child))
    }

    @Test func testGitAssertionsRejectBareRepositories() throws {
        let bare = directory.appendingPathComponent("bare.git")
        try git(["init", "--quiet", "--bare", bare.path])
        for builtin in ["assertGitRoot", "assertGitRepository"] {
            try configure(["main": function([["builtin": builtin]])])
            assertFailure(try runCM(["main"], cwd: bare))
        }
    }

    @Test func testGitAssertionsPreserveNewlinesInRootDirectoryNames() throws {
        let repository = try makeDirectory("repository\n")
        try initializeRepository(cwd: repository)
        try configure([
            "main": function([["builtin": "assertGitRoot"], ["builtin": "assertGitRepository"]])
        ])
        assertSuccess(try runCM(["main"], cwd: repository), output: "")
    }

    @Test func testGitAssertionsIgnoreGitDirectoryOverrides() throws {
        try initializeRepository()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        for builtin in ["assertGitRoot", "assertGitRepository"] {
            try configure(["main": function([["builtin": builtin]])])
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_DIR"] = directory.appendingPathComponent(".git").path
            assertFailure(try runCM(["main"], cwd: outside, environment: environment))
            environment["GIT_DIR"] = directory.appendingPathComponent("missing").path
            assertSuccess(try runCM(["main"], environment: environment), output: "")
        }
    }

    @Test func testGitRepositoryAssertionIgnoresDiscoveryCeiling() throws {
        try initializeRepository()
        let child = try makeDirectory("child")
        try configure(["main": function([["builtin": "assertGitRepository"]])])
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CEILING_DIRECTORIES"] = directory.path
        assertSuccess(try runCM(["main"], cwd: child, environment: environment), output: "")
    }

    @Test func testRunsWithTheSwiftInterpreter() throws {
        try configure(["main": function([printStep("interpreted")])])
        let interpreter = ProcessInfo.processInfo.environment["SWIFT"] ?? "swift"
        let result = try runProcess(
            interpreter,
            arguments: [
                "-module-cache-path", directory.appendingPathComponent("module-cache").path,
                Self.source.path, "--config", config.path, "main",
            ], cwd: directory, timeout: 180)
        assertSuccess(result, output: "interpreted\n")
    }
}
