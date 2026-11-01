import Foundation

public enum BottleError: Error, Equatable {
    case invalidID(String)
    case engineMismatch(bottle: String, requested: String)
}

/// A Wine prefix plus the choices made for it. Users never see this; they
/// see the app that lives in it.
public struct Bottle: Codable, Equatable, Sendable {
    public var id: String
    public var wineEngineID: String
    public var layerID: String?
    public var graphics: GraphicsEngine
    /// Environment contributed by the applied recipe (`setEnv` actions).
    public var environment: [String: String]
    /// Digest of the last recipe applied, so unchanged recipes are not reapplied.
    public var appliedRecipeDigest: String?
    public var createdAt: Date
}

public struct BottleStore: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    static func isValid(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    public func directory(for id: String) throws -> URL {
        guard Self.isValid(id) else { throw BottleError.invalidID(id) }
        return root.appendingPathComponent(id)
    }

    public func prefix(for id: String) throws -> URL { try directory(for: id).appendingPathComponent("prefix") }
    private func metadata(for id: String) throws -> URL { try directory(for: id).appendingPathComponent("bottle.json") }

    public func load(_ id: String) throws -> Bottle? {
        let url = try metadata(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Bottle.self, from: Data(contentsOf: url))
    }

    public func save(_ bottle: Bottle) throws {
        let dir = try directory(for: bottle.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(bottle).write(to: try metadata(for: bottle.id), options: .atomic)
    }

    public func list() throws -> [Bottle] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return try names.sorted().compactMap { Self.isValid($0) ? try load($0) : nil }
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: try directory(for: id))
    }
}
