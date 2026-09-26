import Foundation

let commandManagerVersion = "0.4"

struct Version: Comparable {
    private let components: [UInt]

    init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt($0) }
        guard text.range(of: "\\A[0-9]+\\.[0-9]+(?:\\.[0-9]+)?\\z", options: .regularExpression) != nil,
            numbers.count == parts.count
        else {
            throw CommandError(
                "Invalid version '\(text)'; expected major.minor or major.minor.patch using nonnegative integers.")
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

func validateMinimumVersion(_ minimum: String?) throws {
    guard let minimum else { return }
    guard try Version(commandManagerVersion) >= Version(minimum) else {
        throw CommandError(
            "This configuration requires CommandManager \(minimum) or later; installed version is \(commandManagerVersion). Upgrade cm before using this configuration."
        )
    }
}
