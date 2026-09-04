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
    /// Real decoded frames from the last successful import (H4, `import-coordinator-wiring`).
    /// `internal` (not `private`) so `@testable import` can observe it; setter is closed. NOT
    /// `@Published`: the payload is a multi-megabyte pixel array and publishing it would push a
    /// full value diff through `objectWillChange` on every import. The UI only ever needs the
    /// count, which IS published below.
    internal private(set) var importedSources: [ExportSource]?
    @Published private(set) var importedFrameCount: Int = 0
    /// The source asset's audio track from the last successful import, already classified by
    /// `AudioPolicy` (Slice C, `import-audio-wiring`). `internal` (not `private`) so `@testable
    /// import` can observe it; setter is closed. NOT `@Published`, for the same reason as
    /// `importedSources`: it boxes an `AVAssetTrack` and an `AudioPolicyDecision`, and the UI has
    /// no use for either — it cannot draw a track. What the UI CAN show is published below.
    internal private(set) var importedAudio: AudioAttachment?
    /// The imported `AVAsset` itself, retained for exactly as long as `importedAudio` is.
    ///
    /// `AVAssetTrack.asset` is declared `@property (nonatomic, readonly, weak)` — a track does NOT
    /// keep its asset alive. `openAsset(url:)` builds its `AVURLAsset` as a temporary, so without
    /// this reference ARC would release the asset the moment `importAsset` returns, leaving
    /// `importedAudio.track.asset` nil and making `AudioPump` throw `writerRejected("audio track
    /// has no asset")` on the next export. An `AudioAttachment` is only valid while the asset its
    /// track came from is still alive, and this property is what makes that true.
    private var importedAsset: AVAsset?
    /// The import-time audio verdict as a user-facing sentence. `@Published` where the attachment
    /// is not, because this is the piece the UI can actually render — and it MUST be rendered at
    /// import time: the user has to know whether sound will survive BEFORE committing to a write,
    /// not after a silent file has already been written over a chosen destination.
    @Published private(set) var importedAudioDisclosure: String?
    @Published private(set) var exportProgress: ExportProgress?
    @Published private(set) var preflightDisclosure: String?
    @Published private(set) var completionDisclosure: String?
    @Published private(set) var lastError: String?
    /// The frame currently on screen. UNLIKE `importedSources` this one IS `@Published`: the
    /// preview render is bounded by `previewMaximumDimension`, so the published payload is at most
    /// ~240×240 bytes — small enough to diff through `objectWillChange` on every scrub, where the
    /// unbounded multi-megabyte source array is not.
    @Published private(set) var previewSnapshot: PreviewSnapshot?
    let previewState = PreviewState()
    private let renderer: MetalFrameRenderer
    private let exportSettings: ExportSettings
    /// Preview and export share the SOLE `MetalFrameRenderer` and the SAME `RenderSettings`; the
    /// preview differs only by `RenderRequest.scale` (R3-003). Constructing a second renderer here
    /// would break intent-invariance between what the user sees and what gets written.
    private let previewPipeline: PreviewPipeline
    /// Monotonic scrub token. `PreviewPipeline` coalesces on it, so a superseded frame request can
    /// never overwrite a newer one's result.
    private var scrubToken: UInt64 = 0
    private var exportSession: ExportSession?
    private let log = Logger(subsystem: "com.gentleai.AnciiVideoGenerator", category: "lifecycle")
    private let signposter = OSSignposter(subsystem: "com.gentleai.AnciiVideoGenerator", category: "lifecycle-export")

    /// `previewRenderer` is a TEST SEAM and nothing else: production passes `nil`, so preview and
    /// export share the sole `MetalFrameRenderer` (R3-003 intent-invariance). Tests substitute a
    /// gated `FrameRendering` double to interleave two concurrent `showFrame` calls around the
    /// renderer's suspension point, which is the only way to observe stale-result handling without
    /// sleeps or timing tolerances.
    init(renderer: MetalFrameRenderer = MetalFrameRenderer(),
         settings: ExportSettings = LifecycleCoordinator.defaultSettings,
         previewRenderer: (any FrameRendering)? = nil) {
        self.renderer = renderer; self.exportSettings = settings
        self.previewPipeline = PreviewPipeline(renderer: previewRenderer ?? renderer,
                                               settings: settings.render, previewScale: 1.0)
    }

    /// Longest side, in pixels, the preview render is allowed to produce. The preview is bounded
    /// (rather than rendered at source resolution and shrunk on screen) so both the render cost and
    /// the published `previewSnapshot` stay constant no matter how large the imported clip is.
    static let previewMaximumDimension = 240

    /// Preview scale for a source of the given size: shrink so the longest side lands on
    /// `previewMaximumDimension`, never upscale. Pure and total — a degenerate (zero or negative)
    /// source yields `1.0` rather than a division by zero, because `PreviewPipeline.makeRequest`
    /// throws `invalidDimensions` for anything outside `(0, 1]`.
    static func previewScale(sourceWidth: Int, sourceHeight: Int) -> Double {
        let longest = max(sourceWidth, sourceHeight)
        guard longest > 0 else { return 1.0 }
        return min(1.0, Double(previewMaximumDimension) / Double(longest))
    }

    /// Renders the imported frame at `index` into `previewSnapshot` and tracks its timestamp.
    ///
    /// An absent import or an out-of-range index is a programming no-op, NOT a user-visible
    /// failure: nothing is shown, nothing is cleared, and `lastError` stays untouched so the UI
    /// never reports an error the user cannot act on.
    func showFrame(at index: Int) async {
        guard let sources = importedSources, sources.indices.contains(index) else { return }
        let frame = sources[index]
        scrubToken &+= 1
        let token = scrubToken
        await previewPipeline.update(previewScale: LifecycleCoordinator.previewScale(
            sourceWidth: frame.sourceWidth, sourceHeight: frame.sourceHeight))
        do {
            let snapshot = try await previewPipeline.scrub(token: token, timestamp: frame.presentationTime,
                                                          source: frame.pixels,
                                                          sourceWidth: frame.sourceWidth,
                                                          sourceHeight: frame.sourceHeight)
            // A `nil` result means the pipeline coalesced this request away as stale — a NEWER
            // frame already won. BOTH visible writes are therefore gated on acceptance: assigning
            // `nil` would blank the screen behind that newer frame, and bumping the overlay
            // timestamp would label the newer frame with THIS frame's older time. A stale render
            // must leave every piece of visible state alone, not just the image.
            if let snapshot {
                previewSnapshot = snapshot
                previewState.scrub(to: frame.presentationTime)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            log.error("preview render failed: \(self.lastError ?? "")")
        }
    }

    /// Default export settings (a 2-color bayer palette at scale 1). Constructed once; throws are
    /// known-good so `try!` is safe.
    ///
    /// `background` MUST be `.postToneMapSDR` and MUST be passed explicitly. `RenderSettings`
    /// defaults it to `.blackOnWhite`, and per `MetalFrameRenderer.render`'s contract every
    /// background EXCEPT `.postToneMapSDR` returns a palette INDEX (0…N-1), not brightness.
    /// Nothing downstream maps an index back to a colour: `ExportSession` writes the byte straight
    /// into the luma plane and `PreviewSnapshot.makeGrayscaleImage` reads it straight as grey. With
    /// this 2-colour palette that made every rendered pixel 0 or 1 — a fully black preview and a
    /// fully black export, from any source. `.postToneMapSDR` returns the stylized brightness the
    /// dither actually produced ({0, 255} here), which is what a luma plane can carry.
    static let defaultSettings: ExportSettings = {
        let palette = try! Palette(colors: [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 255, g: 255, b: 255)])
        let render = try! RenderSettings(style: .dither(.bayer), palette: palette,
                                         background: .postToneMapSDR)
        return try! ExportSettings(render: render, scale: 1.0)
    }()

    /// Processing is enabled only after a supported import and never during an active export.
    var exportEnabled: Bool { validation?.isSupported == true && phase != .exporting }

    /// What the UI actually gates the export affordance on. `exportEnabled` is deliberately TRUE
    /// for a supported asset whose frame extraction failed — the asset genuinely IS supported, and
    /// D4b point 5 defers that consequence to the export itself. The UI cannot afford that
    /// deferral: offering an export that is guaranteed to fail with `noFrames` is not an offer, so
    /// the control also requires frames to actually exist.
    var exportReady: Bool { exportEnabled && importedFrameCount > 0 }

    /// True while a write is in flight. The UI disables the destructive controls (Open, Export) on
    /// it and shows Cancel in their place, so the same lifecycle phase drives both directions.
    var isExporting: Bool { phase == .exporting }

    /// Imports from a plain file `URL` — the single entry point the UI layer uses, so no view ever
    /// constructs an `AVAsset` itself and the whole import path stays reachable from a unit test
    /// that only has a URL.
    ///
    /// The `AVURLAsset` is built directly from the panel's URL with no security-scoped bookmark
    /// dance: this app is NOT sandboxed (`Config/Base.xcconfig` sets `CODE_SIGNING_ALLOWED = NO`,
    /// there is no entitlements file, and `ENABLE_APP_SANDBOX` is never set), so `NSOpenPanel`
    /// hands back a plainly readable URL. `startAccessingSecurityScopedResource` would be dead
    /// code here, and pretending otherwise would hide the day sandboxing IS turned on.
    func openAsset(url: URL, maximumDimension: Int = 4_096) async {
        await importAsset(AVURLAsset(url: url), maximumDimension: maximumDimension)
    }

    /// Exports the frames stored by the last import to `url` — the UI's export entry point.
    ///
    /// No `sources:` argument is passed ON PURPOSE: the parameter is `[ExportSource]?`, so an
    /// explicit `[]` would be `.some([])` and would defeat the stored-frame fallback, failing
    /// `noFrames` on a perfectly good import.
    ///
    /// The imported audio track (if the source had one) rides along as `audioSource`, so a UI
    /// export carries the clip's sound (#34) instead of writing a silent file. The `audio:`
    /// argument stays `.none` and is IGNORED for wiring on purpose: `export` derives both the
    /// wired `ExportAudioMode` and the disclosure from the attachment's own `AudioPolicyDecision`
    /// (H5), so passing the attachment is the whole wiring — a second, parallel path that also
    /// declared a mode here could only ever disagree with it.
    func exportToFile(url: URL) async {
        await export(audio: .none, audioSource: importedAudio, outputURL: url)
    }

    func importAsset(_ asset: AVAsset, maximumDimension: Int = 4_096) async {
        // Reset stored state FIRST so a failed or unsupported re-import can never leave a
        // previous import's frames reachable (D4b, "Stored state added to LifecycleCoordinator").
        // `previewSnapshot` resets with them: a failed or unsupported re-import MUST NOT leave the
        // previous clip's frame on screen.
        // `importedAudio`/`importedAudioDisclosure` reset with the frames and for the same
        // reason: an unsupported or audio-less re-import MUST NOT carry the previous clip's
        // sound into the next export.
        importedSources = nil; importedFrameCount = 0; previewSnapshot = nil
        importedAudio = nil; importedAudioDisclosure = nil; importedAsset = nil
        phase = .importing; previewState.setImporting()
        let s = signposter.beginInterval("import")
        let report = await AssetValidator.validate(asset, maximumDimension: maximumDimension)
        validation = report
        if report.isSupported {
            // Decode real frames while phase == .importing (honest: importing means validate +
            // decode). Extraction failure does NOT block exportEnabled (the asset genuinely IS
            // supported) — it only surfaces via lastError; the real consequence is deferred to
            // the next argument-less export, which will fail noFrames (D4b point 5).
            do {
                let sources = try await AssetFrameExtractor.extract(from: asset, maximumDimension: maximumDimension)
                importedSources = sources
                importedFrameCount = sources.count
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                log.error("import extraction failed: \(self.lastError ?? "")")
            }
            // Retain the source asset's audio track so the UI export is not silent (#34). The
            // `nil`-track case deliberately still runs through `AudioPolicy.decision`: routing
            // both the "no audio" and the "real audio" case through the SAME call keeps that one
            // function the single source of truth for the disclosure (the H5 invariant), so the
            // two can never drift apart.
            do {
                let track = try await asset.loadTracks(withMediaType: .audio).first
                let decision = try await AudioPolicy.decision(for: track)
                if let track {
                    importedAudio = AudioAttachment(decision: decision, track: track)
                    // Retain the asset, not just the track — see `importedAsset`.
                    importedAsset = asset
                }
                importedAudioDisclosure = decision.disclosure(at: .preflight)
            } catch {
                // A track that cannot be classified MUST NOT block the export. Refusing to write
                // a perfectly good video because its audio could not be read would cost the user
                // more than losing the audio does — so the error is surfaced, no attachment is
                // kept, and the disclosure falls back to the `.absent` decision (which never
                // throws) so the UI states plainly that the export will be silent.
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                log.error("import audio classification failed: \(self.lastError ?? "")")
                importedAudio = nil; importedAsset = nil
                importedAudioDisclosure = try? await AudioPolicy.decision(for: nil).disclosure(at: .preflight)
            }
            phase = .ready; previewState.setReady(timestamp: 0)
            // Put a real rendered frame on screen; a successful import that shows nothing would be
            // indistinguishable from a failed one. No-ops when extraction yielded nothing.
            await showFrame(at: 0)
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
    func export(sources: [ExportSource]? = nil, audio: ExportAudioMode, audioSource: AudioAttachment? = nil, outputURL: URL) async {
        // An explicit non-nil argument wins (including `[]`, used by tests to prove the
        // no-frames failure); `nil` (the default, and the only form production/UI code uses)
        // falls back to the stored frames from the last successful import (D4b point 3).
        let resolved = sources ?? importedSources ?? []
        guard exportEnabled, !resolved.isEmpty else {
            phase = .failed; lastError = ExportError.noFrames.errorDescription; return
        }
        phase = .exporting
        exportProgress = ExportProgress(stage: .rendering, fractionCompleted: 0)
        // Disclosure and the actually-wired `ExportAudioMode` BOTH derive from `audioSource`'s
        // own `AudioPolicyDecision` — never from the caller's requested `audio` argument (H5,
        // export-audio: "Audio disclosure MUST reflect the actually wired decision"). Routing a
        // `nil` track through the SAME `AudioPolicy.decision` call (rather than a bespoke
        // `.absent` literal) keeps this one code path the single source of truth for both the
        // "no audio" and "real audio" cases, so divergence between the two is structurally
        // impossible. A `nil` track never throws, so `try!` here is safe.
        let decision: AudioPolicyDecision
        if let audioSource { decision = audioSource.decision }
        else { decision = try! await AudioPolicy.decision(for: nil) }
        let wiredAudio = exportAudioMode(for: decision.mode)
        preflightDisclosure = decision.disclosure(at: .preflight)
        let session = ExportSession(renderer: renderer, settings: exportSettings)
        exportSession = session
        let s = signposter.beginInterval("export")
        do {
            _ = try await session.export(sources: resolved, audio: wiredAudio, audioSource: audioSource, outputURL: outputURL)
            exportProgress = await session.currentProgress()
            phase = .exported
            completionDisclosure = decision.disclosure(at: .completion)
            log.info("export completed frames=\(resolved.count)")
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

    /// Maps the actually-wired `AudioPolicyDecision.mode` onto the `ExportAudioMode` value
    /// `ExportSession.export` (and its `ExportResult.audioMode`) actually reports — the export
    /// result therefore always reflects the wired decision, never the requested mode (H5-080).
    private func exportAudioMode(for mode: AudioPolicyMode) -> ExportAudioMode {
        switch mode {
        case .absent: return .none
        case .passthrough: return .passthrough
        case .aacFallback: return .aacFallback
        }
    }
}