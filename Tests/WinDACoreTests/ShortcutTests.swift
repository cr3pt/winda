import Foundation
import XCTest
@testable import WinDACore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

final class ShortcutTests: XCTestCase {
    /// A stand-in launcher that records each argument on its own line.
    private func stubLauncher(in tmp: URL) throws -> (launcher: URL, record: URL) {
        let record = tmp.appendingPathComponent("args.txt")
        let launcher = tmp.appendingPathComponent("launcher.sh")
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \(ShortcutGenerator.shellQuote(record.path))\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return (launcher, record)
    }

    private func spec(_ tmp: URL, name: String = "My Game", program: [String] = ["game.exe"], launcher: URL? = nil) throws -> ShortcutSpec {
        let recipe = tmp.appendingPathComponent("r.json")
        try Data("{}".utf8).write(to: recipe)
        return ShortcutSpec(name: name, recipe: recipe, program: program,
                            launcher: launcher ?? URL(fileURLWithPath: "/bin/true"),
                            manifestsDirectory: tmp.appendingPathComponent("m"), engineRoot: tmp.appendingPathComponent("e"),
                            bottlesRoot: tmp.appendingPathComponent("b"), logDirectory: tmp.appendingPathComponent("logs"))
    }

    func testBundleLayoutAndPlist() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let app = try ShortcutGenerator.create(try spec(tmp), in: tmp)
        XCTAssertEqual(app.lastPathComponent, "My Game.app")
        let fm = FileManager.default
        XCTAssertTrue(fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/launch").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("Contents/Resources/recipe.json").path))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["CFBundleExecutable"] as? String, "launch")
        XCTAssertEqual(plist?["CFBundleIdentifier"] as? String, "app.winda.shortcut.my-game")
        XCTAssertEqual(plist?["CFBundlePackageType"] as? String, "APPL")
    }

    func testScriptPassesArgumentsVerbatim() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (launcher, record) = try stubLauncher(in: tmp)
        let tricky = ["/Games/It's a $HOME \"test\"/game.exe", "-flag", "two words", "`id`"]
        let app = try ShortcutGenerator.create(try spec(tmp, program: tricky, launcher: launcher), in: tmp)

        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/launch")
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let afterDashes = Array(lines.drop(while: { $0 != "--" }).dropFirst().prefix(tricky.count))
        XCTAssertEqual(afterDashes, tricky)
        XCTAssertEqual(lines.first, "launch")
        XCTAssertTrue(lines.contains(app.appendingPathComponent("Contents/Resources/recipe.json").path))
    }

    func testRecipeIsCopiedSoShortcutSurvivesMovingTheOriginal() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let s = try spec(tmp)
        let app = try ShortcutGenerator.create(s, in: tmp)
        try FileManager.default.removeItem(at: s.recipe)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/recipe.json").path))
    }

    func testRegenerationReplacesExistingBundle() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let first = try ShortcutGenerator.create(try spec(tmp, program: ["a.exe"]), in: tmp)
        let stray = first.appendingPathComponent("Contents/stray")
        try Data().write(to: stray)
        _ = try ShortcutGenerator.create(try spec(tmp, program: ["b.exe"]), in: tmp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        let script = try String(contentsOf: first.appendingPathComponent("Contents/MacOS/launch"), encoding: .utf8)
        XCTAssertTrue(script.contains("b.exe"))
    }

    func testNameSanitizing() throws {
        XCTAssertEqual(try ShortcutGenerator.sanitize("a/b:c\\d"), "a-b-c-d")
        XCTAssertEqual(try ShortcutGenerator.sanitize("  Hi  "), "Hi")
        for bad in ["", "   ", ".hidden", String(repeating: "x", count: 101)] {
            XCTAssertThrowsError(try ShortcutGenerator.sanitize(bad)) { XCTAssertEqual($0 as? ShortcutError, .invalidName(bad)) }
        }
    }

    func testNeverEscapesTargetDirectory() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A leading "../" becomes a hidden-looking name and is refused outright.
        XCTAssertThrowsError(try ShortcutGenerator.create(try spec(tmp, name: "../../evil"), in: out))
        // Separators inside a name are flattened, so the bundle stays in `out`.
        let app = try ShortcutGenerator.create(try spec(tmp, name: "x/../evil"), in: out)
        XCTAssertEqual(app.deletingLastPathComponent().standardizedFileURL.path, out.standardizedFileURL.path)
        XCTAssertEqual(app.lastPathComponent, "x-..-evil.app")
    }

    func testRejectsEmptyProgramAndMissingRecipe() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try ShortcutGenerator.create(try spec(tmp, program: []), in: tmp)) {
            XCTAssertEqual($0 as? ShortcutError, .emptyProgram)
        }
        var s = try spec(tmp)
        s.recipe = tmp.appendingPathComponent("nope.json")
        XCTAssertThrowsError(try ShortcutGenerator.create(s, in: tmp))
    }

    func testShellQuote() {
        XCTAssertEqual(ShortcutGenerator.shellQuote("a b"), "'a b'")
        XCTAssertEqual(ShortcutGenerator.shellQuote("it's"), "'it'\\''s'")
    }
}
