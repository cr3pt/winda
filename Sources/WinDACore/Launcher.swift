import Foundation

public enum LaunchError: Error, Equatable {
    case invalidRecipe([String])
    case engineNotInstalled(String)
    case noLaunchSpec(String)
    case invalidSettings([String])
}

/// A bottle with its recipe applied, ready to run programs.
public struct PreparedBottle: Sendable {
    public var bottle: Bottle
    public var runner: WineRunner
}

public enum EngineSwitchError: Error, Equatable {
    case notAvailable(String)
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
    public func prepare(recipe: Recipe, bottleID: String? = nil, graphics: GraphicsEngine? = nil) async throws -> PreparedBottle {
        let issues = RecipeValidator.validate(recipe)
        guard issues.isEmpty else { throw LaunchError.invalidRecipe(issues.map(\.message)) }

        let avail = installed()
        // An existing bottle keeps the graphics path it was set up with, unless the caller asks for another.
        let existingGraphics = try bottles.load(bottleID ?? recipe.id).map(\.graphics)
        let choice = try EngineSelector.select(graphics ?? existingGraphics ?? recipe.engine.graphics,
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
        if choice.graphics == .d3dmetal { overrides += ";d3d9,d3d10core,d3d11,d3d12,d3d12core,dxgi=b" }
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
        // Programs may replace a wrapped file when they update; put the wrapper back before every start.
        for case let .wrap(path, arguments) in recipe.actions {
            try? ExecutableWrapper.ensure(prefix: prefix, path: path, arguments: arguments)
        }
        return PreparedBottle(bottle: bottle, runner: runner)
    }

    /// Re-points an existing bottle at the engine that provides `graphics` (for example D3DMetal instead of DXVK).
    /// The prefix and everything installed in it stay; only the Wine build and graphics layer change.
    public func switchGraphics(recipe: Recipe, to graphics: GraphicsEngine, bottleID: String? = nil) throws {
        let id = bottleID ?? recipe.id
        guard var bottle = try bottles.load(id) else { return }
        let avail = installed()
        let choice: EngineChoice
        do {
            choice = try EngineSelector.select(graphics, wines: avail.filter { $0.kind == .wine },
                                               layers: avail.filter { $0.kind == .graphicsLayer })
        } catch { throw EngineSwitchError.notAvailable(graphics.rawValue) }
        if let layer = choice.layer {
            _ = try LayerInstaller.install(layer, packageRoot: engineRoot, prefix: try bottles.prefix(for: id))
        }
        bottle.wineEngineID = choice.wine.id
        bottle.layerID = choice.layer?.id
        bottle.graphics = choice.graphics
        try bottles.save(bottle)
    }

    /// Stops the recipe's bottle. A program that can quit cleanly (recipe `launch.shutdown`) is asked to first and
    /// given time to finish; only what is left after that is killed. Killing Steam mid-update makes it download
    /// its whole client again on the next start.
    public func stop(recipe: Recipe, bottleID: String? = nil, gracePeriod: TimeInterval = 45) {
        let id = bottleID ?? recipe.id
        guard let bottle = try? bottles.load(id),
              let manifest = manifests.first(where: { $0.id == bottle.wineEngineID }),
              let wine = try? manifest.resolveWine(root: engineRoot),
              let prefix = try? bottles.prefix(for: id) else { return }
        let runner = WineRunner(engine: wine, prefix: prefix)
        if let spec = recipe.launch, let shutdown = spec.shutdown, !shutdown.isEmpty {
            _ = try? runner.run([spec.program] + shutdown, timeout: 20)
            runner.waitForExit(timeout: gracePeriod)
        }
        runner.stopAll()
    }

    /// Runs a dropped program in the recipe's bottle.
    @discardableResult
    public func launch(recipe: Recipe, program: [String], bottleID: String? = nil) async throws -> WineResult {
        try await prepare(recipe: recipe, bottleID: bottleID).runner.run(program)
    }

    /// Starts what the recipe says to start (for launchers such as Steam).
    @discardableResult
    public func open(recipe: Recipe, settings: ProgramSettings = ProgramSettings(), extraArguments: [String] = [],
                     bottleID: String? = nil, timeout: TimeInterval = 86_400) async throws -> WineResult {
        guard let spec = recipe.launch else { throw LaunchError.noLaunchSpec(recipe.id) }
        let issues = settings.validate() + ProgramSettings(extraArguments: extraArguments).validate()
        guard issues.isEmpty else { throw LaunchError.invalidSettings(issues) }
        if let g = settings.graphics, let b = try bottles.load(bottleID ?? recipe.id), b.graphics != g {
            try switchGraphics(recipe: recipe, to: g, bottleID: bottleID)
        }
        var prepared = try await prepare(recipe: recipe, bottleID: bottleID, graphics: settings.graphics)
        prepared.runner.extraEnvironment.merge(settings.environment) { _, new in new }
        try Self.applyCommandKey(settings.commandIsCtrl, runner: prepared.runner)
        return try prepared.runner.run([spec.program] + spec.arguments + settings.extraArguments + extraArguments, timeout: timeout)
    }

    /// Writes the Mac driver options only when they differ from what the bottle already has.
    static func applyCommandKey(_ enabled: Bool, runner: WineRunner) throws {
        let reg = runner.prefix.appendingPathComponent("user.reg")
        let text = (try? String(contentsOf: reg, encoding: .utf8)) ?? ""
        let has = text.contains("\"LeftCommandIsCtrl\"=\"y\"")
        guard enabled != has else { return }
        for key in ["LeftCommandIsCtrl", "RightCommandIsCtrl"] {
            let args = enabled ? ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", key, "/d", "y", "/f"]
                               : ["reg", "delete", "HKCU\\Software\\Wine\\Mac Driver", "/v", key, "/f"]
            _ = try runner.run(args, timeout: 60)
        }
    }
}
