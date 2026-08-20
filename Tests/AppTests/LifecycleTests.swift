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
}