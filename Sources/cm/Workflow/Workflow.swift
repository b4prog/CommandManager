import Foundation

struct Step: Decodable {
    enum Target {
        case command(String)
        case function(String)
        case builtin(String)
    }

    let target: Target
    let args: [StepArgument]
    let when: Condition?
    let saveAs: String?
    let capture: CaptureMode?
    let sensitive: Bool
    let label: String?

    enum CodingKeys: String, CodingKey {
        case command, function, builtin, args, when, saveAs, capture, sensitive, label
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder,
            allowed: ["command", "function", "builtin", "args", "when", "saveAs", "capture", "sensitive", "label"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let targets: [Target] = try [
            container.decodeIfDefined(String.self, forKey: .command).map(Target.command),
            container.decodeIfDefined(String.self, forKey: .function).map(Target.function),
            container.decodeIfDefined(String.self, forKey: .builtin).map(Target.builtin),
        ].compactMap { $0 }
        guard targets.count == 1, let target = targets.first else {
            throw CommandError("Each step must specify exactly one of command, function, or builtin.")
        }
        self.target = target
        args = try container.decodeIfDefined([StepArgument].self, forKey: .args) ?? []
        when = try container.decodeIfDefined(Condition.self, forKey: .when)
        saveAs = try container.decodeIfDefined(String.self, forKey: .saveAs)
        capture = try container.decodeIfDefined(CaptureMode.self, forKey: .capture)
        sensitive = try container.decodeIfDefined(Bool.self, forKey: .sensitive) ?? false
        label = try container.decodeIfDefined(String.self, forKey: .label)
    }
}

enum CaptureMode: String, Decodable {
    case text, trimmed, json
}

/// Keeps option syntax distinct from runtime data until function arguments are bound.
struct RenderedArgument {
    let value: String
    let allowsOptionParsing: Bool
}

enum StepArgument: Decodable {
    case template(String)
    case spread(String)

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self = .template(value)
        } else {
            try rejectUnknownKeys(decoder, allowed: ["spread"])
            let container = try decoder.container(keyedBy: JSONKey.self)
            self = .spread(try container.decode(String.self, forKey: JSONKey(stringValue: "spread")!))
        }
    }

    func validate(_ names: Set<String>) throws {
        switch self {
        case .template(let text):
            try validateProcessArguments([text])
            try ArgumentTemplate(text).validate(parameters: names)
        case .spread(let name):
            guard names.contains(name) else { throw CommandError("Unknown array '\(name)'.") }
        }
    }

    func render(_ values: [String: RuntimeValue]) throws -> [RenderedArgument] {
        switch self {
        case .template(let text):
            let template = try ArgumentTemplate(text)
            return [
                RenderedArgument(
                    value: try template.renderRuntime(values: values), allowsOptionParsing: !template.hasParameters)
            ]
        case .spread(let name):
            guard case .array(let array) = values[name] else { throw CommandError("Expected string array '\(name)'.") }
            return try array.map { value in
                guard case .string(let text) = value else {
                    throw CommandError("Array '\(name)' must contain only strings.")
                }
                return RenderedArgument(value: text, allowsOptionParsing: false)
            }
        }
    }

    var literal: String? {
        if case .template(let value) = self { return value }
        return nil
    }
}

indirect enum Condition: Decodable {
    case value(String)
    case any([Condition])
    case all([Condition])
    case not(Condition)
    case equals(StringComparison)
    case notEquals(StringComparison)

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = .value(name)
            return
        }
        try rejectUnknownKeys(decoder, allowed: ["any", "all", "not", "equals", "notEquals"])
        let container = try decoder.container(keyedBy: JSONKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw CommandError("A condition requires exactly one of any, all, not, equals, or notEquals.")
        }
        switch key.stringValue {
        case "any": self = .any(try container.decode([Condition].self, forKey: key))
        case "all": self = .all(try container.decode([Condition].self, forKey: key))
        case "not": self = .not(try container.decode(Condition.self, forKey: key))
        case "equals": self = .equals(try container.decode(StringComparison.self, forKey: key))
        default: self = .notEquals(try container.decode(StringComparison.self, forKey: key))
        }
    }

    func validate(_ names: Set<String>) throws {
        switch self {
        case .value(let name):
            guard names.contains(name) else { throw CommandError("Unknown condition value '\(name)'.") }
        case .any(let conditions), .all(let conditions):
            guard !conditions.isEmpty else { throw CommandError("Condition lists must not be empty.") }
            for condition in conditions { try condition.validate(names) }
        case .not(let condition): try condition.validate(names)
        case .equals(let comparison), .notEquals(let comparison): try comparison.validate(names)
        }
    }

    func evaluate(_ values: [String: RuntimeValue]) throws -> Bool {
        switch self {
        case .value(let name):
            guard let value = values[name] else { throw CommandError("Missing condition value '\(name)'.") }
            switch value {
            case .bool(let bool): return bool
            case .string("true"): return true
            case .string("false"): return false
            default: throw CommandError("Condition '\(name)' must be a boolean or the string true/false.")
            }
        case .any(let conditions): return try conditions.contains { try $0.evaluate(values) }
        case .all(let conditions): return try conditions.allSatisfy { try $0.evaluate(values) }
        case .not(let condition): return try !condition.evaluate(values)
        case .equals(let comparison): return try comparison.matches(values)
        case .notEquals(let comparison): return try !comparison.matches(values)
        }
    }
}
