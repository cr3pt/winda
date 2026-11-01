import SwiftUI
import UniformTypeIdentifiers
import WinDACore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var targeted = false
    @State private var showEngines = false
    @State private var importingGPTK = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { model.showSetup = true } label: { Label("Locations", systemImage: "gearshape") }
                    .buttonStyle(.borderless)
            }
            programsSection
            dropZone
            if model.selected != nil { programCard }
            if let n = model.notice {
                Text(n).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.output.isEmpty || model.status != .idle { logView }
            engines
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data]) { r in
            if case .success(let url) = r { model.select(url) }
        }
        .fileImporter(isPresented: $importingGPTK, allowedContentTypes: [UTType(filenameExtension: "dmg") ?? .data]) { r in
            if case .success(let url) = r { Task { await model.inspectGPTK(url) } }
        }
        .sheet(isPresented: $model.showSetup) { SetupView(model: model) }
        .sheet(item: $model.pendingInstall) { r in installSheet(r) }
        .sheet(item: $model.editingSettings) { r in ProgramSettingsView(model: model, recipe: r) }
        .sheet(item: $model.pendingLicense) { m in licenseSheet(m) }
        .sheet(item: $model.pendingGPTK) { p in gptkSheet(p) }
    }

    @ViewBuilder private var programsSection: some View {
        if !model.programs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Programs").font(.headline)
                ForEach(model.programs, id: \.id) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.name).font(.body.bold())
                            Text(model.isPrepared(r) ? "Installed" : "Not installed").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.busyPrograms.contains(r.id) {
                            ProgressView().controlSize(.small)
                            Text("Working…").font(.caption).foregroundStyle(.secondary)
                        } else if model.isPrepared(r) {
                            Button { model.editingSettings = r } label: { Image(systemName: "slider.horizontal.3") }
                                .help("Settings for \(r.name)").buttonStyle(.borderless)
                            if model.runningPrograms.contains(r.id) {
                                Button("Stop") { model.stopProgram(r) }
                            } else {
                                Button("Open") { Task { await model.openProgram(r) } }.buttonStyle(.borderedProminent)
                            }
                        } else {
                            Button("Install…") { model.pendingInstall = r }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
        }
    }

    private func installSheet(_ r: Recipe) -> some View {
        let dir = model.installLocation(r)
        let check = LocationCheck.preview(dir)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Install \(r.name)").font(.title3.bold())
            Text("WinDA will download it and install it in a private Windows environment here:")
            Text(dir.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            if let free = check.freeBytes {
                Label(ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free on this volume",
                      systemImage: check.lowSpace ? "exclamationmark.triangle" : "internaldrive")
                    .foregroundStyle(check.lowSpace ? Color.orange : Color.secondary)
            }
            Text("You sign in to \(r.name) yourself the first time you open it. WinDA never sees your password.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Change location…") { model.pendingInstall = nil; model.showSetup = true }
                Spacer()
                Button("Cancel") { model.pendingInstall = nil }
                Button("Install") {
                    model.pendingInstall = nil
                    Task { await model.installProgram(r) }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 520)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Drop a Windows program here").font(.headline)
            Button("Choose a file…") { importing = true }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            model.select(u)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityLabel("Drop a Windows program here")
    }

    private var programCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selected?.lastPathComponent ?? "").font(.title3.bold())
                    if let r = model.recipe { Text(model.isTested ? r.name : "Not tested").foregroundStyle(.secondary) }
                }
                Spacer()
                if let r = model.recipe, model.isTested { ratingBadge(r.rating) }
            }
            if !model.isTested {
                Label("No recipe matches this program. WinDA will try its defaults and it may not work.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if model.recipe?.rating == .incompatibleAntiCheat {
                Label("This game uses kernel anti-cheat and does not work. Online play may get you banned.", systemImage: "xmark.octagon")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button { Task { await model.run() } } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.status == .running || model.recipe?.rating == .incompatibleAntiCheat)
                Button { model.createShortcut() } label: { Label("Create shortcut", systemImage: "square.and.arrow.down") }
                if model.status == .running { ProgressView().controlSize(.small) }
                statusText
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
    }

    @ViewBuilder private var statusText: some View {
        switch model.status {
        case .idle, .running: EmptyView()
        case .finished(let code):
            Text(code == 0 ? "Finished" : "Exited with code \(code)").foregroundStyle(code == 0 ? Color.secondary : Color.red)
        case .failed(let msg): Text(msg).foregroundStyle(.red).lineLimit(3)
        }
    }

    private func ratingBadge(_ r: Rating) -> some View {
        let (text, color): (String, Color) = switch r {
        case .platinum: ("Platinum", .teal)
        case .gold: ("Gold", .yellow)
        case .silver: ("Silver", .gray)
        case .bronze: ("Bronze", .brown)
        case .broken: ("Broken", .red)
        case .incompatibleAntiCheat: ("Anti-cheat", .red)
        }
        return Text(text).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.25))).foregroundStyle(color == .yellow ? .primary : color)
    }

    private var logView: some View {
        ScrollView {
            Text(model.output.isEmpty ? " " : model.output)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .frame(minHeight: 70, maxHeight: 140)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }

    private var engines: some View {
        DisclosureGroup("Engines", isExpanded: $showEngines) {
            VStack(alignment: .leading, spacing: 8) {
                if model.manifests.isEmpty { Text("No engine manifests found in \(model.paths.manifests.path).").foregroundStyle(.secondary) }
                ForEach(model.manifests, id: \.id) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text(m.provides.map(\.rawValue).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isInstalled(m) {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if model.installing.contains(m.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Install") { Task { await model.install(m, licenseAccepted: false) } }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("D3DMetal from Apple").font(.callout)
                    Spacer()
                    if model.importing { ProgressView().controlSize(.small) }
                    Button("Import GPTK…") { importingGPTK = true }.disabled(model.importing)
                }
                Text("Download Game Porting Toolkit from Apple, then choose the .dmg here. WinDA does not include it.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gptkSheet(_ p: AppModel.PendingGPTK) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Game Porting Toolkit \(p.info.version)").font(.title3.bold())
            Text("Read Apple's license. It restricts use and non-commercial distribution of this software.")
            ScrollView {
                Text(p.info.licenseText.isEmpty ? "The license text could not be read from the image." : p.info.licenseText)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { model.pendingGPTK = nil }
                Button("I accept the license and import") {
                    model.pendingGPTK = nil
                    Task { await model.importGPTK(p) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(p.info.licenseText.isEmpty)
            }
        }.padding(20).frame(width: 560)
    }

    private func licenseSheet(_ m: EngineManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("License required").font(.title3.bold())
            Text("\(m.name) is distributed under:")
            Text(m.license?.name ?? "").bold()
            if let url = m.license?.url { Link("Read the license", destination: url) }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingLicense = nil }
                Button("I accept") {
                    model.pendingLicense = nil
                    Task { await model.install(m, licenseAccepted: true) }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 420)
    }
}

extension EngineManifest: Identifiable {}

extension Recipe: Identifiable {}
