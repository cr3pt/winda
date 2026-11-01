import AppKit
import Foundation
import Observation
import WinDACore

@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle, running
        case finished(Int32)
        case failed(String)
    }

    var paths: WinDAPaths
    private let locationStore = LocationStore()
    /// True until the user has chosen where WinDA keeps its files (skipped when WINDA_HOME is set).
    var needsSetup: Bool
    var showSetup = false
    var pendingInstall: Recipe?
    var busyPrograms: Set<String> = []
    var runningPrograms: Set<String> = []
    /// Games found in each launcher's library, by recipe id.
    var games: [String: [SteamGame]] = [:]
    /// The program whose settings sheet is open.
    var editingSettings: Recipe?
    var manifests: [EngineManifest] = []
    var catalog = RecipeCatalog(recipes: [])
    var selected: URL?
    var matchedRecipe: Recipe?
    var status: Status = .idle
    var output = ""
    var notice: String?
    var installing: Set<String> = []
    var pendingLicense: EngineManifest?
    /// A GPTK image waiting for the user to read and accept Apple's license.
    var pendingGPTK: PendingGPTK?
    var importing = false

    struct PendingGPTK: Identifiable {
        var id: String { url.path }
        var url: URL
        var info: GPTKInfo
    }

    init(paths: WinDAPaths? = nil) {
        let saved = LocationStore().load()
        self.paths = paths ?? .resolve(saved: saved)
        let envSet = !(ProcessInfo.processInfo.environment["WINDA_HOME"] ?? "").isEmpty
        needsSetup = paths == nil && saved == nil && !envSet
        showSetup = needsSetup
        reload()
    }

    var currentLocations: WinDALocations {
        WinDALocations(home: paths.home.path, bottles: paths.bottlesOverride?.path,
                       engines: paths.enginesOverride?.path, apps: paths.appsOverride?.path)
    }

    /// Saves the chosen folders after checking each can be written to.
    func saveLocations(_ l: WinDALocations) -> String? {
        for (label, url) in [("WinDA data", l.paths.home), ("Windows apps", l.paths.bottles),
                             ("Engines and downloads", l.paths.engines), ("Shortcuts", l.paths.apps)] {
            if !LocationCheck.check(url).writable { return "\(label): cannot write to \(url.path)" }
        }
        do { try locationStore.save(l) } catch { return "Could not save the settings: \(error)" }
        paths = l.paths
        needsSetup = false
        showSetup = false
        reload()
        return nil
    }

    private func makeLauncher() -> Launcher {
        Launcher(manifests: manifests, engineRoot: paths.engines, bottles: BottleStore(root: paths.bottles), cache: paths.cache)
    }

    /// Recipes that install a launcher or program with its own entry point (Steam and similar).
    var programs: [Recipe] { catalog.recipes.filter { $0.launch != nil } }

    func isPrepared(_ r: Recipe) -> Bool { makeLauncher().isPrepared(r) }

    func installLocation(_ r: Recipe) -> URL { paths.bottles.appendingPathComponent(r.id) }

    func installProgram(_ r: Recipe) async {
        busyPrograms.insert(r.id)
        defer { busyPrograms.remove(r.id) }
        let launcher = makeLauncher()
        do {
            _ = try await Task.detached { try await launcher.prepare(recipe: r) }.value
            notice = "\(r.name) is installed. Press Open to start it."
        } catch {
            notice = "Could not install \(r.name): \(Self.describe(error))"
        }
    }

    func settings(for r: Recipe) -> ProgramSettings { ProgramSettingsStore(root: paths.config).load(r.id) }

    func saveSettings(_ s: ProgramSettings, for r: Recipe) -> String? {
        let issues = s.validate()
        if !issues.isEmpty { return issues.joined(separator: "\n") }
        do { try ProgramSettingsStore(root: paths.config).save(s, for: r.id) } catch { return "Could not save: \(error)" }
        return nil
    }

    /// Graphics paths with an installed engine, for the settings picker.
    var availableGraphics: [GraphicsEngine] {
        let installed = manifests.filter { isInstalled($0) }
        var out: [GraphicsEngine] = []
        let wines = installed.filter { $0.kind == .wine }
        if wines.contains(where: { ($0.compatibleGraphics ?? $0.provides).contains(.d3dmetal) }) { out.append(.d3dmetal) }
        if wines.contains(where: { ($0.compatibleGraphics ?? $0.provides).contains(.dxvk) }),
           installed.contains(where: { $0.kind == .graphicsLayer }) { out.append(.dxvk) }
        return out
    }

    func stopProgram(_ r: Recipe) {
        let launcher = makeLauncher()
        Task.detached { launcher.stop(recipe: r) }
        notice = "Stopping \(r.name)…"
    }

    /// Folder that holds a launcher's `steamapps`, derived from its launch path inside the bottle.
    func libraryRoot(for r: Recipe) -> URL? {
        guard let program = r.launch?.program,
              let prefix = try? BottleStore(root: paths.bottles).prefix(for: r.id) else { return nil }
        return SteamLibrary.unixURL(forWindowsPath: program, prefix: prefix)?.deletingLastPathComponent()
    }

    func refreshGames() {
        for r in programs where r.id == "steam" || r.launch?.program.lowercased().hasSuffix("steam.exe") == true {
            guard let root = libraryRoot(for: r) else { continue }
            let found = SteamLibrary.games(inSteamRoot: root)
            if games[r.id] != found { games[r.id] = found }
        }
    }

    func playGame(_ r: Recipe, _ game: SteamGame) async {
        await openProgram(r, extra: ["-applaunch", game.appID], label: game.name)
    }

    func createGameShortcut(_ r: Recipe, _ game: SteamGame) {
        guard let exe = Bundle.main.executableURL else { return }
        let launcher = exe.deletingLastPathComponent().appendingPathComponent("winda-bottle")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            notice = "Shortcuts need the WinDA launcher next to the app, and it was not found."
            return
        }
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("winda-\(UUID().uuidString).json")
            try JSONEncoder().encode(r).write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try FileManager.default.createDirectory(at: paths.apps, withIntermediateDirectories: true)
            var spec = ShortcutSpec(name: game.name, recipe: tmp, program: ["-applaunch", game.appID], launcher: launcher,
                                    manifestsDirectory: paths.manifests, engineRoot: paths.engines, bottlesRoot: paths.bottles,
                                    logDirectory: paths.logs, cacheDirectory: paths.cache)
            spec.openWithConfig = paths.config
            let app = try ShortcutGenerator.create(spec, in: paths.apps)
            notice = "Created \(app.lastPathComponent) in \(paths.apps.path)"
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            notice = "Could not create the shortcut: \(Self.describe(error))"
        }
    }

    func openProgram(_ r: Recipe, extra: [String] = [], label: String? = nil) async {
        let launcher = makeLauncher()
        let settings = settings(for: r)
        notice = "Starting \(label ?? r.name)…"
        runningPrograms.insert(r.id)
        defer { runningPrograms.remove(r.id) }
        do {
            let result = try await Task.detached { try await launcher.open(recipe: r, settings: settings, extraArguments: extra) }.value
            notice = result.status == 0 ? "\(r.name) closed." : "\(r.name) exited with code \(result.status)."
        } catch {
            notice = "Could not start \(r.name): \(Self.describe(error))"
        }
    }

    /// The recipe that will run: the matched one, or defaults for an unknown program.
    var recipe: Recipe? {
        guard let selected else { return nil }
        return matchedRecipe ?? RecipeCatalog.untested(for: selected)
    }

    var isTested: Bool { matchedRecipe != nil }

    func reload() {
        let dir = paths.manifests
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        manifests = files.compactMap { try? EngineManifest.decode(from: Data(contentsOf: dir.appendingPathComponent($0))) }
            .filter { EngineManifestValidator.validate($0).isEmpty }
        catalog = RecipeCatalog(directory: paths.recipes)
    }

    func isInstalled(_ m: EngineManifest) -> Bool { EngineInstaller(root: paths.engines).isInstalled(m) }

    func select(_ url: URL) {
        guard url.pathExtension.lowercased() == "exe" else {
            notice = "Choose a Windows program (.exe)."
            return
        }
        selected = url
        matchedRecipe = catalog.match(exe: url)
        status = .idle
        output = ""
        notice = nil
    }

    func run() async {
        guard let recipe, let selected else { return }
        status = .running
        output = ""
        let launcher = makeLauncher()
        do {
            let r = try await launcher.launch(recipe: recipe, program: [selected.path])
            output = r.output
            status = .finished(r.status)
            log(r.output)
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    func createShortcut() {
        guard let recipe, let selected else { return }
        guard let exe = Bundle.main.executableURL else { return }
        let launcher = exe.deletingLastPathComponent().appendingPathComponent("winda-bottle")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            notice = "Shortcuts need the WinDA launcher next to the app, and it was not found."
            return
        }
        do {
            // Writing the recipe to a temp file lets the generator copy it into the bundle.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("winda-\(UUID().uuidString).json")
            try JSONEncoder().encode(recipe).write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try FileManager.default.createDirectory(at: paths.apps, withIntermediateDirectories: true)
            let name = isTested ? recipe.name : selected.deletingPathExtension().lastPathComponent
            let spec = ShortcutSpec(name: name, recipe: tmp, program: [selected.path], launcher: launcher,
                                    manifestsDirectory: paths.manifests, engineRoot: paths.engines,
                                    bottlesRoot: paths.bottles, logDirectory: paths.logs, cacheDirectory: paths.cache)
            let app = try ShortcutGenerator.create(spec, in: paths.apps)
            notice = "Created \(app.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            notice = "Could not create the shortcut: \(Self.describe(error))"
        }
    }

    func install(_ m: EngineManifest, licenseAccepted: Bool) async {
        installing.insert(m.id)
        defer { installing.remove(m.id) }
        do {
            try await EngineInstaller(root: paths.engines).install(m, licenseAccepted: licenseAccepted)
            notice = "Installed \(m.name)"
        } catch InstallError.licenseNotAccepted {
            pendingLicense = m
        } catch {
            notice = "Install failed: \(Self.describe(error))"
        }
    }

    /// Step 1: read the image and show the license. Nothing is installed yet.
    func inspectGPTK(_ url: URL) async {
        importing = true
        defer { importing = false }
        let importer = GPTKImporter(engineRoot: paths.engines)
        do {
            let info = try await Task.detached { try importer.inspect(image: url) }.value
            pendingGPTK = PendingGPTK(url: url, info: info)
        } catch {
            notice = "Could not read that image: \(Self.describeImport(error))"
        }
    }

    /// Step 2 (after acceptance): import, then try the new D3DMetal on each installed GPTK-based Wine.
    func importGPTK(_ pending: PendingGPTK) async {
        importing = true
        defer { importing = false }
        let engines = paths.engines, manifestsDir = paths.manifests
        let bases = manifests.filter { $0.kind == .wine && $0.provides.contains(.d3dmetal) && isInstalled($0) && !$0.id.contains("-d3dm-") }
        let url = pending.url
        let result: Result<String, Error> = await Task.detached {
            do {
                let importer = GPTKImporter(engineRoot: engines)
                let rec = try importer.install(image: url, licenseAccepted: true)
                guard !bases.isEmpty else { return .success("Imported D3DMetal \(rec.version), but no GPTK-based Wine is installed to use it with.") }
                var lines: [String] = []
                for base in bases {
                    let o = try D3DMetalOverlay.deriveAndVerify(base: base, imported: rec, engineRoot: engines, manifestsDirectory: manifestsDir)
                    lines.append(o.activated
                        ? "D3DMetal \(rec.version) works with \(base.name) and is now available."
                        : "D3DMetal \(rec.version) did not pass the check with \(base.name), so it is not used. \(SmokeTest.summary(o.smoke))")
                }
                return .success(lines.joined(separator: "\n"))
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let m): notice = m
        case .failure(let e): notice = "Import failed: \(Self.describeImport(e))"
        }
        reload()
    }

    static func describeImport(_ error: Error) -> String {
        switch error {
        case ImportError.notAGPTKImage: return "this is not a Game Porting Toolkit image."
        case ImportError.missingComponent(let c): return "the image is missing \(c)."
        case ImportError.alreadyImported(let id): return "\(id) is already imported."
        case ImportError.mountFailed(let m): return "the image could not be opened (\(m))."
        case ImportError.licenseNotAccepted: return "the license was not accepted."
        default: return "\(error)"
        }
    }

    private func log(_ text: String) {
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let url = paths.logs.appendingPathComponent("last-run.log")
        try? Data(text.utf8).write(to: url)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SelectionError.noEngine(let g): return "No installed engine can run this (needs \(g)). Install one under Engines."
        case EngineSwitchError.notAvailable(let g): return "No installed engine provides \(g)."
        case LaunchError.invalidSettings(let issues): return "These settings are not allowed: \(issues.joined(separator: "; "))"
        case LaunchError.noLaunchSpec: return "This recipe has nothing to start."
        case LaunchError.invalidRecipe(let issues): return "The recipe is invalid: \(issues.joined(separator: "; "))"
        case ApplyError.unsupported(let what): return "This recipe needs \(what), which WinDA cannot do yet."
        case BottleError.engineMismatch: return "This program's bottle was made with a different engine."
        case InstallError.hashMismatch: return "The download did not match its checksum and was discarded."
        default: return "\(error)"
        }
    }
}
