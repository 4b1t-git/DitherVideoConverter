import SwiftUI

/// The single routing seam between the modal file panels and the lifecycle coordinator.
///
/// Both the window's buttons and the App's menu commands go through these two routines, so a
/// keyboard shortcut and its on-screen button can never drift apart — there is only one description
/// of "open" and one of "export" in the whole app.
///
/// A cancelled panel (`nil` URL) is an ordinary outcome and does exactly nothing: no error, no
/// phase change. Surfacing "you cancelled" as a failure would put an unactionable message in the
/// same place real correction messages live.
@MainActor
enum WorkspaceActions {
    /// Fallback name offered by the save panel. `ExportSession` writes QuickTime, hence `.mov`.
    static let defaultExportName = "ancii-export.mov"

    static func open(into coordinator: LifecycleCoordinator) async {
        guard let url = FileDialogs.chooseMovie() else { return }
        await coordinator.openAsset(url: url)
    }

    static func export(from coordinator: LifecycleCoordinator) async {
        guard let url = FileDialogs.chooseExportDestination(defaultName: defaultExportName) else { return }
        await coordinator.exportToFile(url: url)
    }
}

/// The app's only window content: preview, frame navigation, the import/export/cancel controls, and
/// the lifecycle status surface. Everything here is a thin projection of `LifecycleCoordinator` —
/// the view owns exactly one piece of state (the slider position), because that is the only value
/// the coordinator has no opinion about until the user moves it.
struct WorkspaceView: View {
    @ObservedObject var coordinator: LifecycleCoordinator
    /// Observed EXPLICITLY rather than reached through `coordinator`. `PreviewState` is its own
    /// `ObservableObject`, so the coordinator's `objectWillChange` says nothing about a timestamp
    /// bump. Every path that moves the timestamp today ALSO touches a published coordinator
    /// property, which makes the frame label below correct by accident; observing the object the
    /// label actually reads makes it correct by construction, and keeps a future path that only
    /// touches `PreviewState` from silently freezing the label.
    @ObservedObject var previewState: PreviewState
    /// Slider position, in frames. `Double` because `Slider` is `BinaryFloatingPoint`-bound; it is
    /// stepped by 1 and only ever read back through `Int(...)`.
    @State private var frameIndex: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(state: previewState, snapshot: coordinator.previewSnapshot)
            frameNavigator
            controls
            status
        }
    }

    private var frameNavigator: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(frameLabel).font(.caption).monospacedDigit()
            Slider(value: $frameIndex, in: 0...sliderUpperBound, step: 1)
                .disabled(coordinator.importedFrameCount <= 1)
                .onChange(of: frameIndex) { _, newValue in
                    Task { await coordinator.showFrame(at: Int(newValue)) }
                }
        }
        .padding(.horizontal, 8)
        // A shorter clip must never leave the slider pointing past its end, which would show a
        // frame number the import cannot render. Rewinding to 0 on every new import is honest:
        // a fresh import already displays frame 0 (`importAsset` renders it).
        .onChange(of: coordinator.importedFrameCount) { _, _ in frameIndex = 0 }
    }

    /// The slider's range never collapses to `0...0`: a zero-width range gives `Slider` a division
    /// by zero when it maps the value onto the track. With 0 or 1 frames the control is disabled
    /// anyway, so the unreachable upper bound is harmless.
    private var sliderUpperBound: Double { Double(max(coordinator.importedFrameCount - 1, 1)) }

    private var frameLabel: String {
        guard coordinator.importedFrameCount > 0 else { return "No frames" }
        return String(format: "Frame %d / %d — %.2f s", Int(frameIndex) + 1,
                      coordinator.importedFrameCount, previewState.currentTimestamp)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Open…") { Task { await WorkspaceActions.open(into: coordinator) } }
                .disabled(coordinator.isExporting)
            Button("Export…") { Task { await WorkspaceActions.export(from: coordinator) } }
                .disabled(!coordinator.exportReady)
            // Cancel exists only while there is something to cancel; a permanently disabled Cancel
            // would suggest the app can stop work it is not doing.
            if coordinator.isExporting {
                Button("Cancel") { Task { await coordinator.cancelExport() } }
            }
            Spacer()
        }
        .padding(8)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let preflight = coordinator.preflightDisclosure { Text(preflight).font(.caption) }
            // The audio verdict belongs here at IMPORT time, not only after a write completes:
            // "this export will be silent" is something the user must be able to read before
            // choosing a destination, while they can still pick a different source.
            if let audio = coordinator.importedAudioDisclosure { Text(audio).font(.caption) }
            if let completion = coordinator.completionDisclosure { Text(completion).font(.caption) }
            if let progress = coordinator.exportProgress {
                ProgressView(value: progress.fractionCompleted).progressViewStyle(.linear)
            }
            if let err = coordinator.lastError { Text(err).font(.caption).foregroundStyle(.red) }
            Text("Phase: \(String(describing: coordinator.phase)) — \(coordinator.importedFrameCount) frames")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
