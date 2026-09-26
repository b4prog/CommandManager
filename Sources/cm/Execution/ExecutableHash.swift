import CryptoKit
import Foundation

/// Hash the executable selected by command resolution without launching it.
func executableHash(_ executable: String, directory: URL, environment: [String: String]) throws -> String {
    try validateProcessArguments([executable])
    guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CommandError("executableHash requires a nonempty executable name or path.")
    }
    let path: URL
    do {
        path = try executableURL(executable, directory: directory, environment: environment)
    } catch let error as CommandError where error.status == 127 {
        return ""
    }
    guard isExecutableFile(path) else { return "" }
    let resolved = path.resolvingSymlinksInPath()
    let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw CommandError("executableHash requires a regular file at '\(resolved.path)'.")
    }
    let handle = try FileHandle(forReadingFrom: resolved)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
        hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
