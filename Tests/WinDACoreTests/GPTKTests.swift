import Foundation
import XCTest
@testable import WinDACore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("winda-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Pretends to mount images by returning a prepared directory.
private final class FakeMounter: DiskImageMounter, @unchecked Sendable {
    var volumes: [String: URL] = [:]
    private let lock = NSLock()
    private var detachedLog: [String] = []
    var detached: [String] { lock.lock(); defer { lock.unlock() }; return detachedLog }

    func attach(_ image: URL) throws -> URL {
        guard let v = volumes[image.path] else { throw ImportError.mountFailed("unknown image \(image.path)") }
        return v
    }
    func detach(_ mountPoint: URL) { lock.lock(); detachedLog.append(mountPoint.lastPathComponent); lock.unlock() }
}

private func makeRedist(at volume: URL, version: String = "9.9b1", skip: String? = nil) throws {
    let files = [
        "lib/external/D3DMetal.framework/Versions/A/D3DMetal": "binary",
        "lib/external/D3DMetal.framework/Versions/A/Resources/version.plist":
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>",
        "lib/external/libd3dshared.dylib": "shared",
        "lib/wine/x86_64-windows/d3d11.dll": "d3d11-new",
        "lib/wine/x86_64-windows/dxgi.dll": "dxgi-new",
    ]
    for (p, c) in files where p != skip { try write(c, to: volume.appendingPathComponent("redist/\(p)")) }
}

private struct Fixture {
    let tmp: URL
    let dmg: URL
    let mounter: FakeMounter
    let importer: GPTKImporter
}

private func fixture(nested: Bool = true, version: String = "9.9b1", skip: String? = nil) throws -> Fixture {
    let tmp = try tempDir()
    let mounter = FakeMounter()
    let dmg = tmp.appendingPathComponent("GPTK.dmg")
    try Data("x".utf8).write(to: dmg)
    let outer = tmp.appendingPathComponent("outer")
    let inner = tmp.appendingPathComponent("inner")
    try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    if nested {
        try Data("y".utf8).write(to: outer.appendingPathComponent("Evaluation environment for Windows games 9.dmg"))
        mounter.volumes[dmg.path] = outer
        mounter.volumes[outer.appendingPathComponent("Evaluation environment for Windows games 9.dmg").path] = inner
        try makeRedist(at: inner, version: version, skip: skip)
        try write("{\\rtf1 Test license text}", to: inner.appendingPathComponent("License.rtf"))
    } else {
        mounter.volumes[dmg.path] = outer
        try makeRedist(at: outer, version: version, skip: skip)
    }
    return Fixture(tmp: tmp, dmg: dmg, mounter: mounter,
                   importer: GPTKImporter(mounter: mounter, engineRoot: tmp.appendingPathComponent("engines")))
}

final class GPTKImporterTests: XCTestCase {
    func testInspectsNestedImageAndDetachesBoth() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.tmp) }
        let info = try f.importer.inspect(image: f.dmg)
        XCTAssertEqual(info.version, "9.9b1")
        XCTAssertTrue(info.licenseText.contains("Test license text"))
        XCTAssertEqual(info.imageSHA256, try EngineInstaller.sha256(of: f.dmg))
        XCTAssertEqual(f.mounter.detached, ["inner", "outer"])
    }

    func testInspectsFlatImage() throws {
        let f = try fixture(nested: false); defer { try? FileManager.default.removeItem(at: f.tmp) }
        XCTAssertEqual(try f.importer.inspect(image: f.dmg).version, "9.9b1")
        XCTAssertEqual(f.mounter.detached, ["outer"])
    }

    func testMissingComponentIsReportedAndImageStillDetached() throws {
        let f = try fixture(skip: "lib/external/libd3dshared.dylib"); defer { try? FileManager.default.removeItem(at: f.tmp) }
        XCTAssertThrowsError(try f.importer.inspect(image: f.dmg)) {
            XCTAssertEqual($0 as? ImportError, .missingComponent("lib/external/libd3dshared.dylib"))
        }
        XCTAssertEqual(f.mounter.detached.count, 2)
    }

    func testRejectsImageThatIsNotGPTK() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let mounter = FakeMounter()
        let dmg = tmp.appendingPathComponent("other.dmg")
        try Data("x".utf8).write(to: dmg)
        let empty = tmp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        mounter.volumes[dmg.path] = empty
        XCTAssertThrowsError(try GPTKImporter(mounter: mounter, engineRoot: tmp).inspect(image: dmg)) {
            XCTAssertEqual($0 as? ImportError, .notAGPTKImage)
        }
        XCTAssertEqual(mounter.detached.count, 1)
    }

    func testInstallRequiresLicenseAcceptanceAndTouchesNothingWithout() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.tmp) }
        XCTAssertThrowsError(try f.importer.install(image: f.dmg, licenseAccepted: false)) {
            XCTAssertEqual($0 as? ImportError, .licenseNotAccepted)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.importer.engineRoot.path))
        XCTAssertTrue(f.mounter.detached.isEmpty)
    }

    func testInstallCopiesFilesRecordsAndRefusesDuplicates() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.tmp) }
        let rec = try f.importer.install(image: f.dmg, licenseAccepted: true)
        XCTAssertEqual(rec.id, "d3dmetal-9.9b1")
        let dir = f.importer.engineRoot.appendingPathComponent(rec.directory)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8), "d3d11-new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("lib/external/libd3dshared.dylib").path))
        XCTAssertEqual(f.importer.imported(), [rec])
        XCTAssertThrowsError(try f.importer.install(image: f.dmg, licenseAccepted: true)) {
            XCTAssertEqual($0 as? ImportError, .alreadyImported("d3dmetal-9.9b1"))
        }
        // No staging leftovers.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.importer.engineRoot.path).filter { $0.hasPrefix(".staging") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSlug() {
        XCTAssertEqual(GPTKImporter.slug("4.0b3"), "4.0b3")
        XCTAssertEqual(GPTKImporter.slug("4.0 Beta/3"), "4.0-beta-3")
    }
}

