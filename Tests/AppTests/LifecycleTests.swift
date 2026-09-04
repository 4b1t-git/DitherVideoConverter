import AVFoundation
import XCTest
@testable import AnciiVideoGenerator

// Unit 8 — interactive-video-preview / timing-preserving-video-export lifecycle (task 4.5).
// Layer: Unit (XCTest). Integration/E2E layers are unavailable per
// testing-capabilities #39 (Integration ❌, E2E ❌), so the XCUI import/play/export/cancel
// scenarios degrade to unit-layer tests driving the `LifecycleCoordinator` state machine
// (`AssetValidator` → `PreviewState` → `ExportSession`) with the real `MediaFixtureFactory`,
// per strict-tdd.md "degrade gracefully".
@MainActor
final class LifecycleTests: XCTestCase {
    private let bw: [SRGBColor] = [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 255, g: 255, b: 255)]
    private var ramp: [UInt8] { (0..<(16 * 8)).map { UInt8(truncatingIfNeeded: $0 &* 15 &+ 5) } }

    // Spec "Navigation": importing a supported source surfaces the source timestamp + ready phase,
    // keeps the source unchanged (no resize), and enables processing (export).
    func testImportSupportedSourceNavigatesToReadySourceUnchangedAndEnablesExport() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let before = fileSize(fixture.videoURL)
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: fixture.videoURL))
        XCTAssertEqual(coordinator.phase, .ready, "Supported import MUST navigate to .ready (Navigation scenario)")
        let report = try XCTUnwrap(coordinator.validation, "Import MUST populate the validation report")
        XCTAssertTrue(report.isSupported, "HEVC fixture MUST validate as supported")
        XCTAssertTrue(report.sourceUnchanged, "Source MUST remain unchanged (MUST NOT be resized)")
        XCTAssertEqual(coordinator.previewState.phase, .ready, "Import MUST mirror to the preview overlay state")
        XCTAssertEqual(coordinator.exportEnabled, true, "Processing MUST be enabled for supported input (Unsupported scenario inverse)")
        XCTAssertEqual(fileSize(fixture.videoURL), before, "Source bytes MUST be byte-identical after import")
        XCTAssertNotNil(coordinator.preflightDisclosure, "Import MUST surface a preflight disclosure summary")
    }

    // Spec "Unsupported input": a streaming (non-file) source MUST keep processing disabled with an
    // actionable reason; no validation reads tracks over the network (the scheme check is early).
    func testImportUnsupportedStreamingSourceKeepsProcessingDisabledWithActionableReason() async {
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: URL(string: "https://example.invalid/clip.mov")!))
        XCTAssertEqual(coordinator.phase, .unsupported, "Streaming source MUST navigate to .unsupported")
        XCTAssertEqual(coordinator.exportEnabled, false, "Unsupported input MUST keep processing disabled")
        let report = coordinator.validation
        XCTAssertEqual(report?.violation, AssetValidationError.streaming, "Streaming source MUST report the streaming violation")
        XCTAssertFalse(report?.summary.isEmpty ?? true, "Unsupported input MUST surface an actionable reason")
    }

    // Spec "Navigation": playback and scrub reflect the source timestamp through the preview state.
    func testPlaybackAndScrubReflectSourceTimestamp() async throws {
        let coordinator = LifecycleCoordinator()
        coordinator.previewState.setReady(timestamp: 0)
        coordinator.play(at: 12.5)
        XCTAssertEqual(coordinator.previewState.currentTimestamp, 12.5, "Playback SHALL show the source timestamp")
        XCTAssertEqual(coordinator.phase, .playing)
        coordinator.scrub(to: 33.0)
        XCTAssertEqual(coordinator.previewState.currentTimestamp, 33.0, "Scrub SHALL update the source timestamp label")
    }

    // Spec "Safe lifecycle": export progress MUST be monotonic, reach 100% only at .completed,
    // leave the output file, and disclose audio policy after completion.
    func testExportProgressReachesOneOnlyAtCompletedAndDisclosesPolicy() async throws {
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: try MediaFixtureFactory().makeFixture().videoURL))
        await coordinator.export(sources: vfrSources(count: 6), audio: .none, outputURL: url)
        XCTAssertEqual(coordinator.phase, .exported, "Successful export MUST navigate to .exported")
        XCTAssertEqual(coordinator.exportProgress?.stage, .completed, "Progress stage MUST be .completed")
        XCTAssertEqual(coordinator.exportProgress?.fractionCompleted, 1.0, "Progress MUST reach 1.0 only at completion (monotonic)")
        XCTAssertLessThanOrEqual(coordinator.exportProgress?.fractionCompleted ?? -1, 1.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Completed export MUST leave the output file")
        // Preflight audio disclosure is set at the start of export(), before the writer runs:
        XCTAssertEqual(coordinator.preflightDisclosure, "No audio will be exported.", "Preflight MUST disclose the audio policy before export")
        XCTAssertEqual(coordinator.completionDisclosure, "Export completed without audio.", "Completion MUST disclose the audio policy after export")
        XCTAssertNil(coordinator.lastError, "Successful export MUST NOT surface an error")
    }

    // Spec "Safe lifecycle": cancellation mid-export MUST delete partial output and preserve the source.
    func testCancelMidExportDeletesPartialOutputAndPreservesSource() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let sourceBefore = fileSize(fixture.videoURL)
        let url = exportURL()
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: fixture.videoURL))
        // Cancel from a Task; mirrors Unit 7's proven 30-frame/5ms timing on the current M5 host (#106).
        Task { try? await Task.sleep(nanoseconds: 5_000_000); await coordinator.cancelExport() }
        await coordinator.export(sources: vfrSources(count: 30), audio: .none, outputURL: url)
        XCTAssertEqual(coordinator.phase, .cancelled, "Cancel mid-export MUST navigate to .cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Cancelled export MUST delete partial output")
        XCTAssertEqual(fileSize(fixture.videoURL), sourceBefore, "Source MUST be preserved (unchanged) through cancel")
        XCTAssertNotNil(coordinator.lastError, "Cancellation MUST surface a correction message")
    }

    // Spec "Safe lifecycle": a failing export (no frames) MUST surface a stage+correction error and delete partial output.
    func testFailingExportSurfacesActionableErrorAndDeletesPartial() async throws {
        let url = exportURL()
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: try MediaFixtureFactory().makeFixture().videoURL))
        await coordinator.export(sources: [], audio: .none, outputURL: url)
        XCTAssertEqual(coordinator.phase, .failed, "A no-frames export MUST navigate to .failed")
        XCTAssertFalse(coordinator.lastError?.isEmpty ?? true, "Failed export MUST name a stage + correction")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Failed export MUST delete partial output")
    }

    // H4 (import-coordinator-wiring): a real import followed by an argument-less export MUST use
    // the coordinator's stored extracted frames (no synthetic `sources:` argument supplied).
    func testImportThenExportRoundTripUsesStoredFrames() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: fixture.videoURL))
        XCTAssertEqual(coordinator.phase, .ready, "Import of a supported fixture MUST navigate to .ready before export")
        await coordinator.export(audio: .none, outputURL: url)
        XCTAssertEqual(coordinator.phase, .exported, "Round-trip export MUST navigate to .exported using stored frames")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Round-trip export MUST leave the output file")
        let frameCount = try readVideoFrameCount(url)
        XCTAssertEqual(frameCount, 4, "Round-trip export MUST commit exactly the 4 extracted fixture frames")
    }

    // H4: an argument-less export before any successful import MUST fail with `noFrames` (no
    // stored frames exist yet); the existing `testFailingExportSurfacesActionableErrorAndDeletesPartial`
    // (explicit `sources: []`) stays green unedited since `[]` is non-nil and never falls through.
    func testExportWithoutPriorImportFailsNoFrames() async {
        let url = exportURL()
        let coordinator = LifecycleCoordinator()
        await coordinator.export(audio: .none, outputURL: url)
        XCTAssertEqual(coordinator.phase, .failed, "Export without a prior import MUST fail (no stored frames)")
        XCTAssertEqual(coordinator.lastError, ExportError.noFrames.errorDescription,
                       "Failure MUST report the noFrames description")
    }

    // H4: a validated-supported asset whose frame extraction fails MUST NOT disable `exportEnabled`
    // (the asset genuinely IS supported); the failure is surfaced via `lastError` and stored frames
    // stay nil, deferring the observable consequence to the next argument-less export (D4b point 5).
    func testExtractionFailurePreservesExportEnabledAndSetsLastError() async throws {
        let (asset, urls) = try corruptedFixtureAsset()
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(asset)
        XCTAssertEqual(coordinator.phase, .ready, "A validated-supported asset MUST still navigate to .ready")
        XCTAssertEqual(coordinator.exportEnabled, true, "Extraction failure MUST NOT disable exportEnabled (asset IS supported)")
        XCTAssertNotNil(coordinator.lastError, "Extraction failure MUST surface a lastError")
        XCTAssertNil(coordinator.importedSources, "Extraction failure MUST leave stored sources nil")
    }

    // H5 (export-audio): disclosure MUST reflect the actually wired `AudioPolicyDecision`, never
    // the caller's requested `ExportAudioMode`. `.passthrough` is requested here on purpose while
    // the fixture's LPCM audio track genuinely resolves to `.aacFallback`.
    func testAudioDisclosureReflectsWiredDecisionNotRequestedMode() async throws {
        let fixture = try MediaFixtureFactory().makeCombinedFixture(audio: .lpcm)
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let audioAsset = AVURLAsset(url: fixture.audioURL)
        let audioTrackList = try await audioAsset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTrackList.first)
        let decision = try await AudioPolicy.decision(for: track)
        XCTAssertEqual(decision.mode, .aacFallback, "LPCM source MUST resolve to AAC fallback")
        let attachment = AudioAttachment(decision: decision, track: track)
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: fixture.videoURL))
        await coordinator.export(audio: .passthrough, audioSource: attachment, outputURL: url)
        XCTAssertEqual(coordinator.phase, .exported)
        XCTAssertEqual(coordinator.completionDisclosure, decision.disclosure(at: .completion),
                       "Disclosure MUST state the wired .aacFallback decision, not the requested .passthrough mode")
        XCTAssertTrue(coordinator.completionDisclosure?.contains("AAC fallback") ?? false,
                      "Wired .aacFallback disclosure text MUST be surfaced, not the requested passthrough text")
    }

    // R3-010 (Unit 6 carry-forward): `PreviewFrameView` `Equatable` MUST depend ONLY on the snapshot,
    // so a per-timestamp overlay bump does NOT repaint the O(W×H) frame canvas.
    func testPreviewFrameViewEqualityDependsOnlyOnSnapshot() async throws {
        let pipeline = PreviewPipeline(renderer: MetalFrameRenderer(), settings: try settings(), previewScale: 0.5)
        let s0 = try await pipeline.render(timestamp: 0, source: ramp, sourceWidth: 16, sourceHeight: 8)
        XCTAssertEqual(PreviewFrameView(snapshot: s0), PreviewFrameView(snapshot: s0), "Same snapshot MUST be equal (R3-010)")
        let s1 = try await pipeline.render(timestamp: 1, source: ramp, sourceWidth: 16, sourceHeight: 8)
        XCTAssertNotEqual(PreviewFrameView(snapshot: s0), PreviewFrameView(snapshot: s1), "A different snapshot MUST NOT be equal (R3-010)")
        XCTAssertEqual(PreviewFrameView(snapshot: nil), PreviewFrameView(snapshot: nil), "Empty frames MUST be equal (R3-010)")
    }

    // R3-011 (preview-render-wiring): the preview render is BOUNDED so the published snapshot and
    // the on-screen image stay cheap regardless of source size. The scale is a pure function, and
    // it MUST stay inside (0, 1] — `PreviewPipeline.makeRequest` throws on anything else.
    func testPreviewScaleBoundsSourceToMaximumDimension() {
        XCTAssertEqual(LifecycleCoordinator.previewScale(sourceWidth: 16, sourceHeight: 32), 1.0,
                       "A source already under the bound MUST render at full preview scale")
        let scale = LifecycleCoordinator.previewScale(sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertGreaterThan(scale, 0, "Preview scale MUST stay strictly positive")
        XCTAssertLessThanOrEqual(scale, 1.0, "Preview scale MUST never upscale")
        XCTAssertEqual(Int((1920.0 * scale).rounded()), LifecycleCoordinator.previewMaximumDimension,
                       "The longest side MUST land exactly on the preview bound")
        XCTAssertEqual(LifecycleCoordinator.previewScale(sourceWidth: 0, sourceHeight: 0), 1.0,
                       "A degenerate 0x0 source MUST NOT divide by zero (never 0, never infinity)")
    }

    // A successful import MUST actually put a rendered frame on screen, and that frame MUST be a
    // bounded `.preview` render — not a full-resolution export-intent one.
    func testImportRendersBoundedPreviewSnapshot() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: fixture.videoURL))
        let snapshot = try XCTUnwrap(coordinator.previewSnapshot, "A successful import MUST render the first frame")
        XCTAssertEqual(snapshot.request.intent, .preview, "The imported frame MUST render with preview intent")
        XCTAssertLessThanOrEqual(snapshot.request.width, LifecycleCoordinator.previewMaximumDimension)
        XCTAssertLessThanOrEqual(snapshot.request.height, LifecycleCoordinator.previewMaximumDimension)
        XCTAssertEqual(snapshot.pixels.count, snapshot.request.width * snapshot.request.height)
    }

    // An out-of-range index is a programming no-op, NOT a user-visible failure: the currently
    // displayed frame survives untouched and no error is surfaced.
    func testShowFrameOutOfRangeLeavesSnapshotAndErrorUntouched() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: fixture.videoURL))
        let before = try XCTUnwrap(coordinator.previewSnapshot)
        await coordinator.showFrame(at: coordinator.importedFrameCount)
        XCTAssertEqual(coordinator.previewSnapshot, before, "An index past the end MUST leave the shown frame untouched")
        await coordinator.showFrame(at: -1)
        XCTAssertEqual(coordinator.previewSnapshot, before, "A negative index MUST leave the shown frame untouched")
        XCTAssertNil(coordinator.lastError, "An out-of-range index MUST NOT surface a user-visible error")
    }

    // Without an import there is nothing to show: no snapshot, and still no error.
    func testShowFrameWithoutImportLeavesPreviewEmpty() async {
        let coordinator = LifecycleCoordinator()
        await coordinator.showFrame(at: 0)
        XCTAssertNil(coordinator.previewSnapshot, "No import MUST mean no preview snapshot")
        XCTAssertNil(coordinator.lastError, "Showing a frame with nothing imported MUST NOT surface an error")
    }

    // Navigation: advancing to a later frame shows THAT frame's real presentation time (VFR-safe),
    // never an index-derived value.
    func testShowFrameAdvancesPreviewTimestampToFramePresentationTime() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = LifecycleCoordinator()
        await coordinator.importAsset(AVURLAsset(url: fixture.videoURL))
        let sources = try XCTUnwrap(coordinator.importedSources)
        XCTAssertGreaterThan(sources.count, 2, "The fixture MUST provide more than two frames to advance through")
        XCTAssertEqual(coordinator.previewState.currentTimestamp, sources[0].presentationTime)
        await coordinator.showFrame(at: 2)
        XCTAssertEqual(coordinator.previewState.currentTimestamp, sources[2].presentationTime,
                       "Advancing MUST track the shown frame's own presentation time")
        XCTAssertEqual(coordinator.previewSnapshot?.request.timestamp, sources[2].presentationTime,
                       "The rendered snapshot MUST carry the shown frame's presentation time")
        XCTAssertNil(coordinator.lastError)
    }

    private func settings() throws -> RenderSettings {
        try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: bw))
    }
    private func exportURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("u8-lifecycle-\(UUID().uuidString).mov")
    }
    private func vfrSources(count: Int) -> [ExportSource] {
        (0..<count).map { i in
            let pix = (0..<(16 * 8)).map { UInt8(truncatingIfNeeded: ($0 + i * 17) &* 9 &+ 11) }
            return ExportSource(pixels: pix, sourceWidth: 16, sourceHeight: 8, presentationTime: Double(i) * 0.04)
        }
    }
    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
    /// Re-reads an exported `.mov` and counts committed video sample buffers (mirrors the
    /// `ExportSessionTests` runtime-harness pattern used to prove no-partial-batches).
    private func readVideoFrameCount(_ url: URL) throws -> Int {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = asset.tracks(withMediaType: .video).first else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return 0 }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return count
    }
    /// Builds a fixture whose `moov` metadata (tracks/format/transform) parses fine — so
    /// `AssetValidator` reports it supported — but whose `mdat` payload is overwritten in place
    /// (same byte length, so `moov` sample-table offsets stay valid) so decoding real frame data
    /// genuinely fails. This is the exact condition `AssetFrameExtractor.extract`'s own
    /// `reader.reader.status == .completed` guard exists to catch.
    private func corruptedFixtureAsset() throws -> (asset: AVAsset, urls: [URL]) {
        let fixture = try MediaFixtureFactory().makeFixture()
        var data = try Data(contentsOf: fixture.videoURL)
        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
                | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            guard size >= 8, offset + size <= data.count else { break }
            if type == "mdat" {
                for i in (offset + 8)..<(offset + size) { data[i] = 0xFF }
            }
            offset += size
        }
        try data.write(to: fixture.videoURL)
        return (AVURLAsset(url: fixture.videoURL), fixture.urls)
    }
}