import CryptoKit
import Foundation

public enum InstallError: Error, Equatable {
    case invalidManifest([String])
    case licenseNotAccepted(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch(expected: String, actual: String)
    case extractFailed(String)
}

/// Downloads an engine package, verifies it against its manifest and
/// extracts it under `root`. A package is never visible at its final
/// location until size and SHA-256 matched and extraction succeeded.
public struct EngineInstaller: Sendable {
    public var root: URL
    /// Only https in production; tests add "file" to install from a local archive.
    var allowedSchemes: Set<String> = ["https"]

    public init(root: URL) { self.root = root }

    private var markerDirectory: URL { root.appendingPathComponent(".installed") }
    private func marker(for m: EngineManifest) -> URL { markerDirectory.appendingPathComponent("\(m.id).json") }

    /// Records a package as installed without downloading it (used for engines WinDA derives itself).
    public func markInstalled(_ m: EngineManifest, sha256: String) throws {
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        let record = ["id": m.id, "version": m.version, "sha256": sha256]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: marker(for: m))
    }

    public func isInstalled(_ m: EngineManifest) -> Bool {
        FileManager.default.fileExists(atPath: marker(for: m).path)
    }

    /// - Parameter licenseAccepted: must be true for manifests whose license
    ///   `requiresAcceptance`; the UI sets it only after showing the license.
    @discardableResult
    public func install(_ m: EngineManifest, licenseAccepted: Bool) async throws -> URL {
        let issues = EngineManifestValidator.validate(m, allowedSchemes: allowedSchemes)
        guard issues.isEmpty else { throw InstallError.invalidManifest(issues.map(\.message)) }
        if let l = m.license, l.requiresAcceptance, !licenseAccepted {
            throw InstallError.licenseNotAccepted(l.name)
        }
        let fm = FileManager.default
        let target = root.appendingPathComponent(m.archive.extractTo ?? m.id)
        if isInstalled(m) { return target }

        let (tmp, _) = try await URLSession.shared.download(from: m.archive.url)
        defer { try? fm.removeItem(at: tmp) }

        let size = (try fm.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? -1
        guard size == m.archive.size else { throw InstallError.sizeMismatch(expected: m.archive.size, actual: size) }
        let digest = try Self.sha256(of: tmp)
        guard digest == m.archive.sha256 else { throw InstallError.hashMismatch(expected: m.archive.sha256, actual: digest) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let stagedTarget = staging.appendingPathComponent(m.archive.extractTo ?? m.id)
        try fm.createDirectory(at: stagedTarget, withIntermediateDirectories: true)
        try Self.extract(archive: tmp, into: stagedTarget)

        // Archives downloaded over the network carry quarantine attributes; the
        // hash check above is what establishes trust, so clear them.
        _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedTarget.path])

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: stagedTarget, to: target)

        try fm.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        let record = ["id": m.id, "version": m.version, "sha256": digest]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: marker(for: m))
        return target
    }

    static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// bsdtar refuses absolute paths and ".." components by default (no -P).
    static func extract(archive: URL, into dir: URL) throws {
        let (status, out) = try run("/usr/bin/tar", ["-xf", archive.path, "-C", dir.path])
        guard status == 0 else { throw InstallError.extractFailed(out) }
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
