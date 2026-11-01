import CryptoKit
import Foundation

public enum ApplyError: Error, Equatable {
    case unsupported(String)
    case actionFailed(String)
    case downloadHashMismatch(url: String)
    case destinationEscapes(String)
}

/// Applies a recipe's closed set of actions to a bottle. Nothing here runs
/// recipe-supplied code: every action maps to a fixed operation.
public struct RecipeApplier: Sendable {
    public var runner: WineRunner
    /// Present when a winetricks package is installed.
    public var winetricks: WinetricksRunner?

    public init(runner: WineRunner, winetricks: WinetricksRunner? = nil) {
        self.runner = runner
        self.winetricks = winetricks
    }

    /// Returns the environment the recipe wants set when programs run.
    public func apply(_ recipe: Recipe) async throws -> [String: String] {
        var env: [String: String] = [:]
        for action in recipe.actions {
            switch action {
            case let .setEnv(key, value):
                env[key] = value
            case let .registry(key, name, value):
                let r = try runner.run(["reg", "add", key, "/v", name, "/d", value, "/f"])
                guard r.status == 0 else { throw ApplyError.actionFailed("reg add \(key): \(r.output)") }
            case let .download(url, sha256, destination):
                try await download(url: url, sha256: sha256, destination: destination)
            case let .winetricks(verb):
                guard let winetricks else { throw ApplyError.unsupported("winetricks \(verb) (winetricks is not installed)") }
                do { try winetricks.run(verb: verb) }
                catch let WinetricksError.failed(v, status, output) {
                    throw ApplyError.actionFailed("winetricks \(v) exited with \(status): \(output)")
                }
            }
        }
        return env
    }

    func download(url: URL, sha256 expected: String, destination: String) async throws {
        let fm = FileManager.default
        let driveC = runner.prefix.appendingPathComponent("drive_c").standardizedFileURL
        let dest = driveC.appendingPathComponent(destination).standardizedFileURL
        guard dest.path.hasPrefix(driveC.path + "/") else { throw ApplyError.destinationEscapes(destination) }
        if fm.fileExists(atPath: dest.path), (try? EngineInstaller.sha256(of: dest)) == expected { return }

        let (tmp, _) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: tmp) }
        guard try EngineInstaller.sha256(of: tmp) == expected else {
            throw ApplyError.downloadHashMismatch(url: url.absoluteString)
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
    }

    public static func digest(of recipe: Recipe) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try e.encode(recipe)).map { String(format: "%02x", $0) }.joined()
    }
}
