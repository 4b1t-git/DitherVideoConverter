import SwiftUI

@main
struct AnciiVideoGeneratorApp: App {
    @StateObject private var coordinator = LifecycleCoordinator()
    var body: some Scene {
        WindowGroup {
            WorkspaceView(coordinator: coordinator)
        }
        .commands {
            // The default "New" group is replaced rather than added to: this app has no document
            // model, so a New item would offer something that does not exist. Both items route
            // through `WorkspaceActions`, the same seam the window's buttons use, so the menu and
            // the buttons cannot drift apart.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Task { await WorkspaceActions.open(into: coordinator) } }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(coordinator.isExporting)
                Button("Export…") { Task { await WorkspaceActions.export(from: coordinator) } }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!coordinator.exportReady)
            }
        }
    }
}
