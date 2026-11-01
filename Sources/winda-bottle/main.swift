import Foundation
import WinDACore

// usage: winda-bottle launch --recipe R.json --manifests DIR --engine-root DIR --bottles DIR -- <program> [args]
func die(_ m: String, _ code: Int32 = 2) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(code) }

var a = Array(CommandLine.arguments.dropFirst())
guard a.first == "launch" else { die("usage: winda-bottle launch --recipe R --manifests D --engine-root D --bottles D -- program [args]") }
a.removeFirst()
var opts: [String: String] = [:]
var program: [String] = []
var it = a.makeIterator()
while let x = it.next() {
    if x == "--" { program = Array(it); break }
    guard x.hasPrefix("--"), let v = it.next() else { die("bad argument: \(x)") }
    opts[String(x.dropFirst(2))] = v
}
guard let rp = opts["recipe"], let md = opts["manifests"], let er = opts["engine-root"], let bd = opts["bottles"], !program.isEmpty else {
    die("missing arguments")
}
do {
    let recipe = try Recipe.decode(from: Data(contentsOf: URL(fileURLWithPath: rp)))
    let manifests = try FileManager.default.contentsOfDirectory(atPath: md).filter { $0.hasSuffix(".json") }.sorted()
        .map { try EngineManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: md).appendingPathComponent($0))) }
    let launcher = Launcher(manifests: manifests, engineRoot: URL(fileURLWithPath: er),
                            bottles: BottleStore(root: URL(fileURLWithPath: bd)),
                            cache: opts["cache"].map { URL(fileURLWithPath: $0) })
    let t0 = Date()
    let r = try await launcher.launch(recipe: recipe, program: program)
    print("recipe \(recipe.id): status=\(r.status) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    print(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    exit(r.status)
} catch {
    die("error: \(error)", 1)
}
