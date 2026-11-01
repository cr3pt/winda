import Foundation

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

public enum RecipeValidator {
    public static func validate(_ recipe: Recipe) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func fail(_ m: String) { issues.append(ValidationIssue(message: m)) }

        if recipe.schemaVersion != Recipe.currentSchemaVersion {
            fail("Unsupported schemaVersion \(recipe.schemaVersion)")
        }
        if !matches(recipe.id, #"^[a-z0-9]+(-[a-z0-9]+)*$"#) {
            fail("id must be a lowercase slug")
        }
        if recipe.name.trimmingCharacters(in: .whitespaces).isEmpty {
            fail("name must not be empty")
        }
        if recipe.match.exeNames.isEmpty && recipe.match.sha256.isEmpty {
            fail("match needs at least one exe name or sha256")
        }
        for h in recipe.match.sha256 where !isSHA256(h) {
            fail("match sha256 '\(h)' is not 64 hex characters")
        }
        if recipe.rating == .incompatibleAntiCheat && !recipe.actions.isEmpty {
            fail("anti-cheat incompatible recipes must not carry actions")
        }

        var downloaded: Set<String> = []
        for action in recipe.actions {
            switch action {
            case let .setEnv(key, value):
                if !matches(key, #"^[A-Z_][A-Z0-9_]*$"#) { fail("env key '\(key)' is invalid") }
                if value.contains("\n") || value.contains("\0") { fail("env value for \(key) is invalid") }
                if ["PATH", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "WINEPREFIX", "WINEDLLOVERRIDES"].contains(key) {
                    fail("env key '\(key)' is reserved")
                }
            case let .winetricks(verb):
                if !matches(verb, #"^[a-z0-9][a-z0-9_.=-]*$"#) { fail("winetricks verb '\(verb)' is invalid") }
            case let .registry(key, name, _):
                if !matches(key, #"^HKEY_(CURRENT_USER|LOCAL_MACHINE)\\[^\n]+$"#) {
                    fail("registry key '\(key)' must start with HKEY_CURRENT_USER or HKEY_LOCAL_MACHINE")
                }
                if name.isEmpty { fail("registry value name must not be empty") }
            case let .download(url, sha256, destination):
                if url.scheme != "https" { fail("download \(url) must use https") }
                if !isSHA256(sha256) { fail("download sha256 for \(url) is invalid") }
                if destination.hasPrefix("/") || destination.split(separator: "/").contains("..") {
                    fail("download destination '\(destination)' must be relative and stay inside the bottle")
                }
                downloaded.insert(destination)
            case let .run(path, arguments):
                if !downloaded.contains(path) { fail("run '\(path)' must be a file this recipe downloaded earlier") }
                if arguments.count > 8 { fail("run takes at most 8 arguments") }
                for a in arguments where !matches(a, #"^[A-Za-z0-9/_.:=-]+$"#) { fail("run argument '\(a)' is invalid") }
            }
        }
        if let launch = recipe.launch {
            if !matches(launch.program, #"^[A-Za-z]:\\[^\n]+$"#) || launch.program.contains("..") {
                fail("launch program '\(launch.program)' must be an absolute Windows path")
            }
            if launch.arguments.count > 16 { fail("launch takes at most 16 arguments") }
            for a in launch.arguments where !matches(a, #"^[A-Za-z0-9/_.:=-]+$"#) { fail("launch argument '\(a)' is invalid") }
        }
        return issues
    }

    private static func isSHA256(_ s: String) -> Bool { matches(s, #"^[0-9a-f]{64}$"#) }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}
