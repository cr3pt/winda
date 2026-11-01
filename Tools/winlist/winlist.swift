// Lists macOS windows owned by Wine/Steam/Paradox processes: owner, size, position, on-screen flag and layer.
// Window metadata does not need the Screen Recording permission. usage: swiftc -o winlist winlist.swift && ./winlist
import CoreGraphics
import Foundation

var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)
print("displays:", ids.map { d -> String in let b = CGDisplayBounds(d); return "(\(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height)))" }.joined(separator: " "))

let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    guard ["wine", "paradox", "steam"].contains(where: { owner.lowercased().contains($0) }) else { continue }
    let b = (w[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
    let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    print("\(owner) | \((w[kCGWindowName as String] as? String) ?? "") | layer \(w[kCGWindowLayer as String] ?? "?") | onscreen \(on) | alpha \(w[kCGWindowAlpha as String] ?? "?") | (\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)))")
}
