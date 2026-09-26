import Foundation

func redact(_ text: String, secrets: Set<String>) -> String {
    secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) {
        $0.replacingOccurrences(of: $1, with: "*****")
    }
}

func printCommand(_ executable: String, arguments: [String]) {
    let command = ([executable] + arguments).map(quoteArgument).joined(separator: " ")
    FileHandle.standardOutput.write(Data("\u{1B}[90m❯ \u{1B}[32m\(command)\u{1B}[0m\n".utf8))
}

func quoteArgument(_ argument: String) -> String {
    if argument.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
        return "$'" + argument.unicodeScalars.map(quoteControlCharacter).joined() + "'"
    }
    if argument.range(of: "^[A-Za-z0-9_./:@%+=,-]+$", options: .regularExpression) != nil {
        return argument
    }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func quoteControlCharacter(_ character: Unicode.Scalar) -> String {
    switch character.value {
    case 39: return "\\'"
    case 92: return "\\\\"
    case 10: return "\\n"
    case 13: return "\\r"
    case 9: return "\\t"
    case 0...31, 127: return String(format: "\\x%02x", character.value)
    default: return String(character)
    }
}
