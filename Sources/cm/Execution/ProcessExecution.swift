import Darwin
import Foundation

/// Inherit the caller's process group so terminal reads and terminal signals work normally.
func runInheritedCommand(
    _ executable: String, arguments: [String], directory: URL, environment: [String: String], stdoutFD: Int32? = nil
) throws -> Int32 {
    try validateProcessArguments([executable] + arguments)
    let path = try executableURL(executable, directory: directory, environment: environment).path
    var actions: posix_spawn_file_actions_t?
    try checkSpawn(posix_spawn_file_actions_init(&actions), executable: executable)
    defer { posix_spawn_file_actions_destroy(&actions) }
    try checkSpawn(addWorkingDirectory(&actions, path: directory.path), executable: executable)
    if let stdoutFD {
        try checkSpawn(posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO), executable: executable)
        try checkSpawn(posix_spawn_file_actions_addclose(&actions, stdoutFD), executable: executable)
    }
    var pid: pid_t = 0
    var attributes: posix_spawnattr_t?
    try checkSpawn(posix_spawnattr_init(&attributes), executable: executable)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGINT)
    sigaddset(&defaults, SIGQUIT)
    try checkSpawn(posix_spawnattr_setsigdefault(&attributes, &defaults), executable: executable)
    try checkSpawn(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF)), executable: executable)
    // Like system(3): let the foreground child handle terminal interrupts while cm waits.
    let previousInterrupt = signal(SIGINT, SIG_IGN)
    let previousQuit = signal(SIGQUIT, SIG_IGN)
    defer {
        signal(SIGINT, previousInterrupt)
        signal(SIGQUIT, previousQuit)
    }
    try withCStringArray([executable] + arguments) { argv in
        try withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { environment in
            // No SETPGROUP flag: unlike Foundation.Process, keep the existing foreground job.
            try checkSpawn(posix_spawn(&pid, path, &actions, &attributes, argv, environment), executable: executable)
        }
    }
    return try waitForCommand(pid)
}

func addWorkingDirectory(_ actions: inout posix_spawn_file_actions_t?, path: String) -> Int32 {
    #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return posix_spawn_file_actions_addchdir(&actions, path)
        } else {
            return posix_spawn_file_actions_addchdir_np(&actions, path)
        }
    #else
        return posix_spawn_file_actions_addchdir_np(&actions, path)
    #endif
}

func withCStringArray<Result>(
    _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) throws -> Result {
    var pointers = strings.map { strdup($0) }
    defer {
        for pointer in pointers { free(pointer) }
    }
    guard pointers.allSatisfy({ $0 != nil }) else { throw CommandError("Cannot allocate command arguments.") }
    pointers.append(nil)
    return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
}

func checkSpawn(_ status: Int32, executable: String) throws {
    guard status == 0 else {
        throw CommandError("Cannot run command '\(executable)': \(String(cString: strerror(status)))", status: 126)
    }
}

func waitForCommand(_ pid: pid_t) throws -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        guard errno == EINTR else {
            throw CommandError("Cannot wait for command: \(String(cString: strerror(errno)))")
        }
    }
    // Darwin's wait status macros are not imported into Swift.
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : min(128 + signal, 255)
}

func makeProcess(_ executable: String, arguments: [String], directory: URL) throws -> Process {
    try validateProcessArguments([executable] + arguments)
    let process = Process()
    process.currentDirectoryURL = directory
    process.executableURL = try executableURL(executable, directory: directory)
    process.arguments = arguments
    return process
}

func validateProcessArguments(_ arguments: [String]) throws {
    guard !arguments.contains(where: { $0.contains("\0") }) else {
        throw CommandError("Command names and arguments cannot contain a NUL character.")
    }
}

func executableURL(_ executable: String, directory: URL, environment: [String: String]? = nil) throws -> URL {
    if executable.contains("/") {
        return URL(fileURLWithPath: executable, relativeTo: directory).absoluteURL
    }
    let searchPath = (environment ?? ProcessInfo.processInfo.environment)["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for component in searchPath.components(separatedBy: ":") {
        let base = component.isEmpty ? directory : URL(fileURLWithPath: component, relativeTo: directory)
        let candidate = base.appendingPathComponent(executable)
        if isExecutableFile(candidate) { return candidate.absoluteURL }
    }
    throw CommandError("Command '\(executable)' was not found in PATH.", status: 127)
}

func isExecutableFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
}

func start(_ process: Process, executable: String) throws {
    do {
        try process.run()
    } catch {
        throw CommandError("Cannot run command '\(executable)': \(error.localizedDescription)", status: 126)
    }
}
