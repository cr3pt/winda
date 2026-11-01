import Foundation

/// Where WinDA keeps its data. One root, so it can live on any volume.
public struct WinDAPaths: Sendable {
    public var home: URL
    public var engines: URL { home.appendingPathComponent("engines") }
    public var bottles: URL { home.appendingPathComponent("bottles") }
    public var manifests: URL { home.appendingPathComponent("manifests") }
    public var recipes: URL { home.appendingPathComponent("recipes") }
    public var apps: URL { home.appendingPathComponent("Apps") }
    public var logs: URL { home.appendingPathComponent("logs") }
    public var cache: URL { home.appendingPathComponent("cache") }

    public init(home: URL) { self.home = home }

    /// `WINDA_HOME` if set, otherwise ~/Library/Application Support/WinDA.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> WinDAPaths {
        if let h = environment["WINDA_HOME"], !h.isEmpty { return WinDAPaths(home: URL(fileURLWithPath: h)) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WinDAPaths(home: support.appendingPathComponent("WinDA"))
    }
}

/// Recipes found on disk. Invalid files are kept out of `recipes` and listed in `rejected`.
public struct RecipeCatalog: Sendable {
    public var recipes: [Recipe]
    public var rejected: [String]

    public init(recipes: [Recipe], rejected: [String] = []) {
        self.recipes = recipes
        self.rejected = rejected
    }

    public init(directory: URL) {
        var good: [Recipe] = []
        var bad: [String] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        for n in names {
            do {
                let r = try Recipe.decode(from: Data(contentsOf: directory.appendingPathComponent(n)))
                if RecipeValidator.validate(r).isEmpty { good.append(r) } else { bad.append(n) }
            } catch { bad.append(n) }
        }
        self.init(recipes: good, rejected: bad)
    }

    /// A SHA-256 match beats a file-name match. Names compare case-insensitively.
    public func match(exe: URL) -> Recipe? {
        if recipes.contains(where: { !$0.match.sha256.isEmpty }),
           let digest = try? EngineInstaller.sha256(of: exe),
           let r = recipes.first(where: { $0.match.sha256.contains(digest) }) { return r }
        let name = exe.lastPathComponent.lowercased()
        return recipes.first { $0.match.exeNames.contains { $0.lowercased() == name } }
    }

    /// Used when nothing matches: shared bottle, automatic engine, no actions.
    public static func untested(for exe: URL) -> Recipe {
        Recipe(schemaVersion: Recipe.currentSchemaVersion, id: "untested", name: "Untested program", category: .app,
               match: Match(exeNames: [exe.lastPathComponent], sha256: []), engine: EngineSpec(graphics: .auto, package: nil),
               actions: [], rating: .bronze, notes: "No recipe matched; using defaults.")
    }
}
