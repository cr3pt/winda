import Foundation

/// What a user may change for one program without editing its recipe.
public struct ProgramSettings: Codable, Equatable, Sendable {
    /// nil follows the recipe.
    public var graphics: GraphicsEngine?
    /// Added after the recipe's own launch arguments.
    public var extraArguments: [String]
    public var environment: [String: String]
    /// Treat the Command key as Ctrl, so Cmd+C / Cmd+V work inside Windows programs.
    public var commandIsCtrl: Bool

    public init(graphics: GraphicsEngine? = nil, extraArguments: [String] = [],
                environment: [String: String] = [:], commandIsCtrl: Bool = true) {
        self.graphics = graphics
        self.extraArguments = extraArguments
        self.environment = environment
        self.commandIsCtrl = commandIsCtrl
    }

    static let reservedEnvironment: Set<String> = ["PATH", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "WINEPREFIX", "WINEDLLOVERRIDES", "WINESERVER", "WINE"]

    /// Problems that make these settings unsafe or meaningless; empty when fine.
    public func validate() -> [String] {
        var issues: [String] = []
        if extraArguments.count > 16 { issues.append("at most 16 extra arguments") }
        for a in extraArguments where a.range(of: #"^[A-Za-z0-9/_.:=,+-]+$"#, options: .regularExpression) == nil {
            issues.append("argument '\(a)' has characters that are not allowed")
        }
        for (k, v) in environment {
            if k.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) == nil { issues.append("variable name '\(k)' is invalid") }
            if Self.reservedEnvironment.contains(k) || k.hasPrefix("DYLD_") { issues.append("variable '\(k)' is reserved") }
            if v.contains("\n") || v.contains("\0") { issues.append("variable '\(k)' has an invalid value") }
        }
        return issues
    }

    /// Parses "KEY=value" lines; lines that are blank or start with # are skipped.
    public static func parseEnvironment(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            out[String(l[..<eq])] = String(l[l.index(after: eq)...])
        }
        return out
    }
}

public struct ProgramSettingsStore: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    private func file(_ id: String) throws -> URL {
        guard BottleStore.isValid(id) else { throw BottleError.invalidID(id) }
        return root.appendingPathComponent("\(id).json")
    }

    public func load(_ id: String) -> ProgramSettings {
        guard let url = try? file(id), let d = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(ProgramSettings.self, from: d) else { return ProgramSettings() }
        return s
    }

    public func save(_ s: ProgramSettings, for id: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(s).write(to: try file(id), options: .atomic)
    }
}
