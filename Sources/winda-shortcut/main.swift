import Foundation
import WinDACore

// usage: winda-shortcut create --name N --recipe R.json --launcher L --manifests D --engine-root D
//                              --bottles D --out DIR [--logs DIR] -- <program> [args]
func die(_ m: String, _ code: Int32 = 2) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(code) }

var a = Array(CommandLine.arguments.dropFirst())
guard a.first == "create" else { die("usage: winda-shortcut create --name N --recipe R --launcher L --manifests D --engine-root D --bottles D --out DIR -- program [args]") }
a.removeFirst()
var opts: [String: String] = [:]
var program: [String] = []
var it = a.makeIterator()
while let x = it.next() {
    if x == "--" { program = Array(it); break }
    guard x.hasPrefix("--"), let v = it.next() else { die("bad argument: \(x)") }
    opts[String(x.dropFirst(2))] = v
}
guard let name = opts["name"], let recipe = opts["recipe"], let launcher = opts["launcher"], let manifests = opts["manifests"],
      let engines = opts["engine-root"], let bottles = opts["bottles"], let out = opts["out"] else { die("missing arguments") }
func abs(_ p: String) -> URL { URL(fileURLWithPath: p).standardizedFileURL }
let logs = opts["logs"].map(abs) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WinDA")
do {
    let spec = ShortcutSpec(name: name, recipe: abs(recipe), program: program, launcher: abs(launcher),
                            manifestsDirectory: abs(manifests), engineRoot: abs(engines), bottlesRoot: abs(bottles), logDirectory: logs)
    let app = try ShortcutGenerator.create(spec, in: abs(out))
    print("created \(app.path)")
} catch {
    die("error: \(error)", 1)
}
