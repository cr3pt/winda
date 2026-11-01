import Foundation
import XCTest
@testable import WinDACore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let toolJSON = Data("""
{"schemaVersion":1,"id":"winetricks-test","name":"Winetricks","kind":"tool","version":"1",
 "archive":{"url":"https://example.com/w.tar.gz","sha256":"\(String(repeating: "d", count: 64))","size":1,"extractTo":"wt"},
 "provides":[],"toolBinary":"wt/src/winetricks"}
""".utf8)

final class WinetricksTests: XCTestCase {
    func testToolManifestValidatesAndResolves() throws {
        let m = try EngineManifest.decode(from: toolJSON)
        XCTAssertTrue(EngineManifestValidator.validate(m).isEmpty)
        XCTAssertEqual(try m.resolveTool(root: URL(fileURLWithPath: "/e")).path, "/e/wt/src/winetricks")
    }

    func testToolManifestRejectsMissingOrEscapingBinaryAndWineFields() throws {
        var m = try EngineManifest.decode(from: toolJSON)
        m.toolBinary = nil
        XCTAssertFalse(EngineManifestValidator.validate(m).isEmpty)
        m.toolBinary = "../outside"
        XCTAssertFalse(EngineManifestValidator.validate(m).isEmpty)
        m.toolBinary = "ok/winetricks"
        m.wineBinary = "x/wine"
        XCTAssertFalse(EngineManifestValidator.validate(m).isEmpty)
    }

    func testResolveToolRejectsNonTools() throws {
        var m = try EngineManifest.decode(from: toolJSON)
        m.kind = .wine
        XCTAssertThrowsError(try m.resolveTool(root: URL(fileURLWithPath: "/e")))
    }

    func testVerbsWithEqualsAreAllowed() throws {
        let json = """
        {"schemaVersion":1,"id":"r","name":"R","category":"game","match":{"exeNames":["a.exe"],"sha256":[]},
         "engine":{"graphics":"dxvk"},"actions":[{"type":"winetricks","verb":"fontsmooth=rgb"}],"rating":"gold"}
        """
        let r = try Recipe.decode(from: Data(json.utf8))
        XCTAssertTrue(RecipeValidator.validate(r).isEmpty)
        let bad = json.replacingOccurrences(of: "fontsmooth=rgb", with: "-q; rm")
        XCTAssertFalse(RecipeValidator.validate(try Recipe.decode(from: Data(bad.utf8))).isEmpty)
    }

    func testEnvironmentPointsAtTheEngineAndCache() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let r = WinetricksRunner(script: tmp.appendingPathComponent("winetricks"),
                                 engine: WineEngine(wine: URL(fileURLWithPath: "/e/bin/wine64")),
                                 prefix: tmp.appendingPathComponent("p"), cache: tmp.appendingPathComponent("c"))
        let env = r.environment()
        XCTAssertEqual(env["WINE"], "/e/bin/wine64")
        XCTAssertEqual(env["WINESERVER"], "/e/bin/wineserver")
        XCTAssertEqual(env["WINEPREFIX"], tmp.appendingPathComponent("p").path)
        XCTAssertEqual(env["W_CACHE"], tmp.appendingPathComponent("c").path)
        XCTAssertTrue(env["PATH"]!.hasPrefix("/e/bin:"))
    }

    func testMissingScriptAndMissingHelperAreClearErrors() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let engine = WineEngine(wine: URL(fileURLWithPath: "/e/bin/wine"))
        let missing = WinetricksRunner(script: tmp.appendingPathComponent("nope"), engine: engine,
                                       prefix: tmp, cache: tmp)
        XCTAssertThrowsError(try missing.run(verb: "vcrun2022")) {
            XCTAssertEqual($0 as? WinetricksError, .toolMissing(tmp.appendingPathComponent("nope").path))
        }
        let script = tmp.appendingPathComponent("winetricks")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        let noHelper = WinetricksRunner(script: script, engine: engine, prefix: tmp, cache: tmp, helperPaths: ["/nonexistent"])
        // /usr/bin and /bin never contain cabextract on macOS.
        XCTAssertThrowsError(try noHelper.run(verb: "vcrun2022")) {
            guard case WinetricksError.dependencyMissing = $0 else { return XCTFail("\($0)") }
        }
    }

    func testRunReportsFailureWithOutput() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let fakeCab = tmp.appendingPathComponent("bin/cabextract")
        try Data("#!/bin/sh\n".utf8).write(to: fakeCab)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCab.path)
        let script = tmp.appendingPathComponent("winetricks")
        try Data("#!/bin/sh\necho \"boom $2\" >&2\nexit 3\n".utf8).write(to: script)
        let r = WinetricksRunner(script: script, engine: WineEngine(wine: URL(fileURLWithPath: "/e/bin/wine")),
                                 prefix: tmp, cache: tmp.appendingPathComponent("c"), helperPaths: [tmp.appendingPathComponent("bin").path])
        // The script above is run via /bin/bash with args "-q <verb>", so $2 is the verb.
        XCTAssertThrowsError(try r.run(verb: "vcrun2022")) {
            guard case let WinetricksError.failed(verb, status, output) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(verb, "vcrun2022")
            XCTAssertEqual(status, 3)
            XCTAssertTrue(output.contains("boom vcrun2022"), output)
        }
    }

    func testApplierRunsWinetricksVerbThroughRunner() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let fakeCab = tmp.appendingPathComponent("bin/cabextract")
        try Data("#!/bin/sh\n".utf8).write(to: fakeCab)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCab.path)
        let marker = tmp.appendingPathComponent("ran.txt")
        let script = tmp.appendingPathComponent("winetricks")
        try Data("#!/bin/sh\necho \"$2\" > '\(marker.path)'\n".utf8).write(to: script)
        let engine = WineEngine(wine: URL(fileURLWithPath: "/e/bin/wine"))
        let tricks = WinetricksRunner(script: script, engine: engine, prefix: tmp, cache: tmp.appendingPathComponent("c"),
                                      helperPaths: [tmp.appendingPathComponent("bin").path])
        let recipe = Recipe(schemaVersion: 1, id: "r", name: "R", category: .game,
                            match: Match(exeNames: ["a.exe"], sha256: []), engine: EngineSpec(graphics: .dxvk, package: nil),
                            actions: [.winetricks(verb: "corefonts")], rating: .gold, notes: nil)
        _ = try await RecipeApplier(runner: WineRunner(engine: engine, prefix: tmp), winetricks: tricks).apply(recipe)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "corefonts")
    }
}
