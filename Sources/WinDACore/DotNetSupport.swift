import Foundation

/// Makes .NET programs and installers work in a bottle whose Wine ships an unpacked Wine Mono.
/// Wine Mono's own installer writes the .NET install root into the registry; an unpacked runtime does not,
/// and then installers that ask "where is the framework?" (for example WiX custom actions) fail.
public enum DotNetSupport {
    static let key = #"HKLM\SOFTWARE\Microsoft\.NETFramework"#

    /// True once the bottle has a .NET install root recorded.
    public static func isConfigured(prefix: URL) -> Bool {
        let reg = prefix.appendingPathComponent("system.reg")
        guard let text = try? String(contentsOf: reg, encoding: .utf8) else { return false }
        return text.contains(#""InstallRoot"="C:\\windows\\Microsoft.NET\\Framework64\\""#)
    }

    /// Records the install root in both registry views and creates the folders it points at.
    public static func configure(runner: WineRunner) throws {
        let fm = FileManager.default
        for (dir, view) in [("Framework64", "64"), ("Framework", "32")] {
            _ = try runner.run(["reg", "add", key, "/v", "InstallRoot", "/t", "REG_SZ",
                                "/d", "C:\\windows\\Microsoft.NET\\\(dir)\\", "/f", "/reg:\(view)"], timeout: 60)
            for version in ["v4.0.30319", "v2.0.50727"] {
                try fm.createDirectory(at: runner.prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/\(dir)/\(version)"),
                                       withIntermediateDirectories: true)
            }
        }
    }
}
