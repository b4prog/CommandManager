import Darwin
import Foundation

do {
    try main(Array(CommandLine.arguments.dropFirst()))
} catch let error as CommandError {
    FileHandle.standardError.write(Data("cm: \(error)\n".utf8))
    exit(error.status)
} catch {
    FileHandle.standardError.write(Data("cm: \(error.localizedDescription)\n".utf8))
    exit(1)
}
