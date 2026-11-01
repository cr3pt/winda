import SwiftUI
import WinDACore

@main
struct WinDAApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("WinDA") {
            ContentView(model: model)
                .task { await autoRunIfRequested() }
        }
        .windowResizability(.contentMinSize)
    }

    /// Test hook: `WINDA_AUTOLOAD_EXE` selects a file; `WINDA_AUTORUN=1` also runs it.
    private func autoRunIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["WINDA_AUTOLOAD_EXE"] else { return }
        model.select(URL(fileURLWithPath: path))
        if env["WINDA_AUTORUN"] == "1" { await model.run() }
    }
}
