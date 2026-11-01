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
    /// Runs a program the same recipe downloaded earlier (so it is hash-pinned), e.g. a silent installer.
    case run(path: String, arguments: [String], skipIfExists: String?)
    /// Starts `path` through a small wrapper that appends `arguments` every time (see ExecutableWrapper).
    case wrap(path: String, arguments: [String])
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key, value, verb, name, url, sha256, destination, path, arguments, skipIfExists
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
        case "wrap":
            self = .wrap(path: try c.decode(String.self, forKey: .path),
                         arguments: try c.decodeIfPresent([String].self, forKey: .arguments) ?? [])
        case "run":
            self = .run(path: try c.decode(String.self, forKey: .path),
                        arguments: try c.decodeIfPresent([String].self, forKey: .arguments) ?? [],
                        skipIfExists: try c.decodeIfPresent(String.self, forKey: .skipIfExists))
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
        case let .run(path, arguments, skipIfExists):
            try c.encode("run", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(arguments, forKey: .arguments)
            try c.encodeIfPresent(skipIfExists, forKey: .skipIfExists)
        case let .wrap(path, arguments):
            try c.encode("wrap", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(arguments, forKey: .arguments)
        }
    }
}

/// How to start an installed program (a launcher such as Steam), as opposed to a dropped `.exe`.
public struct LaunchSpec: Codable, Equatable, Sendable {
    /// Windows path, e.g. `C:\Program Files (x86)\Steam\steam.exe`.
    public var program: String
    public var arguments: [String]
    /// Arguments that make the running program quit cleanly (Steam: `-shutdown`). Used by Stop so the
    /// program can finish what it is doing instead of being killed.
    public var shutdown: [String]?

    public init(program: String, arguments: [String] = [], shutdown: [String]? = nil) {
        self.program = program
        self.arguments = arguments
        self.shutdown = shutdown
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
    public var launch: LaunchSpec?

    public static let currentSchemaVersion = 1

    public static func decode(from data: Data) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: data)
    }
}
