import Foundation

public enum WinetricksError: Error, Equatable {
    case toolMissing(String)
    case dependencyMissing(String)
    case failed(verb: String, status: Int32, output: String)
}

/// Runs a pinned winetricks script against a bottle. The verb has already
/// been validated, and it is passed as a separate argument, never through a shell.
public struct WinetricksRunner: Sendable {
    public var script: URL
    public var engine: WineEngine
    public var prefix: URL
    /// Shared download cache, so a runtime is fetched once for all bottles.
    public var cache: URL
    /// Directories searched for helpers such as cabextract.
    public var helperPaths: [String]

    public init(script: URL, engine: WineEngine, prefix: URL, cache: URL,
                helperPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) {
        self.script = script
        self.engine = engine
        self.prefix = prefix
        self.cache = cache
        self.helperPaths = helperPaths
    }

    func findHelper(_ name: String) -> String? {
        for dir in helperPaths + ["/usr/bin", "/bin"] {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func environment() -> [String: String] {
        let wineserver = engine.binDirectory.appendingPathComponent("wineserver").path
        return [
            "HOME": NSHomeDirectory(),
            "PATH": ([engine.binDirectory.path] + helperPaths + ["/usr/bin", "/bin"]).joined(separator: ":"),
            "WINE": engine.wine.path,
            "WINESERVER": wineserver,
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "mscoree,mshtml=",
            "W_CACHE": cache.path,
            "WINETRICKS_SUPER_QUIET": "1",
        ]
    }

    @discardableResult
    public func run(verb: String, timeout: TimeInterval = 1800) throws -> String {
        guard FileManager.default.fileExists(atPath: script.path) else { throw WinetricksError.toolMissing(script.path) }
        guard findHelper("cabextract") != nil else {
            throw WinetricksError.dependencyMissing("cabextract (install it with: brew install cabextract)")
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "-q", verb]
        p.environment = environment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var data = Data()
        Task { data = await reader.value; sem.signal() }
        sem.wait()
        let out = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw WinetricksError.failed(verb: verb, status: p.terminationStatus, output: String(out.suffix(2000)))
        }
        return out
    }
}
