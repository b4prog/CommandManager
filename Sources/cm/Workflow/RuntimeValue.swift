import Foundation

/// Structured results stay structured until explicitly selected or expanded.
indirect enum RuntimeValue: Decodable {
    case string(String)
    case bool(Bool)
    case number(Decimal)
    case array([RuntimeValue])
    case object([String: RuntimeValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RuntimeValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RuntimeValue].self) {
            self = .object(value)
        } else {
            self = .number(try container.decode(Decimal.self))
        }
    }

    func text() throws -> String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return NSDecimalNumber(decimal: value).stringValue
        default: throw CommandError("Expected a scalar value; select a JSON field or explicitly expand a string array.")
        }
    }

    var secretStrings: [String] {
        switch self {
        case .array(let values): return values.flatMap(\.secretStrings)
        case .object(let values): return values.values.flatMap(\.secretStrings)
        case .null: return []
        default: return (try? text()).map { [$0] } ?? []
        }
    }
}

/// Arguments are templates, never shell programs. Inserted values are not parsed again.
struct ArgumentTemplate {
    enum Part {
        case text(String)
        case parameter(String)
    }

    private var parts: [Part] = []

    init(_ source: String) throws {
        var remaining = source[...]
        while let dollar = remaining.firstIndex(of: "$") {
            parts.append(.text(String(remaining[..<dollar])))
            remaining = remaining[remaining.index(after: dollar)...]
            try consumeDollar(from: &remaining)
        }
        parts.append(.text(String(remaining)))
    }

    private mutating func consumeDollar(from remaining: inout Substring) throws {
        switch remaining.first {
        case "$":
            remaining.removeFirst()
            parts.append(.text("$"))
        case "{":
            remaining.removeFirst()
            guard let end = remaining.firstIndex(of: "}") else {
                throw CommandError("Unclosed parameter placeholder; expected ${name}.")
            }
            parts.append(.parameter(String(remaining[..<end])))
            remaining = remaining[remaining.index(after: end)...]
        default:
            parts.append(.text("$"))
        }
    }

    var hasParameters: Bool {
        parts.contains { part in
            if case .parameter = part { return true }
            return false
        }
    }

    func validate(parameters: Set<String>) throws {
        for case .parameter(let name) in parts {
            guard parameters.contains(name) else {
                throw CommandError("Unknown parameter '${\(name)}'. Use $$ to escape a literal dollar sign.")
            }
        }
    }

    func renderRuntime(values: [String: RuntimeValue]) throws -> String {
        try parts.map { part in
            switch part {
            case .text(let value):
                return value
            case .parameter(let name):
                guard let value = values[name] else {
                    throw CommandError("Missing parameter '\(name)'.")
                }
                return try value.text()
            }
        }.joined()
    }
}

func decodeJSON(_ data: Data) throws -> RuntimeValue {
    do { return try JSONDecoder().decode(RuntimeValue.self, from: data) } catch {
        throw CommandError("Cannot decode JSON result.")
    }
}
