import Foundation

/// A game Steam knows about in one library folder.
public struct SteamGame: Equatable, Identifiable, Sendable {
    public var id: String { appID }
    public var appID: String
    public var name: String
    public var installDir: String
    /// Bytes on disk right now (0 while the game is only staged).
    public var sizeOnDisk: Int64
    public var bytesToDownload: Int64
    public var bytesDownloaded: Int64
    public var stateFlags: Int

    /// Steam sets bit 4 (FullyInstalled) once the game is complete and usable.
    public var isInstalled: Bool { stateFlags & 4 != 0 }
    public var isBusy: Bool { !isInstalled }
    /// 0...1 while downloading or staging, nil when there is nothing to download.
    public var progress: Double? {
        guard bytesToDownload > 0, !isInstalled else { return nil }
        return min(1, Double(bytesDownloaded) / Double(bytesToDownload))
    }
}

/// Reads Steam's `appmanifest_*.acf` files. No Steam login or network is involved.
public enum SteamLibrary {
    /// Steam components that appear as apps but are not games.
    static let hidden: Set<String> = ["228980"]   // Steamworks Common Redistributables

    /// Top-level `"key" "value"` pairs of an ACF file (nested blocks are skipped).
    public static func parseACF(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var depth = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" { depth += 1; continue }
            if line == "}" { depth -= 1; continue }
            guard depth == 1 else { continue }
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if parts.count >= 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    public static func games(inSteamRoot root: URL) -> [SteamGame] {
        let dir = root.appendingPathComponent("steamapps")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }.sorted()
        return files.compactMap { f in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { return nil }
            let kv = parseACF(text)
            guard let id = kv["appid"], !hidden.contains(id), let name = kv["name"] else { return nil }
            func n(_ k: String) -> Int64 { Int64(kv[k] ?? "") ?? 0 }
            return SteamGame(appID: id, name: name, installDir: kv["installdir"] ?? "", sizeOnDisk: n("SizeOnDisk"),
                             bytesToDownload: n("BytesToDownload"), bytesDownloaded: n("BytesDownloaded"),
                             stateFlags: Int(kv["StateFlags"] ?? "") ?? 0)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Maps `C:\Program Files (x86)\Steam\steam.exe` to the folder inside a bottle's prefix.
    public static func unixURL(forWindowsPath path: String, prefix: URL) -> URL? {
        guard path.count > 3, path.dropFirst().hasPrefix(":\\") else { return nil }
        let rest = path.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        guard !rest.split(separator: "/").contains("..") else { return nil }
        return prefix.appendingPathComponent("drive_\(path.first!.lowercased())").appendingPathComponent(rest)
    }
}
