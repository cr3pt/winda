import Foundation

/// Where WinDA keeps its data. Everything sits under one home folder unless a
/// location is set separately (for example Windows apps on a large external volume).
public struct WinDAPaths: Sendable {
    public var home: URL
    public var bottlesOverride: URL?
    public var enginesOverride: URL?
    public var appsOverride: URL?

    public var engines: URL { enginesOverride ?? home.appendingPathComponent("engines") }
    public var bottles: URL { bottlesOverride ?? home.appendingPathComponent("bottles") }
    public var manifests: URL { home.appendingPathComponent("manifests") }
    public var recipes: URL { home.appendingPathComponent("recipes") }
    public var apps: URL { appsOverride ?? home.appendingPathComponent("Apps") }
    public var logs: URL { home.appendingPathComponent("logs") }
    public var cache: URL { engines.appendingPathComponent(".cache") }

    public init(home: URL, bottles: URL? = nil, engines: URL? = nil, apps: URL? = nil) {
        self.home = home
        self.bottlesOverride = bottles
        self.enginesOverride = engines
        self.appsOverride = apps
    }

    public static var defaultHome: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WinDA")
    }

    /// `WINDA_HOME` wins (used for development and tests), then saved locations, then the default.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               saved: WinDALocations? = nil) -> WinDAPaths {
        if let h = environment["WINDA_HOME"], !h.isEmpty { return WinDAPaths(home: URL(fileURLWithPath: h)) }
        if let s = saved { return s.paths }
        return WinDAPaths(home: defaultHome)
    }
}

/// What the user chose on the setup screen. Folders left nil follow the home folder.
public struct WinDALocations: Codable, Equatable, Sendable {
    public var home: String
    public var bottles: String?
    public var engines: String?
    public var apps: String?

    public init(home: String, bottles: String? = nil, engines: String? = nil, apps: String? = nil) {
        self.home = home
        self.bottles = bottles
        self.engines = engines
        self.apps = apps
    }

    public var paths: WinDAPaths {
        func u(_ s: String?) -> URL? { s.map { URL(fileURLWithPath: $0) } }
        return WinDAPaths(home: URL(fileURLWithPath: home), bottles: u(bottles), engines: u(engines), apps: u(apps))
    }
}

public struct LocationStore: Sendable {
    nonisolated(unsafe) let defaults: UserDefaults
    static let key = "winda.locations"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> WinDALocations? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(WinDALocations.self, from: $0) }
    }

    public func save(_ l: WinDALocations) throws {
        defaults.set(try JSONEncoder().encode(l), forKey: Self.key)
    }
}

public struct LocationCheck: Equatable, Sendable {
    public var writable: Bool
    /// Free space available to the user on the volume, when it can be read.
    public var freeBytes: Int64?
    public var lowSpace: Bool { (freeBytes ?? Int64.max) < Self.recommendedBytes }
    /// Steam alone grows to a few GB after its first update; games add far more.
    public static let recommendedBytes: Int64 = 20 * 1024 * 1024 * 1024

    /// Like `check` but creates nothing: looks at the nearest folder that already exists.
    /// Meant for showing free space while the user is still choosing.
    public static func preview(_ url: URL) -> LocationCheck {
        let fm = FileManager.default
        var dir = url.standardizedFileURL
        while !fm.fileExists(atPath: dir.path), dir.path != "/" { dir = dir.deletingLastPathComponent() }
        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return LocationCheck(writable: fm.isWritableFile(atPath: dir.path), freeBytes: free)
    }

    /// Creates the folder if needed and proves it is writable.
    public static func check(_ url: URL) -> LocationCheck {
        let fm = FileManager.default
        var writable = false
        if (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
            let probe = url.appendingPathComponent(".winda-probe-\(UUID().uuidString)")
            if fm.createFile(atPath: probe.path, contents: Data()) { writable = true; try? fm.removeItem(at: probe) }
        }
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return LocationCheck(writable: writable, freeBytes: free)
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
