import Foundation

public struct SmokeResult: Equatable, Sendable {
    public var passed: Bool
    public var output: String
}

/// Runs a tiny DirectX 11 program in a throwaway bottle to prove an engine can
/// actually render, rather than trusting that it should.
public enum SmokeTest {
    public static var program: URL? { Bundle.module.url(forResource: "dx11test", withExtension: "exe") }

    /// - Parameter workDirectory: where the throwaway bottle is created. Pass a folder under the
    ///   engine store so it sits where antivirus exclusions already apply; defaults to the system temp folder.
    public static func run(engine: WineEngine, timeout: TimeInterval = 180, workDirectory: URL? = nil) throws -> SmokeResult {
        guard let program else { return SmokeResult(passed: false, output: "smoke test program is missing") }
        let base = workDirectory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let prefix = base.appendingPathComponent("winda-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        // Keep Wine's error lines so a failed check can say why.
        let runner = WineRunner(engine: engine, prefix: prefix, extraEnvironment: ["WINEDEBUG": "err+module"])
        _ = try runner.createPrefix()
        let r = try runner.run([program.path], timeout: timeout)
        return SmokeResult(passed: r.status == 0 && r.output.contains("OK:"), output: r.output)
    }

    /// The lines worth showing a person: Wine errors, or the tail of the output.
    public static func summary(_ r: SmokeResult) -> String {
        let lines = r.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("\t") && !$0.contains("mvk-") }
        let errors = lines.filter { $0.contains("err:") || $0.contains("FAIL") }
        return (errors.isEmpty ? Array(lines.suffix(4)) : Array(errors.prefix(4))).joined(separator: "\n")
    }
}

public enum OverlayError: Error, Equatable {
    case notAWineEngine(String)
    case copyFailed(String)
}

public struct OverlayOutcome: Sendable {
    public var manifest: EngineManifest
    public var smoke: SmokeResult
    /// True when the derived engine passed its smoke test and was registered.
    public var activated: Bool
}

/// Builds a copy of a Wine build with an imported D3DMetal laid over it, the way
/// Apple's README describes updating a GPTK-based Wine. The result is only
/// registered when it passes the smoke test.
public enum D3DMetalOverlay {
    public static func derivedID(base: EngineManifest, imported: ImportedGPTK) -> String {
        "\(base.id)-d3dm-\(GPTKImporter.slug(imported.version))"
    }

    /// Creates the derived engine on disk. It is not registered anywhere yet.
    public static func derive(base: EngineManifest, imported: ImportedGPTK, engineRoot: URL) throws -> EngineManifest {
        guard base.kind == .wine, let baseBinary = base.wineBinary else { throw OverlayError.notAWineEngine(base.id) }
        let fm = FileManager.default
        let baseExtract = base.archive.extractTo ?? base.id
        let id = derivedID(base: base, imported: imported)

        var derived = base
        derived.id = id
        derived.name = "\(base.name) + D3DMetal \(imported.version)"
        derived.archive.extractTo = id
        derived.priority = 100
        derived.provides = [.d3dmetal]
        derived.compatibleGraphics = [.d3dmetal]
        guard baseBinary.hasPrefix(baseExtract + "/") else { throw OverlayError.notAWineEngine(base.id) }
        derived.wineBinary = id + String(baseBinary.dropFirst(baseExtract.count))

        let src = engineRoot.appendingPathComponent(baseExtract)
        let dst = engineRoot.appendingPathComponent(id)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        // `cp -c` makes an APFS clone, so the copy costs almost no disk.
        let (cp, cpOut) = try EngineInstaller.run("/bin/cp", ["-cR", src.path, dst.path])
        guard cp == 0 else { throw OverlayError.copyFailed(cpOut) }

        let wineHome = dst.appendingPathComponent(derived.wineBinary!.dropFirst(id.count + 1).description)
            .deletingLastPathComponent().deletingLastPathComponent()
        let importedLib = engineRoot.appendingPathComponent(imported.directory).appendingPathComponent("lib")
        let libDir = wineHome.appendingPathComponent("lib")
        try? fm.removeItem(at: libDir.appendingPathComponent("external"))
        for part in ["external", "wine"] {
            let (status, out) = try EngineInstaller.run("/usr/bin/ditto",
                [importedLib.appendingPathComponent(part).path, libDir.appendingPathComponent(part).path])
            guard status == 0 else { try? fm.removeItem(at: dst); throw OverlayError.copyFailed(out) }
        }
        return derived
    }

    /// Derives the engine, smoke-tests it, and registers it only on success.
    public static func deriveAndVerify(base: EngineManifest, imported: ImportedGPTK,
                                       engineRoot: URL, manifestsDirectory: URL) throws -> OverlayOutcome {
        let derived = try derive(base: base, imported: imported, engineRoot: engineRoot)
        let engine = try derived.resolveWine(root: engineRoot)
        let smoke = try SmokeTest.run(engine: engine, workDirectory: engineRoot.appendingPathComponent(".smoke"))
        let dir = engineRoot.appendingPathComponent(derived.id)
        guard smoke.passed else {
            try? FileManager.default.removeItem(at: dir)
            return OverlayOutcome(manifest: derived, smoke: smoke, activated: false)
        }
        try FileManager.default.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(derived).write(to: manifestsDirectory.appendingPathComponent("\(derived.id).json"))
        try EngineInstaller(root: engineRoot).markInstalled(derived, sha256: imported.imageSHA256)
        return OverlayOutcome(manifest: derived, smoke: smoke, activated: true)
    }
}
