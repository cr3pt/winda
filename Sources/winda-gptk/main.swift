import Foundation
import WinDACore

// winda-gptk inspect <GPTK.dmg>
// winda-gptk import  <GPTK.dmg> --root <engine-root> [--accept-license]
// winda-gptk derive  --base <wine-manifest.json> --imported <id> --root <engine-root> --manifests <dir>
func die(_ m: String, _ code: Int32 = 2) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(code) }

var a = Array(CommandLine.arguments.dropFirst())
guard let cmd = a.first else { die("usage: winda-gptk inspect|import|derive …") }
a.removeFirst()
var positional: [String] = []
var opts: [String: String] = [:]
var flags: Set<String> = []
var it = a.makeIterator()
while let x = it.next() {
    if x == "--accept-license" { flags.insert(x); continue }
    if x.hasPrefix("--") { guard let v = it.next() else { die("missing value for \(x)") }; opts[String(x.dropFirst(2))] = v }
    else { positional.append(x) }
}
func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

do {
    switch cmd {
    case "inspect":
        guard let img = positional.first else { die("usage: winda-gptk inspect <GPTK.dmg>") }
        let info = try GPTKImporter(engineRoot: URL(fileURLWithPath: "/nonexistent")).inspect(image: url(img))
        print("version: \(info.version)\nimage sha256: \(info.imageSHA256)\nlicense: \(info.licenseText.count) characters")
        print(info.licenseText.prefix(300).replacingOccurrences(of: "\n\n", with: "\n"))
    case "import":
        guard let img = positional.first, let root = opts["root"] else { die("usage: winda-gptk import <GPTK.dmg> --root R [--accept-license]") }
        let imp = GPTKImporter(engineRoot: url(root))
        do {
            let r = try imp.install(image: url(img), licenseAccepted: flags.contains("--accept-license"))
            print("imported \(r.id) (\(r.version))")
        } catch ImportError.licenseNotAccepted {
            die("Apple's license must be accepted first. Read it with `winda-gptk inspect`, then re-run with --accept-license.", 3)
        }
    case "derive":
        guard let b = opts["base"], let id = opts["imported"], let root = opts["root"], let md = opts["manifests"] else {
            die("usage: winda-gptk derive --base M --imported ID --root R --manifests DIR")
        }
        let base = try EngineManifest.decode(from: Data(contentsOf: url(b)))
        guard let rec = GPTKImporter(engineRoot: url(root)).imported().first(where: { $0.id == id }) else { die("no imported package \(id)", 1) }
        let o = try D3DMetalOverlay.deriveAndVerify(base: base, imported: rec, engineRoot: url(root), manifestsDirectory: url(md))
        print("\(o.manifest.id): smoke test \(o.smoke.passed ? "PASSED, engine registered" : "FAILED, engine discarded")")
        if !o.smoke.passed {
            print(SmokeTest.summary(o.smoke))
            exit(1)
        }
    default: die("unknown command \(cmd)")
    }
} catch {
    die("error: \(error)", 1)
}
