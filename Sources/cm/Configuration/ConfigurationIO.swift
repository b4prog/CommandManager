import Foundation

struct JSONKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

extension KeyedDecodingContainer {
    func decodeIfDefined<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}

func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: JSONKey.self)
    let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        let location = decoder.codingPath.map(\.stringValue).joined(separator: ".")
        throw CommandError(
            "Unknown JSON field(s) at \(location.isEmpty ? "root" : location): \(unknown.sorted().joined(separator: ", "))."
        )
    }
}

func configurationURL(_ explicitPath: String?) throws -> URL {
    if let explicitPath {
        let path = (explicitPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    let directory = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    )
    return directory.appendingPathComponent("CommandManager/cm.json")
}

func loadConfiguration(at url: URL) throws -> Configuration {
    do {
        let data = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        try configuration.validate()
        return configuration
    } catch let error as CommandError {
        throw CommandError("Invalid configuration '\(url.path)': \(error)")
    } catch let error as DecodingError {
        throw CommandError("Invalid JSON configuration '\(url.path)': \(describeDecodingError(error))")
    } catch {
        throw CommandError("Cannot read configuration '\(url.path)': \(error.localizedDescription)")
    }
}

func describeDecodingError(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, let context):
        return "Missing '\(key.stringValue)' at \(decodingLocation(context))."
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        return "\(decodingLocation(context)): \(context.debugDescription)"
    @unknown default:
        return String(describing: error)
    }
}

func decodingLocation(_ context: DecodingError.Context) -> String {
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    return path.isEmpty ? "root" : path
}
