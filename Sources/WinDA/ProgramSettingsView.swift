import SwiftUI
import WinDACore

/// Per-program options: graphics engine, extra launch arguments, environment, keyboard.
struct ProgramSettingsView: View {
    @Bindable var model: AppModel
    let recipe: Recipe
    @State private var graphics: GraphicsEngine?
    @State private var arguments: String
    @State private var environment: String
    @State private var commandIsCtrl: Bool
    @State private var error: String?

    init(model: AppModel, recipe: Recipe) {
        self.model = model
        self.recipe = recipe
        let s = model.settings(for: recipe)
        _graphics = State(initialValue: s.graphics)
        _arguments = State(initialValue: s.extraArguments.joined(separator: " "))
        _environment = State(initialValue: s.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _commandIsCtrl = State(initialValue: s.commandIsCtrl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(recipe.name) settings").font(.title2.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("Graphics").font(.headline)
                Picker("Graphics", selection: $graphics) {
                    Text("Recipe default (\(recipe.engine.graphics.rawValue))").tag(GraphicsEngine?.none)
                    ForEach(model.availableGraphics, id: \.self) { g in
                        Text(g == .d3dmetal ? "D3DMetal (Apple)" : "DXVK (Vulkan)").tag(GraphicsEngine?.some(g))
                    }
                }
                .labelsHidden()
                Text("D3DMetal handles DirectX 11 and 12 on the GPU directly and is usually the faster choice. "
                     + "Switching keeps your installed games and logins. It only changes which Wine build runs them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Extra launch arguments").font(.headline)
                TextField("e.g. -windowed", text: $arguments).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Environment variables").font(.headline)
                TextEditor(text: $environment).font(.system(.body, design: .monospaced)).frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("One KEY=value per line, for example D3DM_SUPPORT_DXR=1.").font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Use the Command key like Ctrl (Cmd+C, Cmd+V)", isOn: $commandIsCtrl)

            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { model.editingSettings = nil }
                Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
            Text("Changes apply the next time you press Open.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        let s = ProgramSettings(graphics: graphics,
                                extraArguments: arguments.split(whereSeparator: \.isWhitespace).map(String.init),
                                environment: ProgramSettings.parseEnvironment(environment),
                                commandIsCtrl: commandIsCtrl)
        if let e = model.saveSettings(s, for: recipe) { error = e } else { model.editingSettings = nil }
    }
}
