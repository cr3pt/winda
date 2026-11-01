import Foundation
import XCTest
@testable import WinDACore

private let sha = String(repeating: "b", count: 64)

private func wineManifestJSON(_ overrides: [String: String] = [:]) -> Data {
    let f = { (k: String, d: String) in overrides[k] ?? d }
    return Data("""
    {"schemaVersion":1,"id":"\(f("id", "wine-test"))","name":"Wine Test","kind":"wine","version":"1",
     "archive":{"url":"\(f("url", "https://example.com/w.tar.xz"))","sha256":"\(f("sha", sha))","size":10,"extractTo":"\(f("extractTo", "wine-test"))"},
     "provides":["dxvk"],"wineBinary":"\(f("bin", "wine-test/bin/wine"))"}
    """.utf8)
}

private let layerJSON = Data("""
{"schemaVersion":1,"id":"dxvk-test","name":"DXVK Test","kind":"graphicsLayer","version":"1",
 "archive":{"url":"https://example.com/d.tar.gz","sha256":"\(sha)","size":10,"extractTo":"dxvk-test"},
 "provides":["dxvk"],
 "installs":[{"source":"dxvk-test/x64","destination":"windows/system32"}],
 "dllOverrides":["d3d11,d3d10core=n,b"]}
""".utf8)

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

final class EngineManifestTests: XCTestCase {
    func testValidWineManifest() throws {
        let m = try EngineManifest.decode(from: wineManifestJSON())
        XCTAssertTrue(EngineManifestValidator.validate(m).isEmpty)
    }

    func testValidLayerManifest() throws {
        let m = try EngineManifest.decode(from: layerJSON)
        XCTAssertTrue(EngineManifestValidator.validate(m).isEmpty)
    }

    func testRejectsHTTPBadHashAndTraversal() throws {
        let m = try EngineManifest.decode(from: wineManifestJSON([
            "url": "http://example.com/w.tar.xz", "sha": "xyz", "bin": "../outside/wine", "extractTo": "../up",
        ]))
        XCTAssertEqual(EngineManifestValidator.validate(m).count, 4)
    }

    func testWineEngineNeedsBinary() throws {
        var m = try EngineManifest.decode(from: wineManifestJSON())
        m.wineBinary = nil
        XCTAssertFalse(EngineManifestValidator.validate(m).isEmpty)
        XCTAssertThrowsError(try m.resolveWine(root: URL(fileURLWithPath: "/x")))
    }

    func testLayerCannotDefineWineBinaryAndNeedsInstalls() throws {
        var m = try EngineManifest.decode(from: layerJSON)
        m.wineBinary = "x/wine"
        m.installs = []
        XCTAssertEqual(EngineManifestValidator.validate(m).count, 2)
    }

    func testRejectsBadDLLOverride() throws {
        var m = try EngineManifest.decode(from: layerJSON)
        m.dllOverrides = ["d3d11=evil"]
        XCTAssertEqual(EngineManifestValidator.validate(m).count, 1)
    }

    func testResolveWineUsesBinaryPath() throws {
        let m = try EngineManifest.decode(from: wineManifestJSON(["bin": "wine-test/Foo.app/bin/wine64"]))
        let e = try m.resolveWine(root: URL(fileURLWithPath: "/engines"))
        XCTAssertEqual(e.wine.path, "/engines/wine-test/Foo.app/bin/wine64")
        XCTAssertEqual(e.binDirectory.path, "/engines/wine-test/Foo.app/bin")
    }
}

