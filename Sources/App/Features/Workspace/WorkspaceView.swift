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
    /// The palette catalogue. Read from `PaletteCatalog.shared`, which decodes the resource once
    /// per process: a stored-property initialiser here would run on every `init`, and SwiftUI
    /// re-initialises this struct every time the App's `body` re-evaluates — i.e. on every
    /// published coordinator change, which during a scrub is once per frame.
    private var palettes: [NamedPalette] { PaletteCatalog.shared }

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(state: previewState, snapshot: coordinator.previewSnapshot,
                        settings: previewSettings)
            frameNavigator
            settingsPanel
            controls
            status
        }
    }

    /// The settings the snapshot on screen is painted with.
    ///
    /// This reads the coordinator's LIVE settings, not `LifecycleCoordinator.defaultSettings`. It
    /// used to read the defaults, which meant the renderer's byte was interpreted with a palette
    /// and background the user may never have chosen: every control in `settingsPanel` would have
    /// changed the render and left the picture on screen unchanged. Named rather than inlined so
    /// the value `body` hands to `PreviewView` has somewhere a test can read it.
    var previewSettings: RenderSettings { coordinator.renderSettings }

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

    /// The render controls the `bitmap-ascii-rendering` spec requires the app to OFFER: the four
    /// dither modes and both bundled glyph sets, the three backgrounds, the bundled palettes, the
    /// ASCII cell size, tone mapping, and the export-only scale.
    ///
    /// The whole panel is disabled while an export is in flight. A settings change cannot reach a
    /// file that is already being written, so leaving the controls live would let the user believe
    /// they had changed the output of the write they are watching.
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Picker("Style", selection: styleSelection) {
                    ForEach(RenderStyleOption.allCases, id: \.self) { Text($0.description).tag($0) }
                }
                Picker("Background", selection: backgroundSelection) {
                    ForEach(RenderBackground.allCases, id: \.self) { Text($0.description).tag($0) }
                }
                Picker("Palette", selection: paletteSelection) {
                    ForEach(palettes.indices, id: \.self) { Text(palettes[$0].name).tag($0) }
                }
            }
            HStack(spacing: 12) {
                // Disabled rather than hidden: cell size is the ASCII inverse-density block and
                // means nothing to a dither mode, but removing the control would shuffle every
                // other one sideways each time the style changed.
                Stepper("Cell size: \(coordinator.renderSettings.cellSize)", value: cellSizeSelection, in: 1...16)
                    .disabled(!RenderStyleOption(coordinator.renderSettings.style).usesCellSize)
                Toggle("Tone map", isOn: toneMapSelection)
                Spacer()
            }
            HStack(spacing: 8) {
                Text(String(format: "Export scale: %.0f%%", coordinator.exportScale * 100)).monospacedDigit()
                Slider(value: exportScaleSelection, in: 0.1...1.0).frame(maxWidth: 160)
                Text("Written file only; the preview keeps its own bounded size.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.top, 6)
        .disabled(coordinator.isExporting)
    }

    /// Every control above derives its value FROM `coordinator.renderSettings` and writes the whole
    /// settings value back through `coordinator.updateRenderSettings`. There is deliberately NO
    /// `@State` mirror of style/palette/background/cell size/tone map here.
    ///
    /// The coordinator owns those settings precisely because the spec requires preview, still, and
    /// export to share ONE configuration. A view-owned copy re-creates the divergence that design
    /// exists to prevent: the panel would keep showing whatever the user last touched while the
    /// export wrote something else, and — since a mirror only re-syncs when the view chooses to —
    /// nothing on screen would say which of the two was real. Deriving is also what makes a
    /// settings change from anywhere else (a future preset, a menu command) show up here at all.
    private var styleSelection: Binding<RenderStyleOption> {
        Binding(get: { RenderStyleOption(self.coordinator.renderSettings.style) },
                set: { self.apply(style: $0) })
    }

    private var backgroundSelection: Binding<RenderBackground> {
        Binding(get: { self.coordinator.renderSettings.background },
                set: { self.apply(background: $0) })
    }

    /// Selected by INDEX into the catalogue, matched by comparing the live `Palette` against each
    /// entry's own. `Palette` is `Equatable` by colours and carries no name, so there is nothing
    /// else to match on — and a palette that is not in the catalogue at all (a custom one) has no
    /// row to select. That case falls back to the first entry rather than to no selection, because
    /// SwiftUI renders an out-of-range tag as a blank control, which would read as "no palette" for
    /// a configuration that certainly has one. The fallback is display-only: it selects a row, it
    /// does NOT write that palette back, so a custom palette survives until the user picks another.
    private var paletteSelection: Binding<Int> {
        Binding(get: {
            self.palettes.firstIndex { $0.palette == self.coordinator.renderSettings.palette } ?? 0
        }, set: { index in
            guard self.palettes.indices.contains(index) else { return }
            self.apply(palette: self.palettes[index].palette)
        })
    }

    private var cellSizeSelection: Binding<Int> {
        Binding(get: { self.coordinator.renderSettings.cellSize },
                set: { self.apply(cellSize: $0) })
    }

    private var toneMapSelection: Binding<Bool> {
        Binding(get: { self.coordinator.renderSettings.toneMap },
                set: { self.apply(toneMap: $0) })
    }

    /// The one control that does NOT go through `RenderSettings`: export scale is not a render
    /// setting, it is how much of the source resolution the WRITE keeps, and the coordinator
    /// clamps it into `(0, 1]` on the way in.
    private var exportScaleSelection: Binding<Double> {
        Binding(get: { self.coordinator.exportScale },
                set: { self.coordinator.updateExportScale($0) })
    }

    /// Rebuilds the whole settings value from the coordinator's current one with a single field
    /// replaced, then adopts it. Every control routes through here, so assembling settings happens
    /// in exactly one place (`RenderSettings.make`) and the five controls cannot drift apart.
    ///
    /// The `Task` is what bridges a synchronous `Binding` setter to the coordinator's `async`
    /// adoption; `updateRenderSettings` repaints through the same scrub token as everything else,
    /// so a settings change that races a scrub is resolved by the existing coalescing rule rather
    /// than by a second render path.
    private func apply(style: RenderStyleOption? = nil, palette: Palette? = nil,
                       background: RenderBackground? = nil, cellSize: Int? = nil,
                       toneMap: Bool? = nil) {
        let current = coordinator.renderSettings
        let settings = RenderSettings.make(style: style ?? RenderStyleOption(current.style),
                                           palette: palette ?? current.palette,
                                           background: background ?? current.background,
                                           cellSize: cellSize ?? current.cellSize,
                                           toneMap: toneMap ?? current.toneMap)
        Task { await coordinator.updateRenderSettings(settings) }
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