final class OverlayTests: XCTestCase {
    private func base(in root: URL) throws -> EngineManifest {
        let wineHome = root.appendingPathComponent("base-wine/App.app/Contents/Resources/wine")
        try write("exe", to: wineHome.appendingPathComponent("bin/wine64"))
        try write("old-framework", to: wineHome.appendingPathComponent("lib/external/D3DMetal.framework/old"))
        try write("old-d3d11", to: wineHome.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"))
        try write("keep-me", to: wineHome.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll"))
        return EngineManifest(schemaVersion: 1, id: "base-wine", name: "Base Wine", kind: .wine, version: "1",
            archive: Archive(url: URL(string: "https://example.com/b")!, sha256: String(repeating: "e", count: 64), size: 1, extractTo: "base-wine"),
            license: nil, provides: [.d3dmetal], wineBinary: "base-wine/App.app/Contents/Resources/wine/bin/wine64",
            compatibleGraphics: [.d3dmetal], installs: nil, dllOverrides: nil)
    }

    func testDeriveClonesAndOverlaysWithoutTouchingTheBase() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.tmp) }
        let rec = try f.importer.install(image: f.dmg, licenseAccepted: true)
        let root = f.importer.engineRoot
        let base = try base(in: root)

        let derived = try D3DMetalOverlay.derive(base: base, imported: rec, engineRoot: root)
        XCTAssertEqual(derived.id, "base-wine-d3dm-9.9b1")
        XCTAssertEqual(derived.wineBinary, "base-wine-d3dm-9.9b1/App.app/Contents/Resources/wine/bin/wine64")
        XCTAssertEqual(derived.archive.extractTo, "base-wine-d3dm-9.9b1")
        XCTAssertTrue(EngineManifestValidator.validate(derived).isEmpty)

        let lib = root.appendingPathComponent("base-wine-d3dm-9.9b1/App.app/Contents/Resources/wine/lib")
        func read(_ p: String) -> String? { try? String(contentsOf: lib.appendingPathComponent(p), encoding: .utf8) }
        XCTAssertEqual(read("wine/x86_64-windows/d3d11.dll"), "d3d11-new")
        XCTAssertEqual(read("wine/x86_64-windows/ntdll.dll"), "keep-me")
        XCTAssertNil(read("external/D3DMetal.framework/old"), "old framework must be replaced, not merged")
        XCTAssertNotNil(read("external/libd3dshared.dylib"))

        let baseLib = root.appendingPathComponent("base-wine/App.app/Contents/Resources/wine/lib")
        XCTAssertEqual(try String(contentsOf: baseLib.appendingPathComponent("wine/x86_64-windows/d3d11.dll"), encoding: .utf8), "old-d3d11")
    }

    func testDeriveRejectsNonWineEngines() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.tmp) }
        let rec = try f.importer.install(image: f.dmg, licenseAccepted: true)
        var b = try base(in: f.importer.engineRoot)
        b.kind = .graphicsLayer
        XCTAssertThrowsError(try D3DMetalOverlay.derive(base: b, imported: rec, engineRoot: f.importer.engineRoot))
    }

    func testSmokeTestProgramIsBundled() {
        XCTAssertNotNil(SmokeTest.program)
    }

    func testSmokeSummaryPrefersErrorLines() {
        let r = SmokeResult(passed: false, output: "noise\n\tdetail\nerr:module:x failed\nmore")
        XCTAssertEqual(SmokeTest.summary(r), "err:module:x failed")
    }
}