final class LayerInstallerTests: XCTestCase {
    func testCopiesOnlyDLLsAndReturnsOverrides() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let pkg = tmp.appendingPathComponent("pkg/dxvk-test/x64")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: pkg.appendingPathComponent("d3d11.dll"))
        try Data("txt".utf8).write(to: pkg.appendingPathComponent("readme.txt"))
        let prefix = tmp.appendingPathComponent("prefix")

        let layer = try EngineManifest.decode(from: layerJSON)
        let overrides = try LayerInstaller.install(layer, packageRoot: tmp.appendingPathComponent("pkg"), prefix: prefix)

        let sys32 = prefix.appendingPathComponent("drive_c/windows/system32")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sys32.appendingPathComponent("d3d11.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sys32.appendingPathComponent("readme.txt").path))
        XCTAssertEqual(overrides, "d3d11,d3d10core=n,b")
    }

    func testRefusesDestinationOutsideBottle() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("pkg/dxvk-test/x64"), withIntermediateDirectories: true)
        var layer = try EngineManifest.decode(from: layerJSON)
        layer.installs = [FileInstall(source: "dxvk-test/x64", destination: "../../escape")]
        XCTAssertThrowsError(try LayerInstaller.install(layer, packageRoot: tmp.appendingPathComponent("pkg"),
                                                        prefix: tmp.appendingPathComponent("prefix"))) {
            XCTAssertEqual($0 as? LayerError, .escapesBottle("../../escape"))
        }
    }

    func testMissingSourceFails() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let layer = try EngineManifest.decode(from: layerJSON)
        XCTAssertThrowsError(try LayerInstaller.install(layer, packageRoot: tmp, prefix: tmp.appendingPathComponent("p"))) {
            XCTAssertEqual($0 as? LayerError, .sourceMissing("dxvk-test/x64"))
        }
    }

    func testRejectsWineManifest() throws {
        let m = try EngineManifest.decode(from: wineManifestJSON())
        XCTAssertThrowsError(try LayerInstaller.install(m, packageRoot: URL(fileURLWithPath: "/x"), prefix: URL(fileURLWithPath: "/y")))
    }
}

final class EngineInstallerTests: XCTestCase {
    /// Builds a local .tar.gz and a manifest pointing at it via file://.
    private func fixture(in tmp: URL, license: Bool = false, tamperHash: Bool = false, size: Int64? = nil) throws -> EngineManifest {
        let src = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: src.appendingPathComponent("bin/wine"))
        let archive = tmp.appendingPathComponent("w.tar.gz")
        let (status, out) = try EngineInstaller.run("/usr/bin/tar", ["-czf", archive.path, "-C", src.path, "."])
        XCTAssertEqual(status, 0, out)

        let digest = try EngineInstaller.sha256(of: archive)
        let actualSize = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
        var m = try EngineManifest.decode(from: wineManifestJSON([
            "url": archive.absoluteString, "sha": tamperHash ? sha : digest,
        ]))
        m.archive.size = size ?? actualSize
        if license { m.license = LicenseInfo(name: "Test license", url: nil, requiresAcceptance: true) }
        return m
    }

    private func installer(_ root: URL) -> EngineInstaller {
        var i = EngineInstaller(root: root)
        i.allowedSchemes = ["https", "file"]
        return i
    }

    func testInstallsVerifiesAndMarks() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try fixture(in: tmp)
        let i = installer(tmp.appendingPathComponent("root"))
        XCTAssertFalse(i.isInstalled(m))
        let dir = try await i.install(m, licenseAccepted: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bin/wine").path))
        XCTAssertTrue(i.isInstalled(m))
        // Second call is a no-op.
        _ = try await i.install(m, licenseAccepted: false)
    }

    func testRejectsTamperedHashAndLeavesNothing() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try fixture(in: tmp, tamperHash: true)
        let root = tmp.appendingPathComponent("root")
        do { _ = try await installer(root).install(m, licenseAccepted: false); XCTFail("expected failure") }
        catch let InstallError.hashMismatch(expected, _) { XCTAssertEqual(expected, sha) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("wine-test").path))
        XCTAssertFalse(installer(root).isInstalled(m))
    }

    func testRejectsWrongSize() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try fixture(in: tmp, size: 1)
        do { _ = try await installer(tmp.appendingPathComponent("root")).install(m, licenseAccepted: false); XCTFail("expected failure") }
        catch let InstallError.sizeMismatch(expected, _) { XCTAssertEqual(expected, 1) }
    }

    func testLicenseGateStopsBeforeAnyWork() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try fixture(in: tmp, license: true)
        let root = tmp.appendingPathComponent("root")
        do { _ = try await installer(root).install(m, licenseAccepted: false); XCTFail("expected failure") }
        catch InstallError.licenseNotAccepted(let name) { XCTAssertEqual(name, "Test license") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try await installer(root).install(m, licenseAccepted: true)
    }

    func testProductionInstallerRejectsFileURLs() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try fixture(in: tmp)
        do { _ = try await EngineInstaller(root: tmp.appendingPathComponent("root")).install(m, licenseAccepted: false); XCTFail("expected failure") }
        catch InstallError.invalidManifest(let issues) { XCTAssertEqual(issues, ["archive url must use https"]) }
    }
}
