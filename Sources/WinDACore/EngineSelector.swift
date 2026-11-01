import Foundation

public enum SelectionError: Error, Equatable {
    case noEngine(requested: String)
}

public struct EngineChoice: Equatable, Sendable {
    public var wine: EngineManifest
    public var layer: EngineManifest?
    public var graphics: GraphicsEngine
}

/// Turns a recipe's graphics preference into concrete installed packages.
public enum EngineSelector {
    /// - Parameters:
    ///   - wines/layers: only packages that are installed.
    /// `auto` prefers D3DMetal when a compatible Wine is installed, else DXVK.
    public static func select(_ requested: GraphicsEngine,
                              wines: [EngineManifest],
                              layers: [EngineManifest]) throws -> EngineChoice {
        let order: [GraphicsEngine] = requested == .auto ? [.d3dmetal, .dxvk] : [requested]
        for g in order {
            // Stable sort keeps manifest order among equal priorities.
            let ranked = wines.enumerated().sorted { ($0.element.priority ?? 0, -$0.offset) > ($1.element.priority ?? 0, -$1.offset) }.map(\.element)
            guard let wine = ranked.first(where: { $0.kind == .wine && ($0.compatibleGraphics ?? $0.provides).contains(g) })
            else { continue }
            switch g {
            case .dxvk:
                guard let layer = layers.first(where: { $0.kind == .graphicsLayer && $0.provides.contains(.dxvk) })
                else { continue }
                return EngineChoice(wine: wine, layer: layer, graphics: .dxvk)
            default:
                return EngineChoice(wine: wine, layer: nil, graphics: g)
            }
        }
        throw SelectionError.noEngine(requested: requested.rawValue)
    }
}
