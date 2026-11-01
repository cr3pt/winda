import Foundation

public enum WrapError: Error, Equatable {
    case targetMissing(String)
    case wrapperMissing
    case escapesBottle(String)
}

/// Puts a small launcher in front of a Windows program so extra switches are added every time it starts.
/// The original is kept as `<name>_real.exe`. Safe to repeat: a program that replaced the wrapper
/// (for example after an update) is wrapped again.
public enum ExecutableWrapper {
    public static var wrapperBinary: URL? { Bundle.module.url(forResource: "helper-wrapper", withExtension: "exe") }

    public static func ensure(prefix: URL, path: String, arguments: [String], wrapper: URL? = nil) throws {
        guard let wrapper = wrapper ?? wrapperBinary else { throw WrapError.wrapperMissing }
        let fm = FileManager.default
        let driveC = prefix.appendingPathComponent("drive_c").standardizedFileURL
        let target = driveC.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(driveC.path + "/") else { throw WrapError.escapesBottle(path) }
        let real = target.deletingLastPathComponent()
            .appendingPathComponent(target.deletingPathExtension().lastPathComponent + "_real.exe")

        let wrapperDigest = try EngineInstaller.sha256(of: wrapper)
        let targetIsWrapper = fm.fileExists(atPath: target.path) && (try? EngineInstaller.sha256(of: target)) == wrapperDigest
        if !targetIsWrapper {
            guard fm.fileExists(atPath: target.path) else { throw WrapError.targetMissing(path) }
            // A fresh original (first run, or the program updated itself): keep it as the "real" one.
            if fm.fileExists(atPath: real.path) { try fm.removeItem(at: real) }
            try fm.moveItem(at: target, to: real)
            try fm.copyItem(at: wrapper, to: target)
        }
        try Data((arguments.joined(separator: " ") + "\n").utf8).write(to: URL(fileURLWithPath: target.path + ".wrapargs"))
    }
}
