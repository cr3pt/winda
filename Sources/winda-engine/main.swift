import Foundation
import WinDACore

// usage: winda-engine install <manifest.json> --root <dir> [--accept-license]
let a = Array(CommandLine.arguments.dropFirst())
func die(_ m: String, _ code: Int32 = 2) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(code) }

guard a.count >= 4, a[0] == "install", let ri = a.firstIndex(of: "--root"), ri + 1 < a.count else {
    die("usage: winda-engine install <manifest.json> --root <dir> [--accept-license]")
}
do {
    let manifest = try EngineManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: a[1])))
    let installer = EngineInstaller(root: URL(fileURLWithPath: a[ri + 1]))
    if installer.isInstalled(manifest) { print("already installed: \(manifest.id)") }
    let dir = try await installer.install(manifest, licenseAccepted: a.contains("--accept-license"))
    print("installed \(manifest.id) -> \(dir.path)")
} catch InstallError.licenseNotAccepted(let name) {
    die("license not accepted: \(name)\nre-run with --accept-license after reading it", 3)
} catch {
    die("error: \(error)", 1)
}
