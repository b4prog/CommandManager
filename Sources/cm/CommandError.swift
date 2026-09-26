import Foundation

struct CommandError: Error, CustomStringConvertible {
    let description: String
    let status: Int32

    init(_ message: String, status: Int32 = 1) {
        description = message
        self.status = status
    }
}

func requireArguments(_ arguments: [String], count: Int, target: String) throws {
    guard arguments.count == count else {
        throw CommandError("\(target) expects \(count) argument(s), received \(arguments.count).")
    }
}
