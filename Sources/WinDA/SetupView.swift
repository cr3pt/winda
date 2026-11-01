import SwiftUI
import UniformTypeIdentifiers
import WinDACore

/// Asks where WinDA keeps its files. Shown on first launch and from Settings.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var home: String
    @State private var bottles: String
    @State private var engines: String
    @State private var apps: String
    @State private var choosing: Field?
    @State private var error: String?

    enum Field: String, Identifiable {
        case home, bottles, engines, apps
        var id: String { rawValue }
    }

    init(model: AppModel) {
        self.model = model
        let p = model.paths
        _home = State(initialValue: p.home.path)
        _bottles = State(initialValue: p.bottles.path)
        _engines = State(initialValue: p.engines.path)
        _apps = State(initialValue: p.apps.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.needsSetup ? "Where should WinDA keep its files?" : "Locations").font(.title2.bold())
            Text("Windows programs take a lot of space. A game library can be tens of gigabytes, so choose a volume with room to spare.")
                .foregroundStyle(.secondary)
            row("Windows programs", "Each program or launcher (Steam, games) is installed here.", .bottles, $bottles, recommended: true)
            row("Engines and downloads", "Wine, graphics layers and the download cache.", .engines, $engines)
            row("Shortcuts", "Apps you create for Launchpad and the Dock.", .apps, $apps)
            row("WinDA data", "Recipes, engine manifests and logs.", .home, $home)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            HStack {
                Button("Use defaults") { reset() }
                Spacer()
                if !model.needsSetup { Button("Cancel") { model.showSetup = false } }
                Button(model.needsSetup ? "Continue" : "Save") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 600)
        .interactiveDismissDisabled(model.needsSetup)
        .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                      allowedContentTypes: [.folder]) { r in
            guard case .success(let url) = r, let f = choosing else { return }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            switch f {
            case .home: home = url.path
            case .bottles: bottles = url.appendingPathComponent("WinDA").path
            case .engines: engines = url.appendingPathComponent("WinDA Engines").path
            case .apps: apps = url.path
            }
        }
    }

    private func row(_ title: String, _ detail: String, _ field: Field, _ value: Binding<String>, recommended: Bool = false) -> some View {
        let check = LocationCheck.preview(URL(fileURLWithPath: value.wrappedValue))
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Folder", text: value).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button("Choose…") { choosing = field }
            }
            if !check.writable {
                Label("This folder is not writable.", systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
            } else if let free = check.freeBytes {
                let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
                Label(check.lowSpace && recommended ? "\(text). Less than 20 GB is tight for games." : text,
                      systemImage: check.lowSpace && recommended ? "exclamationmark.triangle" : "internaldrive")
                    .font(.caption).foregroundStyle(check.lowSpace && recommended ? Color.orange : Color.secondary)
            }
        }
    }

    private func reset() {
        let d = WinDAPaths(home: WinDAPaths.defaultHome)
        home = d.home.path; bottles = d.bottles.path; engines = d.engines.path; apps = d.apps.path
    }

    private func save() {
        let h = URL(fileURLWithPath: home)
        // Folders that match the default for this home are stored as "follow home".
        func opt(_ value: String, _ name: String) -> String? {
            value == h.appendingPathComponent(name).path ? nil : value
        }
        let l = WinDALocations(home: home, bottles: opt(bottles, "bottles"), engines: opt(engines, "engines"), apps: opt(apps, "Apps"))
        error = model.saveLocations(l)
    }
}
