import Foundation

public enum GraphicsEngine: String, Codable, Sendable {
    case auto, d3dmetal, dxvk
}

public enum Category: String, Codable, Sendable {
    case game, app
}

public enum Rating: String, Codable, Sendable {
    case platinum, gold, silver, bronze, broken
    case incompatibleAntiCheat = "incompatible-anticheat"
}

public struct Match: Codable, Equatable, Sendable {
    public var exeNames: [String]
    public var sha256: [String]
}

public struct EngineSpec: Codable, Equatable, Sendable {
    public var graphics: GraphicsEngine
    /// Pinned engine package, e.g. "wine-gcenx-10.0".
    public var package: String?
}

/// Closed set of actions. Recipes cannot carry scripts; new capabilities
/// are added here, in the app, never in recipe files.
public enum Action: Equatable, Sendable {
    case setEnv(key: String, value: String)
    case winetricks(verb: String)
    case registry(key: String, name: String, value: String)
    case download(url: URL, sha256: String, destination: String)
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key, value, verb, name, url, sha256, destination
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "setEnv":
            self = .setEnv(key: try c.decode(String.self, forKey: .key),
                           value: try c.decode(String.self, forKey: .value))
        case "winetricks":
            self = .winetricks(verb: try c.decode(String.self, forKey: .verb))
        case "registry":
            self = .registry(key: try c.decode(String.self, forKey: .key),
                             name: try c.decode(String.self, forKey: .name),
                             value: try c.decode(String.self, forKey: .value))
        case "download":
            self = .download(url: try c.decode(URL.self, forKey: .url),
                             sha256: try c.decode(String.self, forKey: .sha256),
                             destination: try c.decode(String.self, forKey: .destination))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown action type '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .setEnv(key, value):
            try c.encode("setEnv", forKey: .type)
            try c.encode(key, forKey: .key)
            try c.encode(value, forKey: .value)
        case let .winetricks(verb):
            try c.encode("winetricks", forKey: .type)
            try c.encode(verb, forKey: .verb)
        case let .registry(key, name, value):
            try c.encode("registry", forKey: .type)
            try c.encode(key, forKey: .key)
            try c.encode(name, forKey: .name)
            try c.encode(value, forKey: .value)
        case let .download(url, sha256, destination):
            try c.encode("download", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(sha256, forKey: .sha256)
            try c.encode(destination, forKey: .destination)
        }
    }
}

public struct Recipe: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var category: Category
    public var match: Match
    public var engine: EngineSpec
    public var actions: [Action]
    public var rating: Rating
    public var notes: String?

    public static let currentSchemaVersion = 1

    public static func decode(from data: Data) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: data)
    }
}
