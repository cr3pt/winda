import Foundation
import WinDACore

// usage: winda-spike --engine <manifest.json> --engine-root <dir>
//                    [--layer <manifest.json> --layer-root <dir>]
//                    --prefix <dir> [-- wine args...]
func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

var opts: [String: String] = [:]
var wineArgs: [String] = []
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--" { wineArgs = Array(it); break }
    guard a.hasPrefix("--"), let v = it.next() else { die("bad argument: \(a)") }
    opts[String(a.dropFirst(2))] = v
}
guard let em = opts["engine"], let er = opts["engine-root"], let pf = opts["prefix"] else {
    die("usage: winda-spike --engine M --engine-root D [--layer M --layer-root D] --prefix P [-- wine args...]")
}

func load(_ path: String) throws -> EngineManifest {
    let m = try EngineManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
    let issues = EngineManifestValidator.validate(m)
    if !issues.isEmpty { die("invalid manifest \(path):\n" + issues.map { "  - \($0)" }.joined(separator: "\n")) }
    return m
}

do {
    let engine = try load(em)
    let prefix = URL(fileURLWithPath: pf)
    var env: [String: String] = [:]
    var runner = WineRunner(engine: try engine.resolveWine(root: URL(fileURLWithPath: er)), prefix: prefix)
    _ = try runner.createPrefix()

    if let lm = opts["layer"], let lr = opts["layer-root"] {
        let layer = try load(lm)
        let overrides = try LayerInstaller.install(layer, packageRoot: URL(fileURLWithPath: lr), prefix: prefix)
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml=;" + overrides
        print("layer \(layer.id): installed, overrides=\(overrides)")
    }
    runner.extraEnvironment = env

    let args = wineArgs.isEmpty ? ["cmd", "/c", "ver"] : wineArgs
    let t0 = Date()
    let r = try runner.run(args)
    print("engine \(engine.id): status=\(r.status) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    print(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    exit(r.status)
} catch {
    print("error: \(error)")
    exit(1)
}
