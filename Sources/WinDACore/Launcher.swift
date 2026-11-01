import Foundation

public enum LaunchError: Error, Equatable {
    case invalidRecipe([String])
    case engineNotInstalled(String)
    case noLaunchSpec(String)
}

/// A bottle with its recipe applied, ready to run programs.
public struct PreparedBottle: Sendable {
    public var bottle: Bottle
    public var runner: WineRunner
}

/// Ties everything together: pick engines for a recipe, make or reuse the
/// bottle, apply the recipe, run the program.
public struct Launcher: Sendable {
    public var manifests: [EngineManifest]
    public var engineRoot: URL
    public var bottles: BottleStore
    /// Shared download cache for winetricks.
    public var cache: URL?

    public init(manifests: [EngineManifest], engineRoot: URL, bottles: BottleStore, cache: URL? = nil) {
        self.manifests = manifests
        self.engineRoot = engineRoot
        self.bottles = bottles
        self.cache = cache
    }

    func installed() -> [EngineManifest] {
        let installer = EngineInstaller(root: engineRoot)
        return manifests.filter { installer.isInstalled($0) }
    }

    /// True once the bottle for `recipe` exists with this exact recipe applied.
    public func isPrepared(_ recipe: Recipe, bottleID: String? = nil) -> Bool {
        guard let b = try? bottles.load(bottleID ?? recipe.id),
              let digest = try? RecipeApplier.digest(of: recipe) else { return false }
        return b.appliedRecipeDigest == digest
    }

    /// Creates the bottle if needed and applies the recipe. `bottleID` defaults to the
    /// recipe id, so each recipe gets its own bottle.
    public func prepare(recipe: Recipe, bottleID: String? = nil) async throws -> PreparedBottle {
        let issues = RecipeValidator.validate(recipe)
        guard issues.isEmpty else { throw LaunchError.invalidRecipe(issues.map(\.message)) }

        let avail = installed()
        let choice = try EngineSelector.select(recipe.engine.graphics,
                                               wines: avail.filter { $0.kind == .wine },
                                               layers: avail.filter { $0.kind == .graphicsLayer })
        let id = bottleID ?? recipe.id
        let prefix = try bottles.prefix(for: id)
        let wine = try choice.wine.resolveWine(root: engineRoot)
        var runner = WineRunner(engine: wine, prefix: prefix)

        var bottle: Bottle
        var overrides = "mscoree,mshtml="
        if let existing = try bottles.load(id) {
            guard existing.wineEngineID == choice.wine.id else {
                throw BottleError.engineMismatch(bottle: existing.wineEngineID, requested: choice.wine.id)
            }
            bottle = existing
            if let layer = choice.layer { overrides += ";" + (layer.dllOverrides ?? []).joined(separator: ";") }
        } else {
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            _ = try runner.createPrefix()
            if let layer = choice.layer {
                let o = try LayerInstaller.install(layer, packageRoot: engineRoot, prefix: prefix)
                overrides += ";" + o
            }
            bottle = Bottle(id: id, wineEngineID: choice.wine.id, layerID: choice.layer?.id,
                            graphics: choice.graphics, environment: [:], appliedRecipeDigest: nil, createdAt: Date())
        }
        runner.extraEnvironment = ["WINEDLLOVERRIDES": overrides]

        let digest = try RecipeApplier.digest(of: recipe)
        if bottle.appliedRecipeDigest != digest {
            var tricks: WinetricksRunner?
            if let tool = avail.first(where: { $0.kind == .tool && $0.id.hasPrefix("winetricks") }),
               let script = try? tool.resolveTool(root: engineRoot) {
                tricks = WinetricksRunner(script: script, engine: wine, prefix: prefix,
                                          cache: cache ?? engineRoot.appendingPathComponent(".cache"))
            }
            bottle.environment = try await RecipeApplier(runner: runner, winetricks: tricks).apply(recipe)
            bottle.appliedRecipeDigest = digest
            try bottles.save(bottle)
        }
        runner.extraEnvironment.merge(bottle.environment) { current, _ in current }
        return PreparedBottle(bottle: bottle, runner: runner)
    }

    /// Runs a dropped program in the recipe's bottle.
    @discardableResult
    public func launch(recipe: Recipe, program: [String], bottleID: String? = nil) async throws -> WineResult {
        try await prepare(recipe: recipe, bottleID: bottleID).runner.run(program)
    }

    /// Starts what the recipe says to start (for launchers such as Steam).
    @discardableResult
    public func open(recipe: Recipe, bottleID: String? = nil, timeout: TimeInterval = 86_400) async throws -> WineResult {
        guard let spec = recipe.launch else { throw LaunchError.noLaunchSpec(recipe.id) }
        return try await prepare(recipe: recipe, bottleID: bottleID).runner.run([spec.program] + spec.arguments, timeout: timeout)
    }
}
