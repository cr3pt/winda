import Foundation
import XCTest
@testable import WinDACore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func recipeJSON(id: String, exe: String, sha: String = "") -> Data {
    Data("""
    {"schemaVersion":1,"id":"\(id)","name":"\(id)","category":"game",
     "match":{"exeNames":["\(exe)"],"sha256":[\(sha.isEmpty ? "" : "\"\(sha)\"")]},
     "engine":{"graphics":"auto"},"actions":[],"rating":"gold"}
    """.utf8)
}

final class CatalogTests: XCTestCase {
    func testLoadsValidAndRejectsInvalid() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        try recipeJSON(id: "good", exe: "g.exe").write(to: tmp.appendingPathComponent("good.json"))
        try recipeJSON(id: "Bad Id", exe: "b.exe").write(to: tmp.appendingPathComponent("bad.json"))
        try Data("not json".utf8).write(to: tmp.appendingPathComponent("broken.json"))
        try Data("ignored".utf8).write(to: tmp.appendingPathComponent("notes.txt"))
        let c = RecipeCatalog(directory: tmp)
        XCTAssertEqual(c.recipes.map(\.id), ["good"])
        XCTAssertEqual(c.rejected, ["bad.json", "broken.json"])
    }

    func testMissingDirectoryIsEmpty() {
        let c = RecipeCatalog(directory: URL(fileURLWithPath: "/nonexistent/winda"))
        XCTAssertTrue(c.recipes.isEmpty)
    }

    func testMatchesByNameCaseInsensitively() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        try recipeJSON(id: "g", exe: "Game.EXE").write(to: tmp.appendingPathComponent("g.json"))
        let c = RecipeCatalog(directory: tmp)
        XCTAssertEqual(c.match(exe: URL(fileURLWithPath: "/x/game.exe"))?.id, "g")
        XCTAssertNil(c.match(exe: URL(fileURLWithPath: "/x/other.exe")))
    }

    func testHashMatchBeatsNameMatch() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let exe = tmp.appendingPathComponent("game.exe")
        try Data("binary".utf8).write(to: exe)
        let digest = try EngineInstaller.sha256(of: exe)
        try recipeJSON(id: "by-name", exe: "game.exe").write(to: tmp.appendingPathComponent("a.json"))
        try recipeJSON(id: "by-hash", exe: "other.exe", sha: digest).write(to: tmp.appendingPathComponent("b.json"))
        XCTAssertEqual(RecipeCatalog(directory: tmp).match(exe: exe)?.id, "by-hash")
    }

    func testUntestedRecipeIsValid() {
        let r = RecipeCatalog.untested(for: URL(fileURLWithPath: "/x/Some Game.exe"))
        XCTAssertTrue(RecipeValidator.validate(r).isEmpty)
        XCTAssertEqual(r.id, "untested")
        XCTAssertEqual(r.engine.graphics, .auto)
    }

    func testPathsFromEnvironment() {
        let p = WinDAPaths.resolve(environment: ["WINDA_HOME": "/x/winda"])
        XCTAssertEqual(p.engines.path, "/x/winda/engines")
        XCTAssertEqual(p.bottles.path, "/x/winda/bottles")
        XCTAssertTrue(WinDAPaths.resolve(environment: [:]).home.path.hasSuffix("Application Support/WinDA"))
    }
}
