import Foundation

public enum LayerError: Error, Equatable {
    case notAGraphicsLayer(String)
    case sourceMissing(String)
    case escapesBottle(String)
}

/// Copies a graphics layer's files into a bottle and reports the DLL
/// overrides Wine needs to prefer them.
public enum LayerInstaller {
    /// - Parameters:
    ///   - packageRoot: where the layer archive was extracted.
    ///   - prefix: the bottle's WINEPREFIX; files land under `drive_c`.
    /// - Returns: the `WINEDLLOVERRIDES` value contributed by the layer.
    @discardableResult
    public static func install(_ layer: EngineManifest, packageRoot: URL, prefix: URL) throws -> String {
        guard layer.kind == .graphicsLayer, let installs = layer.installs else {
            throw LayerError.notAGraphicsLayer(layer.id)
        }
        let fm = FileManager.default
        let driveC = prefix.appendingPathComponent("drive_c").standardizedFileURL
        for item in installs {
            let src = packageRoot.appendingPathComponent(item.source)
            guard fm.fileExists(atPath: src.path) else { throw LayerError.sourceMissing(item.source) }
            let destDir = driveC.appendingPathComponent(item.destination).standardizedFileURL
            guard destDir.path.hasPrefix(driveC.path + "/") else { throw LayerError.escapesBottle(item.destination) }
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            var isDir: ObjCBool = false
            fm.fileExists(atPath: src.path, isDirectory: &isDir)
            let files = isDir.boolValue ? try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) : [src]
            for f in files where f.pathExtension.lowercased() == "dll" {
                let dst = destDir.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: f, to: dst)
            }
        }
        return (layer.dllOverrides ?? []).joined(separator: ";")
    }
}
