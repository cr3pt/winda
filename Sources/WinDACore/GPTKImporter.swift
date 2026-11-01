import Foundation

public protocol DiskImageMounter: Sendable {
    /// Mounts read-only and returns the mount point.
    func attach(_ image: URL) throws -> URL
    func detach(_ mountPoint: URL)
}

/// Uses `hdiutil`. The mount point is always a local temporary directory:
/// hdiutil is refused a mount point on removable volumes, while the image
/// itself may live there.
public struct HdiutilMounter: DiskImageMounter {
    public init() {}

    public func attach(_ image: URL) throws -> URL {
        let mp = FileManager.default.temporaryDirectory.appendingPathComponent("winda-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mp, withIntermediateDirectories: true)
        let (status, out) = try EngineInstaller.run("/usr/bin/hdiutil",
            ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mp.path, image.path])
        guard status == 0 else {
            try? FileManager.default.removeItem(at: mp)
            throw ImportError.mountFailed(String(out.suffix(300)))
        }
        return mp
    }

    public func detach(_ mountPoint: URL) {
        _ = try? EngineInstaller.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
        try? FileManager.default.removeItem(at: mountPoint)
    }
}

public enum ImportError: Error, Equatable {
    case mountFailed(String)
    case notAGPTKImage
    case missingComponent(String)
    case licenseNotAccepted
    case alreadyImported(String)
}

public struct GPTKInfo: Equatable, Sendable {
    public var version: String
    public var licenseText: String
    /// SHA-256 of the image the user chose.
    public var imageSHA256: String
}

public struct ImportedGPTK: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var imageSHA256: String
    /// Directory under the engine root holding `lib/external` and `lib/wine`.
    public var directory: String
}

/// Imports Apple's Game Porting Toolkit from a disk image the user downloaded
/// themselves. WinDA never fetches or redistributes it.
public struct GPTKImporter: Sendable {
    public var mounter: DiskImageMounter
    public var engineRoot: URL

    static let required = [
        "lib/external/D3DMetal.framework/Versions/A/D3DMetal",
        "lib/external/D3DMetal.framework/Versions/A/Resources/version.plist",
        "lib/external/libd3dshared.dylib",
        "lib/wine/x86_64-windows/d3d11.dll",
        "lib/wine/x86_64-windows/dxgi.dll",
    ]

    public init(mounter: DiskImageMounter = HdiutilMounter(), engineRoot: URL) {
        self.mounter = mounter
        self.engineRoot = engineRoot
    }

    /// Mounts the image (and the evaluation-environment image inside it, if any)
    /// and calls `body` with the volume that holds `redist/` and `License.rtf`.
    func withVolume<T>(of image: URL, _ body: (URL) throws -> T) throws -> T {
        var mounted: [URL] = []
        defer { mounted.reversed().forEach(mounter.detach) }
        var volume = try mounter.attach(image)
        mounted.append(volume)
        let fm = FileManager.default
        if !fm.fileExists(atPath: volume.appendingPathComponent("redist/lib").path) {
            let inner = ((try? fm.contentsOfDirectory(atPath: volume.path)) ?? [])
                .filter { $0.hasSuffix(".dmg") && $0.localizedCaseInsensitiveContains("evaluation environment") }
                .sorted().first
            guard let inner else { throw ImportError.notAGPTKImage }
            volume = try mounter.attach(volume.appendingPathComponent(inner))
            mounted.append(volume)
        }
        guard fm.fileExists(atPath: volume.appendingPathComponent("redist/lib").path) else { throw ImportError.notAGPTKImage }
        return try body(volume)
    }

    static func version(in redist: URL) throws -> String {
        let plist = redist.appendingPathComponent("lib/external/D3DMetal.framework/Versions/A/Resources/version.plist")
        guard let d = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              let v = d["CFBundleShortVersionString"] as? String, !v.isEmpty else { throw ImportError.missingComponent("version") }
        return v
    }

    static func licenseText(in volume: URL) -> String {
        let rtf = volume.appendingPathComponent("License.rtf")
        guard FileManager.default.fileExists(atPath: rtf.path),
              let (status, out) = try? EngineInstaller.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", rtf.path]),
              status == 0 else { return "" }
        return out
    }

    static func slug(_ version: String) -> String {
        version.lowercased().replacingOccurrences(of: "[^a-z0-9.]+", with: "-", options: .regularExpression)
    }

    /// Reads version and license without installing anything.
    public func inspect(image: URL) throws -> GPTKInfo {
        let digest = try EngineInstaller.sha256(of: image)
        return try withVolume(of: image) { volume in
            let redist = volume.appendingPathComponent("redist")
            for c in Self.required where !FileManager.default.fileExists(atPath: redist.appendingPathComponent(c).path) {
                throw ImportError.missingComponent(c)
            }
            return GPTKInfo(version: try Self.version(in: redist), licenseText: Self.licenseText(in: volume), imageSHA256: digest)
        }
    }

    public func imported() -> [ImportedGPTK] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: engineRoot.path)) ?? []).filter { $0.hasPrefix("d3dmetal-") }.sorted()
        return names.compactMap { n in
            (try? Data(contentsOf: engineRoot.appendingPathComponent(n).appendingPathComponent("imported.json")))
                .flatMap { try? JSONDecoder().decode(ImportedGPTK.self, from: $0) }
        }
    }

    /// Copies `redist/lib` into the engine store. The user must have seen and
    /// accepted Apple's license first.
    @discardableResult
    public func install(image: URL, licenseAccepted: Bool) throws -> ImportedGPTK {
        guard licenseAccepted else { throw ImportError.licenseNotAccepted }
        let info = try inspect(image: image)
        let id = "d3dmetal-\(Self.slug(info.version))"
        let dir = engineRoot.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("imported.json").path) {
            throw ImportError.alreadyImported(id)
        }
        let record = ImportedGPTK(id: id, version: info.version, imageSHA256: info.imageSHA256, directory: id)
        try withVolume(of: image) { volume in
            let fm = FileManager.default
            let staging = engineRoot.appendingPathComponent(".staging-\(UUID().uuidString)")
            try fm.createDirectory(at: staging.appendingPathComponent("lib"), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            for part in ["external", "wine"] {
                let (status, out) = try EngineInstaller.run("/usr/bin/ditto",
                    [volume.appendingPathComponent("redist/lib/\(part)").path, staging.appendingPathComponent("lib/\(part)").path])
                guard status == 0 else { throw ImportError.missingComponent("copy \(part): \(out)") }
            }
            try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("imported.json"))
            try fm.moveItem(at: staging, to: dir)
        }
        return record
    }
}
