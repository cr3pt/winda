import Foundation

public struct Archive: Codable, Equatable, Sendable {
    public var url: URL
    public var sha256: String
    public var size: Int64
    /// Directory the archive is extracted into, relative to the engine's install root.
    public var extractTo: String?
}

public struct LicenseInfo: Codable, Equatable, Sendable {
    public var name: String
    public var url: URL?
    /// The user must see and accept this license before the package is installed.
    public var requiresAcceptance: Bool
}

public struct FileInstall: Codable, Equatable, Sendable {
    /// Path inside the extracted package.
    public var source: String
    /// Path inside the bottle's C: drive, e.g. "windows/system32".
    public var destination: String
}

public enum EngineKind: String, Codable, Sendable {
    /// A Wine build that can run programs on its own.
    case wine
    /// DLLs copied into a bottle on top of a Wine build (e.g. DXVK).
    case graphicsLayer
    /// A helper program WinDA runs against a bottle (e.g. winetricks).
    case tool
}

/// Describes one downloadable engine package. Engines are replaceable per
/// bottle; the app never hardcodes paths into a specific Wine build.
public struct EngineManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var kind: EngineKind
    public var version: String
    public var archive: Archive
    public var license: LicenseInfo?
    /// Graphics paths this package provides, e.g. ["d3dmetal"] or ["dxvk"].
    public var provides: [GraphicsEngine]

    // kind == .wine
    /// Path of the wine executable relative to the extracted root.
    public var wineBinary: String?
    /// Graphics paths that must NOT be combined with this build (e.g. D3DMetal needs its own Wine).
    public var compatibleGraphics: [GraphicsEngine]?

    /// Higher wins when several engines fit a recipe. Engines WinDA derives and verifies
    /// itself get a high value so they win over the stock build they came from.
    public var priority: Int?

    // kind == .tool
    /// Path of the tool's entry point relative to the extracted root.
    public var toolBinary: String?

    // kind == .graphicsLayer
    public var installs: [FileInstall]?
    /// Value pieces for WINEDLLOVERRIDES, e.g. "d3d11,dxgi=n,b".
    public var dllOverrides: [String]?

    public static let currentSchemaVersion = 1

    public static func decode(from data: Data) throws -> EngineManifest {
        try JSONDecoder().decode(EngineManifest.self, from: data)
    }

    public func resolveTool(root: URL) throws -> URL {
        guard kind == .tool, let toolBinary else { throw WineError.notAWineEngine(id) }
        return root.appendingPathComponent(toolBinary)
    }

    /// Resolves the wine executable for a given install root.
    public func resolveWine(root: URL) throws -> WineEngine {
        guard kind == .wine, let wineBinary else { throw WineError.notAWineEngine(id) }
        let exe = root.appendingPathComponent(wineBinary)
        return WineEngine(wine: exe)
    }
}

public enum EngineManifestValidator {
    public static func validate(_ m: EngineManifest, allowedSchemes: Set<String> = ["https"]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func fail(_ s: String) { issues.append(ValidationIssue(message: s)) }
        func rx(_ s: String, _ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
        func safeRelative(_ p: String) -> Bool { !p.hasPrefix("/") && !p.split(separator: "/").contains("..") }

        if m.schemaVersion != EngineManifest.currentSchemaVersion { fail("Unsupported schemaVersion \(m.schemaVersion)") }
        if !rx(m.id, #"^[a-z0-9]+(-[a-z0-9.]+)*$"#) { fail("id must be a lowercase slug") }
        if !allowedSchemes.contains(m.archive.url.scheme ?? "") { fail("archive url must use https") }
        if !rx(m.archive.sha256, #"^[0-9a-f]{64}$"#) { fail("archive sha256 is invalid") }
        if m.archive.size <= 0 { fail("archive size must be positive") }
        if let to = m.archive.extractTo, !safeRelative(to) { fail("extractTo must be relative and stay inside the install root") }
        if m.kind != .tool && m.provides.isEmpty { fail("provides must list at least one graphics path") }
        if m.provides.contains(.auto) { fail("provides cannot contain 'auto'") }

        switch m.kind {
        case .wine:
            guard let bin = m.wineBinary else { fail("wine engines need wineBinary"); break }
            if !safeRelative(bin) { fail("wineBinary must be relative and stay inside the install root") }
            if m.installs != nil || m.dllOverrides != nil || m.toolBinary != nil {
                fail("wine engines must not define installs, dllOverrides or toolBinary")
            }
        case .tool:
            guard let bin = m.toolBinary else { fail("tools need toolBinary"); break }
            if !safeRelative(bin) { fail("toolBinary must be relative and stay inside the install root") }
            if m.wineBinary != nil || m.installs != nil || m.dllOverrides != nil { fail("tools must not define wine or layer fields") }
        case .graphicsLayer:
            if m.wineBinary != nil || m.toolBinary != nil { fail("graphicsLayer must not define wineBinary or toolBinary") }
            guard let installs = m.installs, !installs.isEmpty else { fail("graphicsLayer needs installs"); break }
            for i in installs {
                if !safeRelative(i.source) { fail("install source '\(i.source)' must be relative") }
                if !safeRelative(i.destination) { fail("install destination '\(i.destination)' must stay inside the bottle") }
            }
            for o in m.dllOverrides ?? [] where !rx(o, #"^[a-z0-9_,.]+=(n|b|d|n,b|b,n)$"#) {
                fail("dllOverride '\(o)' is invalid")
            }
        }
        if let l = m.license, l.url != nil, l.url?.scheme != "https" { fail("license url must use https") }
        return issues
    }
}
