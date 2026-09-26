import Foundation

/// Comparison operands are string templates, with the same scalar rendering as arguments.
struct StringComparison: Decodable {
    private let left: ArgumentTemplate
    private let right: ArgumentTemplate

    init(from decoder: Decoder) throws {
        let operands = try decoder.singleValueContainer().decode([String].self)
        try requireArguments(operands, count: 2, target: "Comparison")
        try validateProcessArguments(operands)
        left = try ArgumentTemplate(operands[0])
        right = try ArgumentTemplate(operands[1])
    }

    func validate(_ names: Set<String>) throws {
        try left.validate(parameters: names)
        try right.validate(parameters: names)
    }

    func matches(_ values: [String: RuntimeValue]) throws -> Bool {
        try left.renderRuntime(values: values) == right.renderRuntime(values: values)
    }
}
