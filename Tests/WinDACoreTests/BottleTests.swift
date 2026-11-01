import Foundation
import XCTest
@testable import WinDACore

private let sha = String(repeating: "c", count: 64)

private func wine(_ id: String, provides: [GraphicsEngine], compatible: [GraphicsEngine]? = nil) -> EngineManifest {
    EngineManifest(schemaVersion: 1, id: id, name: id, kind: .wine, version: "1",
                   archive: Archive(url: URL(string: "https://example.com/w")!, sha256: sha, size: 1, extractTo: id),
                   license: nil, provides: provides, wineBinary: "\(id)/bin/wine", compatibleGraphics: compatible,
                   installs: nil, dllOverrides: nil)
}

private func layer(_ id: String) -> EngineManifest {
    EngineManifest(schemaVersion: 1, id: id, name: id, kind: .graphicsLayer, version: "1",
                   archive: Archive(url: URL(string: "https://example.com/l")!, sha256: sha, size: 1, extractTo: id),
                   license: nil, provides: [.dxvk], wineBinary: nil, compatibleGraphics: nil,
                   installs: [FileInstall(source: id, destination: "windows/system32")], dllOverrides: ["d3d11=n,b"])
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

final class EngineSelectorTests: XCTestCase {
    let gptk = wine("gptk", provides: [.d3dmetal], compatible: [.d3dmetal])
    let stock = wine("stock", provides: [.dxvk], compatible: [.dxvk])
    let dxvk = layer("dxvk")

    func testAutoPrefersD3DMetal() throws {
        let c = try EngineSelector.select(.auto, wines: [stock, gptk], layers: [dxvk])
        XCTAssertEqual(c.graphics, .d3dmetal)
        XCTAssertEqual(c.wine.id, "gptk")
        XCTAssertNil(c.layer)
    }

    func testAutoFallsBackToDXVKWithLayer() throws {
        let c = try EngineSelector.select(.auto, wines: [stock], layers: [dxvk])
        XCTAssertEqual(c.graphics, .dxvk)
        XCTAssertEqual(c.layer?.id, "dxvk")
    }

    func testExplicitD3DMetalWithoutGPTKFails() {
        XCTAssertThrowsError(try EngineSelector.select(.d3dmetal, wines: [stock], layers: [dxvk])) {
            XCTAssertEqual($0 as? SelectionError, .noEngine(requested: "d3dmetal"))
        }
    }

    func testDXVKNeedsALayer() {
        XCTAssertThrowsError(try EngineSelector.select(.dxvk, wines: [stock], layers: []))
    }

    func testDXVKDoesNotPickD3DMetalOnlyWine() {
        XCTAssertThrowsError(try EngineSelector.select(.dxvk, wines: [gptk], layers: [dxvk]))
    }
}

final class BottleStoreTests: XCTestCase {
    func testSaveLoadListDelete() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = BottleStore(root: tmp)
        let b = Bottle(id: "my-game", wineEngineID: "gptk", layerID: nil, graphics: .d3dmetal,
                       environment: ["A": "1"], appliedRecipeDigest: "abc", createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(try store.load("my-game"))
        try store.save(b)
        XCTAssertEqual(try store.load("my-game"), b)
        XCTAssertEqual(try store.list(), [b])
        try store.delete("my-game")
        XCTAssertNil(try store.load("my-game"))
    }

    func testRejectsTraversalIDs() throws {
        let store = BottleStore(root: URL(fileURLWithPath: "/tmp/x"))
        for bad in ["../evil", "a/b", "", "UPPER", "a b"] {
            XCTAssertThrowsError(try store.directory(for: bad)) { XCTAssertEqual($0 as? BottleError, .invalidID(bad)) }
        }
    }
}

final class RecipeApplierTests: XCTestCase {
    private func recipe(_ actions: [Action]) -> Recipe {
        Recipe(schemaVersion: 1, id: "r", name: "R", category: .game,
               match: Match(exeNames: ["a.exe"], sha256: []), engine: EngineSpec(graphics: .dxvk, package: nil),
               actions: actions, rating: .gold, notes: nil)
    }

    private func applier(_ tmp: URL) -> RecipeApplier {
        RecipeApplier(runner: WineRunner(engine: WineEngine(wine: URL(fileURLWithPath: "/nonexistent/wine")),
                                         prefix: tmp.appendingPathComponent("prefix")))
    }

    func testSetEnvIsCollected() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let env = try await applier(tmp).apply(recipe([.setEnv(key: "A", value: "1"), .setEnv(key: "B", value: "2")]))
        XCTAssertEqual(env, ["A": "1", "B": "2"])
    }

    func testWinetricksFailsLoudly() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        do { _ = try await applier(tmp).apply(recipe([.winetricks(verb: "vcrun2022")])); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ApplyError, .unsupported("winetricks vcrun2022 (winetricks is not installed)")) }
    }

    func testDownloadVerifiesHashAndPlacesFile() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.dll")
        try Data("payload".utf8).write(to: src)
        let digest = try EngineInstaller.sha256(of: src)
        let a = applier(tmp)
        try await a.download(url: src, sha256: digest, destination: "windows/system32/x.dll")
        let out = tmp.appendingPathComponent("prefix/drive_c/windows/system32/x.dll")
        XCTAssertEqual(try Data(contentsOf: out), Data("payload".utf8))
        // A second call with the file already in place is a no-op.
        try await a.download(url: src, sha256: digest, destination: "windows/system32/x.dll")
    }

    func testDownloadRejectsWrongHashAndEscape() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.dll")
        try Data("payload".utf8).write(to: src)
        let a = applier(tmp)
        do { try await a.download(url: src, sha256: sha, destination: "x.dll"); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ApplyError, .downloadHashMismatch(url: src.absoluteString)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("prefix/drive_c/x.dll").path))
        do { try await a.download(url: src, sha256: sha, destination: "../../escape.dll"); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ApplyError, .destinationEscapes("../../escape.dll")) }
    }

    func testDigestChangesWithRecipe() throws {
        let a = recipe([.setEnv(key: "A", value: "1")])
        var b = a
        b.actions = [.setEnv(key: "A", value: "2")]
        XCTAssertNotEqual(try RecipeApplier.digest(of: a), try RecipeApplier.digest(of: b))
        XCTAssertEqual(try RecipeApplier.digest(of: a), try RecipeApplier.digest(of: a))
    }
}

