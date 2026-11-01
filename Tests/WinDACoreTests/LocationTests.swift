import Foundation
import XCTest
@testable import WinDACore

final class LocationTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testUnsetFoldersFollowHome() {
        let p = WinDALocations(home: "/h").paths
        XCTAssertEqual(p.bottles.path, "/h/bottles")
        XCTAssertEqual(p.engines.path, "/h/engines")
        XCTAssertEqual(p.apps.path, "/h/Apps")
        XCTAssertEqual(p.cache.path, "/h/engines/.cache")
        XCTAssertEqual(p.manifests.path, "/h/manifests")
    }

    func testSeparateFoldersOverrideHome() {
        let p = WinDALocations(home: "/h", bottles: "/big/bottles", engines: "/big/engines", apps: "/Applications/WinDA").paths
        XCTAssertEqual(p.bottles.path, "/big/bottles")
        XCTAssertEqual(p.engines.path, "/big/engines")
        XCTAssertEqual(p.apps.path, "/Applications/WinDA")
        XCTAssertEqual(p.cache.path, "/big/engines/.cache", "downloads follow the engines folder")
        XCTAssertEqual(p.recipes.path, "/h/recipes")
    }

    func testResolveOrder() {
        let saved = WinDALocations(home: "/saved")
        XCTAssertEqual(WinDAPaths.resolve(environment: ["WINDA_HOME": "/env"], saved: saved).home.path, "/env")
        XCTAssertEqual(WinDAPaths.resolve(environment: [:], saved: saved).home.path, "/saved")
        XCTAssertEqual(WinDAPaths.resolve(environment: [:], saved: nil).home, WinDAPaths.defaultHome)
        XCTAssertNil(WinDAPaths.resolve(environment: ["WINDA_HOME": "/env"], saved: saved).bottlesOverride,
                     "an environment override ignores saved per-folder choices")
    }

    func testStoreRoundTripAndEmpty() throws {
        let suite = "winda-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocationStore(defaults: defaults)
        XCTAssertNil(store.load())
        let l = WinDALocations(home: "/h", bottles: "/b")
        try store.save(l)
        XCTAssertEqual(store.load(), l)
    }

    func testCheckCreatesWritableFolderAndReportsSpace() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("new/nested")
        let c = LocationCheck.check(target)
        XCTAssertTrue(c.writable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNotNil(c.freeBytes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.path)
        XCTAssertTrue(leftovers.isEmpty, "the write probe must be removed")
    }

    func testPreviewCreatesNothingAndUsesNearestExistingFolder() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("a/b/c")
        let c = LocationCheck.preview(target)
        XCTAssertTrue(c.writable)
        XCTAssertNotNil(c.freeBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("a").path))
    }

    func testCheckRejectsUnwritableLocation() {
        XCTAssertFalse(LocationCheck.check(URL(fileURLWithPath: "/System/winda-nope")).writable)
    }

    func testLowSpaceThreshold() {
        XCTAssertTrue(LocationCheck(writable: true, freeBytes: 5 * 1024 * 1024 * 1024).lowSpace)
        XCTAssertFalse(LocationCheck(writable: true, freeBytes: 100 * 1024 * 1024 * 1024).lowSpace)
        XCTAssertFalse(LocationCheck(writable: true, freeBytes: nil).lowSpace)
    }
}
