import Foundation
import XCTest
@testable import WinDACore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

final class ProgramSettingsTests: XCTestCase {
    func testDefaultsAreValidAndMapCommandKey() {
        let s = ProgramSettings()
        XCTAssertTrue(s.validate().isEmpty)
        XCTAssertTrue(s.commandIsCtrl)
        XCTAssertNil(s.graphics)
    }

    func testRejectsBadArgumentsAndReservedVariables() {
        let s = ProgramSettings(extraArguments: ["-ok", "x; rm -rf ~", "$(id)"],
                                environment: ["PATH": "/x", "DYLD_INSERT_LIBRARIES": "/y", "lower": "1", "GOOD": "1"])
        let issues = s.validate()
        XCTAssertEqual(issues.filter { $0.contains("argument") }.count, 2)
        XCTAssertTrue(issues.contains { $0.contains("'PATH' is reserved") })
        XCTAssertTrue(issues.contains { $0.contains("DYLD_INSERT_LIBRARIES") })
        XCTAssertTrue(issues.contains { $0.contains("'lower' is invalid") })
        XCTAssertFalse(issues.contains { $0.contains("GOOD") })
    }

    func testParseEnvironment() {
        let env = ProgramSettings.parseEnvironment("# comment\nA=1\n\n B = no \nC=x=y\nbroken line\n")
        XCTAssertEqual(env["A"], "1")
        XCTAssertEqual(env["C"], "x=y")
        XCTAssertNil(env["broken line"])
        XCTAssertEqual(env.count, 3)
    }

    func testStoreRoundTripDefaultsAndInvalidID() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ProgramSettingsStore(root: tmp.appendingPathComponent("config"))
        XCTAssertEqual(store.load("steam"), ProgramSettings(), "missing file gives defaults")
        let s = ProgramSettings(graphics: .d3dmetal, extraArguments: ["-windowed"], environment: ["A": "1"], commandIsCtrl: false)
        try store.save(s, for: "steam")
        XCTAssertEqual(store.load("steam"), s)
        XCTAssertThrowsError(try store.save(s, for: "../evil"))
    }
}