final class LauncherTests: XCTestCase {
    func testInvalidRecipeIsRejectedBeforeAnyWork() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let bad = Recipe(schemaVersion: 1, id: "Bad Id", name: "x", category: .game,
                         match: Match(exeNames: ["a.exe"], sha256: []), engine: EngineSpec(graphics: .dxvk, package: nil),
                         actions: [], rating: .gold, notes: nil)
        let l = Launcher(manifests: [], engineRoot: tmp, bottles: BottleStore(root: tmp.appendingPathComponent("b")))
        do { _ = try await l.launch(recipe: bad, program: ["x.exe"]); XCTFail("expected failure") }
        catch LaunchError.invalidRecipe(let issues) { XCTAssertEqual(issues, ["id must be a lowercase slug"]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("b").path))
    }

    func testNoInstalledEngineFailsWithoutCreatingABottle() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let r = Recipe(schemaVersion: 1, id: "ok", name: "x", category: .game,
                       match: Match(exeNames: ["a.exe"], sha256: []), engine: EngineSpec(graphics: .auto, package: nil),
                       actions: [], rating: .gold, notes: nil)
        let l = Launcher(manifests: [wine("w", provides: [.dxvk])], engineRoot: tmp,
                         bottles: BottleStore(root: tmp.appendingPathComponent("b")))
        do { _ = try await l.launch(recipe: r, program: ["x.exe"]); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? SelectionError, .noEngine(requested: "auto")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("b").path))
    }
}
