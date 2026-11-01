import Foundation
import WinDACore

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, ["validate", "validate-engine"].contains(command), args.count > 1 else {
    FileHandle.standardError.write(Data("usage: winda-recipe validate|validate-engine <file.json>...\n".utf8))
    exit(2)
}

var failed = false
for path in args.dropFirst() {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let issues = command == "validate-engine"
            ? EngineManifestValidator.validate(try EngineManifest.decode(from: data))
            : RecipeValidator.validate(try Recipe.decode(from: data))
        if issues.isEmpty {
            print("ok   \(path)")
        } else {
            failed = true
            print("FAIL \(path)")
            issues.forEach { print("     - \($0)") }
        }
    } catch {
        failed = true
        print("FAIL \(path)\n     - \(error)")
    }
}
exit(failed ? 1 : 0)