final class WrapTests: XCTestCase {
    private func setup() throws -> (tmp: URL, prefix: URL, wrapper: URL, target: URL) {
        let tmp = try tempDir()
        let prefix = tmp.appendingPathComponent("prefix")
        let dir = prefix.appendingPathComponent("drive_c/Steam/bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wrapper = tmp.appendingPathComponent("wrapper.exe")
        try Data("WRAPPER".utf8).write(to: wrapper)
        let target = dir.appendingPathComponent("helper.exe")
        try Data("ORIGINAL-1".utf8).write(to: target)
        return (tmp, prefix, wrapper, target)
    }

    func testWrapsKeepsOriginalAndWritesArguments() throws {
        let t = try setup(); defer { try? FileManager.default.removeItem(at: t.tmp) }
        try ExecutableWrapper.ensure(prefix: t.prefix, path: "Steam/bin/helper.exe", arguments: ["--a", "--b=1"], wrapper: t.wrapper)
        XCTAssertEqual(try String(contentsOf: t.target, encoding: .utf8), "WRAPPER")
        let real = t.target.deletingLastPathComponent().appendingPathComponent("helper_real.exe")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "ORIGINAL-1")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: t.target.path + ".wrapargs"), encoding: .utf8), "--a --b=1\n")
    }

    func testRepeatingIsHarmlessAndUpdatesArguments() throws {
        let t = try setup(); defer { try? FileManager.default.removeItem(at: t.tmp) }
        try ExecutableWrapper.ensure(prefix: t.prefix, path: "Steam/bin/helper.exe", arguments: ["--a"], wrapper: t.wrapper)
        try ExecutableWrapper.ensure(prefix: t.prefix, path: "Steam/bin/helper.exe", arguments: ["--c"], wrapper: t.wrapper)
        let real = t.target.deletingLastPathComponent().appendingPathComponent("helper_real.exe")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "ORIGINAL-1", "the original must not be overwritten by the wrapper")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: t.target.path + ".wrapargs"), encoding: .utf8), "--c\n")
    }

    func testUpdatedProgramIsWrappedAgain() throws {
        let t = try setup(); defer { try? FileManager.default.removeItem(at: t.tmp) }
        try ExecutableWrapper.ensure(prefix: t.prefix, path: "Steam/bin/helper.exe", arguments: ["--a"], wrapper: t.wrapper)
        try Data("ORIGINAL-2".utf8).write(to: t.target)          // the program updated itself
        try ExecutableWrapper.ensure(prefix: t.prefix, path: "Steam/bin/helper.exe", arguments: ["--a"], wrapper: t.wrapper)
        XCTAssertEqual(try String(contentsOf: t.target, encoding: .utf8), "WRAPPER")
        let real = t.target.deletingLastPathComponent().appendingPathComponent("helper_real.exe")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "ORIGINAL-2")
    }

    func testMissingTargetAndEscape() throws {
        let t = try setup(); defer { try? FileManager.default.removeItem(at: t.tmp) }
        XCTAssertThrowsError(try ExecutableWrapper.ensure(prefix: t.prefix, path: "Steam/bin/none.exe", arguments: [], wrapper: t.wrapper)) {
            XCTAssertEqual($0 as? WrapError, .targetMissing("Steam/bin/none.exe"))
        }
        XCTAssertThrowsError(try ExecutableWrapper.ensure(prefix: t.prefix, path: "../../outside.exe", arguments: [], wrapper: t.wrapper)) {
            XCTAssertEqual($0 as? WrapError, .escapesBottle("../../outside.exe"))
        }
    }

    func testBundledWrapperExists() { XCTAssertNotNil(ExecutableWrapper.wrapperBinary) }

    func testWrapActionValidation() throws {
        func recipe(_ a: String) throws -> Recipe {
            try Recipe.decode(from: Data("""
            {"schemaVersion":1,"id":"r","name":"R","category":"app","match":{"exeNames":["a.exe"],"sha256":[]},
             "engine":{"graphics":"dxvk"},"actions":[\(a)],"rating":"gold"}
            """.utf8))
        }
        XCTAssertTrue(RecipeValidator.validate(try recipe(#"{"type":"wrap","path":"Steam/h.exe","arguments":["--single-process","--x=1"]}"#)).isEmpty)
        XCTAssertFalse(RecipeValidator.validate(try recipe(#"{"type":"wrap","path":"../h.exe","arguments":[]}"#)).isEmpty)
        XCTAssertFalse(RecipeValidator.validate(try recipe(#"{"type":"wrap","path":"Steam/h.dll","arguments":[]}"#)).isEmpty)
        XCTAssertFalse(RecipeValidator.validate(try recipe(#"{"type":"wrap","path":"Steam/h.exe","arguments":["a; b"]}"#)).isEmpty)
    }
}

final class SwitchGraphicsTests: XCTestCase {
    private func wine(_ id: String, _ g: GraphicsEngine) -> EngineManifest {
        EngineManifest(schemaVersion: 1, id: id, name: id, kind: .wine, version: "1",
                       archive: Archive(url: URL(string: "https://example.com/w")!, sha256: String(repeating: "a", count: 64), size: 1, extractTo: id),
                       license: nil, provides: [g], wineBinary: "\(id)/bin/wine", compatibleGraphics: [g],
                       installs: nil, dllOverrides: nil)
    }

    func testSwitchesBottleToAnotherInstalledEngine() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("engines")
        let dxvk = wine("w-dxvk", .dxvk), metal = wine("w-metal", .d3dmetal)
        let installer = EngineInstaller(root: root)
        try installer.markInstalled(metal, sha256: "x")           // only the D3DMetal Wine is installed
        let store = BottleStore(root: tmp.appendingPathComponent("bottles"))
        try store.save(Bottle(id: "game", wineEngineID: "w-dxvk", layerID: "layer", graphics: .dxvk, environment: [:],
                              appliedRecipeDigest: "d", createdAt: Date(timeIntervalSince1970: 0)))
        let launcher = Launcher(manifests: [dxvk, metal], engineRoot: root, bottles: store)
        let recipe = Recipe(schemaVersion: 1, id: "game", name: "G", category: .game, match: Match(exeNames: ["g.exe"], sha256: []),
                            engine: EngineSpec(graphics: .dxvk, package: nil), actions: [], rating: .gold, notes: nil)

        try launcher.switchGraphics(recipe: recipe, to: .d3dmetal)
        let b = try XCTUnwrap(try store.load("game"))
        XCTAssertEqual(b.wineEngineID, "w-metal")
        XCTAssertEqual(b.graphics, .d3dmetal)
        XCTAssertNil(b.layerID)
        XCTAssertEqual(b.appliedRecipeDigest, "d", "installed contents are untouched")

        XCTAssertThrowsError(try launcher.switchGraphics(recipe: recipe, to: .dxvk)) {
            XCTAssertEqual($0 as? EngineSwitchError, .notAvailable("dxvk"))
        }
        XCTAssertEqual(try store.load("game")?.wineEngineID, "w-metal", "a failed switch changes nothing")
    }

    func testSwitchOnMissingBottleIsANoOp() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let launcher = Launcher(manifests: [], engineRoot: tmp, bottles: BottleStore(root: tmp.appendingPathComponent("b")))
        let recipe = Recipe(schemaVersion: 1, id: "none", name: "N", category: .game, match: Match(exeNames: ["n.exe"], sha256: []),
                            engine: EngineSpec(graphics: .dxvk, package: nil), actions: [], rating: .gold, notes: nil)
        XCTAssertNoThrow(try launcher.switchGraphics(recipe: recipe, to: .d3dmetal))
    }
}
