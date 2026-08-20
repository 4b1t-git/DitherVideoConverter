import AVFoundation
import Foundation
import os
import SwiftUI

/// `Sources/App/UIState` lifecycle state machine (task 4.6). Owns the import → validation →
/// playback → export → cancel lifecycle and the disclosure/error surface for the UI. The preview
/// overlay stays on `PreviewState`; export lives on `ExportSession`. Signposts via `Logger` and
/// `OSSignposter` (os.signpost). The live `AVPlayer`/`AVPlayerItemVideoOutput`/`CVDisplayLink`
/// loop stays deferred to a follow-up live-preview slice; this coordinator is the deterministic
/// state surface that the Unit 8 lifecycle tests (and the App) drive.
enum LifecyclePhase: Sendable, Equatable {
    case empty, importing, ready, playing, unsupported, exporting, exported, cancelled, failed
}

@MainActor
final class LifecycleCoordinator: ObservableObject {
    @Published private(set) var phase: LifecyclePhase = .empty
    @Published private(set) var validation: AssetValidationReport?
    @Published private(set) var exportProgress: ExportProgress?
    @Published private(set) var preflightDisclosure: String?
    @Published private(set) var completionDisclosure: String?
    @Published private(set) var lastError: String?
    let previewState = PreviewState()
    private let renderer: MetalFrameRenderer
    private let exportSettings: ExportSettings
    private var exportSession: ExportSession?
    private let log = Logger(subsystem: "com.gentleai.AnciiVideoGenerator", category: "lifecycle")
    private let signposter = OSSignposter(subsystem: "com.gentleai.AnciiVideoGenerator", category: "lifecycle-export")

    init(renderer: MetalFrameRenderer = MetalFrameRenderer(), settings: ExportSettings = LifecycleCoordinator.defaultSettings) {
        self.renderer = renderer; self.exportSettings = settings
    }

    /// Default export settings (a 2-color bayer palette at scale 1). Constructed once; throws are
    /// known-good so `try!` is safe.
    static let defaultSettings: ExportSettings = {
        let palette = try! Palette(colors: [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 255, g: 255, b: 255)])
        let render = try! RenderSettings(style: .dither(.bayer), palette: palette)
        return try! ExportSettings(render: render, scale: 1.0)
    }()

    /// Processing is enabled only after a supported import and never during an active export.
    var exportEnabled: Bool { validation?.isSupported == true && phase != .exporting }

    func importAsset(_ asset: AVAsset, maximumDimension: Int = 4_096) async {
        phase = .importing; previewState.setImporting()
        let s = signposter.beginInterval("import")
        let report = await AssetValidator.validate(asset, maximumDimension: maximumDimension)
        validation = report
        if report.isSupported {
            phase = .ready; previewState.setReady(timestamp: 0)
        } else {
            phase = .unsupported; previewState.setUnsupported(report.violation?.errorDescription ?? report.summary)
        }
        preflightDisclosure = report.summary
        log.info("import supported=\(report.isSupported) summary=\(report.summary)")
        signposter.endInterval("import", s)
    }

    func play(at timestamp: Double) { phase = .playing; previewState.play(at: timestamp) }
    func scrub(to timestamp: Double) { phase = .playing; previewState.scrub(to: timestamp) }

    /// Drives `ExportSession.export`, surfacing progress + disclosures; never re-throws (UI owns
    /// the lifecycle surface). Cancellation/failure delete partial output (ExportSession owns it)
    /// and the source is never touched (preservation is structural).
    func export(sources: [ExportSource], audio: ExportAudioMode, outputURL: URL) async {
        guard exportEnabled, !sources.isEmpty else {
            phase = .failed; lastError = ExportError.noFrames.errorDescription; return
        }
        phase = .exporting
        exportProgress = ExportProgress(stage: .rendering, fractionCompleted: 0)
        preflightDisclosure = audioDisclosure(audio, stage: .preflight)
        let session = ExportSession(renderer: renderer, settings: exportSettings)
        exportSession = session
        let s = signposter.beginInterval("export")
        do {
            _ = try await session.export(sources: sources, audio: audio, outputURL: outputURL)
            exportProgress = await session.currentProgress()
            phase = .exported
            completionDisclosure = audioDisclosure(audio, stage: .completion)
            log.info("export completed frames=\(sources.count)")
        } catch let ExportError.cancelled {
            exportProgress = await session.currentProgress()
            phase = .cancelled
            lastError = ExportError.cancelled.errorDescription
            log.notice("export cancelled; partial output deleted by ExportSession")
        } catch {
            exportProgress = await session.currentProgress()
            phase = .failed
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            log.error("export failed: \(self.lastError ?? "")")
        }
        signposter.endInterval("export", s)
    }

    func cancelExport() async { await exportSession?.cancel() }

    /// Audio policy disclosure mirroring `AudioPolicyDecision.disclosure`; the modes are honest
    /// for `.none` (audio-less, the only mode ExportSession writes today). Passthrough/AAC modes
    /// disclose the intent; wiring the audio `AVAssetWriterInput` is Deviation #3 (deferred).
    private func audioDisclosure(_ mode: ExportAudioMode, stage: AudioDisclosureStage) -> String {
        switch (mode, stage) {
        case (.none, .preflight): return "No audio will be exported."
        case (.none, .completion): return "Export completed without audio."
        case (.passthrough, .preflight): return "Compatible source audio will use verified .mov passthrough."
        case (.passthrough, .completion): return "Export completed with verified audio passthrough."
        case (.aacFallback, .preflight): return "AAC fallback will preserve timing when supported; output is not bit-identical."
        case (.aacFallback, .completion): return "Export completed with disclosed AAC fallback; output is not bit-identical."
        }
    }
}