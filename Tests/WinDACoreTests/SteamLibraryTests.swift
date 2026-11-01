import Foundation
import XCTest
@testable import WinDACore

private let sampleACF = """
"AppState"
{
\t"appid"\t\t"949230"
\t"Universe"\t\t"1"
\t"name"\t\t"Cities: Skylines II"
\t"StateFlags"\t\t"1026"
\t"installdir"\t\t"Cities Skylines II"
\t"SizeOnDisk"\t\t"0"
\t"BytesToDownload"\t\t"1000"
\t"BytesDownloaded"\t\t"250"
\t"UserConfig"
\t{
\t\t"language"\t\t"english"
\t}
\t"InstalledDepots"
\t{
\t\t"949231"
\t\t{
\t\t\t"manifest"\t\t"123"
\t\t}
\t}
}
"""

final class SteamLibraryTests: XCTestCase {
    private func tempRoot() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        return d
    }

    func testParsesTopLevelKeysAndSkipsNestedBlocks() {
        let kv = SteamLibrary.parseACF(sampleACF)
        XCTAssertEqual(kv["appid"], "949230")
        XCTAssertEqual(kv["name"], "Cities: Skylines II")
        XCTAssertEqual(kv["installdir"], "Cities Skylines II")
        XCTAssertNil(kv["language"], "values inside nested blocks must not leak out")
        XCTAssertNil(kv["manifest"])
    }

    func testGameStateAndProgress() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(sampleACF.utf8).write(to: root.appendingPathComponent("steamapps/appmanifest_949230.acf"))
        let games = SteamLibrary.games(inSteamRoot: root)
        XCTAssertEqual(games.count, 1)
        let g = games[0]
        XCTAssertFalse(g.isInstalled, "1026 has no FullyInstalled bit")
        XCTAssertEqual(try XCTUnwrap(g.progress), 0.25, accuracy: 0.0001)
    }

    func testFullyInstalledGameHasNoProgress() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let acf = sampleACF.replacingOccurrences(of: "\"1026\"", with: "\"4\"")
        try Data(acf.utf8).write(to: root.appendingPathComponent("steamapps/appmanifest_949230.acf"))
        let g = SteamLibrary.games(inSteamRoot: root)[0]
        XCTAssertTrue(g.isInstalled)
        XCTAssertNil(g.progress)
    }

    func testHidesSteamComponentsAndSortsByName() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        func acf(_ id: String, _ name: String) -> Data {
            Data("\"AppState\"\n{\n\t\"appid\"\t\"\(id)\"\n\t\"name\"\t\"\(name)\"\n\t\"StateFlags\"\t\"4\"\n}\n".utf8)
        }
        try acf("228980", "Steamworks Common Redistributables").write(to: root.appendingPathComponent("steamapps/appmanifest_228980.acf"))
        try acf("2", "Zeta").write(to: root.appendingPathComponent("steamapps/appmanifest_2.acf"))
        try acf("1", "alpha").write(to: root.appendingPathComponent("steamapps/appmanifest_1.acf"))
        XCTAssertEqual(SteamLibrary.games(inSteamRoot: root).map(\.name), ["alpha", "Zeta"])
    }

    func testMissingFolderAndBrokenFileGiveNoGames() throws {
        XCTAssertTrue(SteamLibrary.games(inSteamRoot: URL(fileURLWithPath: "/nonexistent/steam")).isEmpty)
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("garbage".utf8).write(to: root.appendingPathComponent("steamapps/appmanifest_9.acf"))
        XCTAssertTrue(SteamLibrary.games(inSteamRoot: root).isEmpty)
    }

    func testWindowsPathMapping() {
        let prefix = URL(fileURLWithPath: "/b/steam/prefix")
        XCTAssertEqual(SteamLibrary.unixURL(forWindowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe", prefix: prefix)?.path,
                       "/b/steam/prefix/drive_c/Program Files (x86)/Steam/steam.exe")
        XCTAssertNil(SteamLibrary.unixURL(forWindowsPath: "C:\\a\\..\\b", prefix: prefix))
        XCTAssertNil(SteamLibrary.unixURL(forWindowsPath: "relative\\path", prefix: prefix))
    }

    func testOpenModeShortcutPassesSettingsAndArguments() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recipe = tmp.appendingPathComponent("r.json"); try Data("{}".utf8).write(to: recipe)
        var spec = ShortcutSpec(name: "Cities: Skylines II", recipe: recipe, program: ["-applaunch", "949230"],
                                launcher: URL(fileURLWithPath: "/bin/true"), manifestsDirectory: tmp, engineRoot: tmp,
                                bottlesRoot: tmp, logDirectory: tmp)
        spec.openWithConfig = tmp.appendingPathComponent("config")
        let app = try ShortcutGenerator.create(spec, in: tmp)
        XCTAssertEqual(app.lastPathComponent, "Cities- Skylines II.app")
        let script = try String(contentsOf: app.appendingPathComponent("Contents/MacOS/launch"), encoding: .utf8)
        XCTAssertTrue(script.contains(" open \\"), "runs the recipe's launch entry, not a bare program")
        XCTAssertTrue(script.contains("--config '\(tmp.path)/config'"))
        XCTAssertTrue(script.contains("-- '-applaunch' '949230'"))
    }
}
