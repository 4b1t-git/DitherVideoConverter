import SwiftUI

@main
struct AnciiVideoGeneratorApp: App {
    @StateObject private var coordinator = LifecycleCoordinator()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                PreviewView(state: coordinator.previewState, snapshot: nil)
                VStack(alignment: .leading, spacing: 4) {
                    if let p = coordinator.preflightDisclosure { Text(p).font(.caption) }
                    if let progress = coordinator.exportProgress {
                        ProgressView(value: progress.fractionCompleted).progressViewStyle(.linear)
                    }
                    if let err = coordinator.lastError { Text(err).font(.caption).foregroundStyle(.red) }
                    Text("Phase: \(String(describing: coordinator.phase))").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}