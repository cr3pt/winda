import Foundation

public struct WineEngine: Sendable {
    /// Full path of the wine executable (`wine` or `wine64`, depending on the build).
    public var wine: URL
    public var binDirectory: URL { wine.deletingLastPathComponent() }

    public init(wine: URL) { self.wine = wine }
}

public struct WineResult: Sendable {
    public var status: Int32
    public var output: String
}

public enum WineError: Error { case engineMissing(URL), launchFailed(String), notAWineEngine(String) }

/// Runs a Windows program in a bottle. Environment is built from scratch:
/// only what WinDA sets reaches Wine, plus recipe `setEnv` values.
public struct WineRunner: Sendable {
    public var engine: WineEngine
    public var prefix: URL
    public var extraEnvironment: [String: String]

    public init(engine: WineEngine, prefix: URL, extraEnvironment: [String: String] = [:]) {
        self.engine = engine
        self.prefix = prefix
        self.extraEnvironment = extraEnvironment
    }

    func environment() -> [String: String] {
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "\(engine.binDirectory.path):/usr/bin:/bin",
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all",
            // Skip Mono/Gecko download prompts during prefix creation.
            "WINEDLLOVERRIDES": "mscoree,mshtml=",
        ]
        // CrossOver-based Wine builds load D3DMetal's helper from here; builds that do not know the variable ignore it.
        let shared = engine.wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/external/libd3dshared.dylib")
        if FileManager.default.fileExists(atPath: shared.path) { env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = shared.path }
        env.merge(extraEnvironment) { _, new in new }
        return env
    }

    /// Wine is an x86_64 binary; on Apple Silicon it runs under Rosetta 2.
    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval = 120) throws -> WineResult {
        guard FileManager.default.isExecutableFile(atPath: engine.wine.path) else {
            throw WineError.engineMissing(engine.wine)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", engine.wine.path] + arguments
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { throw WineError.launchFailed("\(error)") }

        let deadline = Date().addingTimeInterval(timeout)
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let data = (try? Self.await(reader)) ?? Data()
        return WineResult(status: process.terminationStatus,
                          output: String(decoding: data, as: UTF8.self))
    }

    private static func await(_ task: Task<Data, Never>) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out = Data()
        Task { out = await task.value; sem.signal() }
        sem.wait()
        return out
    }

    public func createPrefix() throws -> WineResult { try run(["wineboot", "--init"]) }

    /// Waits until every process in this bottle has exited (`wineserver -w`), or the time runs out.
    @discardableResult
    public func waitForExit(timeout: TimeInterval) -> Bool {
        let server = engine.binDirectory.appendingPathComponent("wineserver")
        guard FileManager.default.isExecutableFile(atPath: server.path) else { return true }
        let p = Process()
        p.executableURL = server
        p.arguments = ["-w"]
        p.environment = environment()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return false }
        return true
    }

    /// Stops every process running in this bottle (`wineserver -k`).
    public func stopAll() {
        let server = engine.binDirectory.appendingPathComponent("wineserver")
        guard FileManager.default.isExecutableFile(atPath: server.path) else { return }
        let p = Process()
        p.executableURL = server
        p.arguments = ["-k"]
        p.environment = environment()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
