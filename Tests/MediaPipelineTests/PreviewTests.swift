import AVFoundation
import CryptoKit
import XCTest
@testable import AnciiVideoGenerator

final class PreviewTests: XCTestCase {
    private let blackWhite: [SRGBColor] = [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 255, g: 255, b: 255)]
    private var gradient: [UInt8] { (0..<(16 * 32)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 13) } }

    func testPreviewPipelineLowersResolutionViaRenderRequestScaleOnly() async throws {
        let pipeline = try await makePipeline(scale: 0.5)
        let snapshot = try await pipeline.render(timestamp: 0, source: gradient, sourceWidth: 16, sourceHeight: 32)
        XCTAssertEqual(snapshot.request.intent, .preview)
        XCTAssertEqual(snapshot.request.scale, 0.5, "Preview MUST lower resolution via RenderRequest.scale only (R3-003)")
        XCTAssertEqual(snapshot.request.width, 8)
        XCTAssertEqual(snapshot.request.height, 16)
        XCTAssertEqual(snapshot.request.timestamp, 0)
        XCTAssertEqual(snapshot.pixels.count, 8 * 16)
        let renderer = MetalFrameRenderer()
        let direct = try await renderer.render(request: snapshot.request, settings: try settings(),
                                               pixels: gradient, sourceWidth: 16, sourceHeight: 32)
        XCTAssertEqual(snapshot.pixels, direct, "Preview MUST reuse the sole renderer; no hidden re-sampling branch")
    }

    @MainActor
    func testPreviewTimestampReflectsSourceTimeAndStateTransitions() async throws {
        let state = PreviewState()
        XCTAssertEqual(state.phase, .empty)
        state.setImporting(); XCTAssertEqual(state.phase, .importing)
        state.setReady(timestamp: 0); XCTAssertEqual(state.phase, .ready); XCTAssertEqual(state.currentTimestamp, 0)
        state.play(at: 30); XCTAssertEqual(state.phase, .playing); XCTAssertEqual(state.currentTimestamp, 30)
        state.scrub(to: 45); XCTAssertEqual(state.currentTimestamp, 45)
        let pipeline = try await makePipeline(scale: 0.25)
        for t in [0.0, 12.5, 60.0] {
            let snapshot = try await pipeline.render(timestamp: t, source: gradient, sourceWidth: 16, sourceHeight: 32)
            XCTAssertEqual(snapshot.request.timestamp, t, "Preview SHALL show the source timestamp (Navigation scenario)")
        }
    }

    func testStaleScrubsAreDiscardedByTokenCoalescing() async throws {
        let pipeline = try await makePipeline(scale: 0.5)
        let accept1 = try await pipeline.scrub(token: 1, timestamp: 1, source: gradient, sourceWidth: 16, sourceHeight: 32)
        XCTAssertNotNil(accept1)
        let accept3 = try await pipeline.scrub(token: 3, timestamp: 3, source: gradient, sourceWidth: 16, sourceHeight: 32)
        XCTAssertNotNil(accept3)
        let stale = try await pipeline.scrub(token: 2, timestamp: 2, source: gradient, sourceWidth: 16, sourceHeight: 32)
        XCTAssertNil(stale, "Stale scrub tokens MUST be discarded (zero-tolerance coalescing)")
        let accept4 = try await pipeline.scrub(token: 4, timestamp: 4, source: gradient, sourceWidth: 16, sourceHeight: 32)
        XCTAssertNotNil(accept4, "A newer token after a stale one MUST still be accepted")
    }

    func testPreviewWhiteOnBlackInversionGoesThroughRendererUnchanged() async throws {
        let renderer = MetalFrameRenderer()
        let palette = try Palette(colors: blackWhite)
        let inverted = try RenderSettings(style: .dither(.bayer), palette: palette, background: .whiteOnBlack)
        let pipeline = PreviewPipeline(renderer: renderer, settings: inverted, previewScale: 0.5)
        let snapshot = try await pipeline.render(timestamp: 0, source: gradient, sourceWidth: 16, sourceHeight: 32)
        let direct = try await renderer.render(request: snapshot.request, settings: inverted,
                                               pixels: gradient, sourceWidth: 16, sourceHeight: 32)
        XCTAssertEqual(snapshot.pixels, direct, "Preview inversion MUST flow through RenderSettings.whiteOnBlack, not a preview-side invert (R3-004)")
        let normal = try await renderer.render(request: snapshot.request, settings: try settings(),
                                               pixels: gradient, sourceWidth: 16, sourceHeight: 32)
        XCTAssertNotEqual(snapshot.pixels, normal, "whiteOnBlack MUST produce distinct output for a non-symmetric source")
    }

    @MainActor
    func testImportPlayScrubSixtySecondHarnessDeterministicWithoutLiveAVPlayer() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let report = await AssetValidator.validate(AVURLAsset(url: fixture.videoURL), maximumDimension: 4_096)
        XCTAssertTrue(report.isSupported, "Harness import MUST validate the real fixture first")
        let state = PreviewState()
        state.setImporting(); state.setReady(timestamp: 0)
        let pipeline = try await makePipeline(scale: 0.5)
        var snapshots: [PreviewSnapshot] = []
        for t in [0.0, 15.0, 30.0, 45.0, 60.0] {
            state.play(at: t)
            snapshots.append(try await pipeline.render(timestamp: t, source: gradient, sourceWidth: 16, sourceHeight: 32))
        }
        XCTAssertEqual(snapshots.map(\.request.timestamp), [0, 15, 30, 45, 60])
        XCTAssertTrue(snapshots.allSatisfy { $0.request.intent == .preview && $0.request.scale == 0.5 && $0.pixels.count == 128 })
        XCTAssertEqual(state.phase, .playing)
        let hash = SHA256.hash(data: Data(snapshots.flatMap(\.pixels))).map { String(format: "%02x", $0) }.joined()
        print("PREVIEW_HARNESS frames=\(snapshots.count) timestamps=0,15,30,45,60 scale=0.5 pixelsPerFrame=128 compoundHash=\(hash) scope=deterministic-no-live-AVPlayer-live-loop-deferred-to-Unit-8")
    }

    private func makePipeline(scale: Double) async throws -> PreviewPipeline {
        PreviewPipeline(renderer: MetalFrameRenderer(), settings: try settings(), previewScale: scale)
    }

    private func settings() throws -> RenderSettings {
        try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: blackWhite))
    }
}