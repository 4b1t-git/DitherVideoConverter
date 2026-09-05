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

    /// Test double for `FrameRendering` that gates each render on a `CheckedContinuation`
    /// keyed by `request.timestamp`, so a test can control exactly which concurrent scrub
    /// resumes first. Zero sleeps, zero timing tolerances.
    private actor BlockingFrameRenderer: FrameRendering {
        private var arrivals: [Double: CheckedContinuation<Void, Never>] = [:]
        private var arrived: Set<Double> = []
        private var releases: [Double: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<Double> = []

        func waitForArrival(timestamp: Double) async {
            if arrived.contains(timestamp) { return }
            await withCheckedContinuation { continuation in
                arrivals[timestamp] = continuation
            }
        }

        func release(timestamp: Double) {
            released.insert(timestamp)
            if let continuation = releases.removeValue(forKey: timestamp) {
                continuation.resume()
            }
        }

        func render(request: RenderRequest, settings: RenderSettings,
                    pixels: [UInt8], sourceWidth: Int, sourceHeight: Int) async throws -> [UInt8] {
            arrived.insert(request.timestamp)
            if let waiter = arrivals.removeValue(forKey: request.timestamp) {
                waiter.resume()
            }
            if !released.contains(request.timestamp) {
                await withCheckedContinuation { continuation in
                    releases[request.timestamp] = continuation
                }
            }
            return [UInt8](repeating: 0, count: request.width * request.height)
        }
    }

    func testStaleScrubDroppedAfterSuspension() async throws {
        let renderer = BlockingFrameRenderer()
        let pipeline = PreviewPipeline(renderer: renderer, settings: try settings(), previewScale: 0.5)

        async let token1Result = pipeline.scrub(token: 1, timestamp: 1, source: gradient, sourceWidth: 16, sourceHeight: 32)
        await renderer.waitForArrival(timestamp: 1)

        async let token2Result = pipeline.scrub(token: 2, timestamp: 2, source: gradient, sourceWidth: 16, sourceHeight: 32)
        await renderer.waitForArrival(timestamp: 2)

        await renderer.release(timestamp: 2)
        let snapshot2 = try await token2Result
        XCTAssertNotNil(snapshot2, "The newer scrub token MUST resolve to a snapshot once its render completes")

        await renderer.release(timestamp: 1)
        let snapshot1 = try await token1Result
        XCTAssertNil(snapshot1, "A scrub token superseded during its own render suspension MUST return nil, even though it started first (post-suspension re-validation)")
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

    // R3-011 (preview-render-wiring): the on-screen preview MUST be able to draw the snapshot as a
    // single `CGImage` rather than one fill per pixel. The image's geometry is the request's
    // geometry — never the source's, and never the byte count's.
    func testGrayscaleImageMatchesRequestDimensions() throws {
        let request = RenderRequest(timestamp: 0, width: 4, height: 3, intent: .preview, scale: 0.5)
        let snapshot = PreviewSnapshot(request: request, pixels: [UInt8](repeating: 128, count: 4 * 3))
        let image = try XCTUnwrap(snapshot.makeImage(settings: try sdrSettings()),
                                  "A fully-populated snapshot MUST produce an image")
        XCTAssertEqual(image.width, 4, "Image width MUST come from RenderRequest.width")
        XCTAssertEqual(image.height, 3, "Image height MUST come from RenderRequest.height")
    }

    // A truncated snapshot MUST fail closed: returning an image over a short buffer would let
    // CoreGraphics read past the end of the array. `nil` is the only safe answer.
    func testGrayscaleImageIsNilWhenPixelsAreShorterThanRequest() throws {
        let settings = try sdrSettings()
        let request = RenderRequest(timestamp: 0, width: 8, height: 8, intent: .preview, scale: 0.5)
        let short = PreviewSnapshot(request: request, pixels: [UInt8](repeating: 7, count: 8 * 8 - 1))
        XCTAssertNil(short.makeImage(settings: settings), "A snapshot shorter than width*height MUST NOT produce an image")
        let empty = PreviewSnapshot(request: RenderRequest(timestamp: 0, width: 0, height: 0, intent: .preview, scale: 1),
                                    pixels: [])
        XCTAssertNil(empty.makeImage(settings: settings), "A zero-sized request MUST NOT produce an image")
    }

    // Dimensions alone would pass with an all-black image: assert the real VALUES survive the trip
    // through `CGDataProvider` untouched (bytesPerRow == width*4, no padding, no premultiply). Under
    // `.postToneMapSDR` the renderer's byte IS brightness, so every pixel MUST come back as that
    // exact grey — the mapping may not re-quantize what the renderer already resolved.
    func testGrayscaleImageRoundTripsPixelValues() throws {
        let width = 4, height = 2
        let ramp: [UInt8] = [0, 17, 200, 255, 33, 90, 128, 254]
        let request = RenderRequest(timestamp: 0, width: width, height: height, intent: .preview, scale: 1)
        let image = try XCTUnwrap(PreviewSnapshot(request: request, pixels: ramp).makeImage(settings: try sdrSettings()))
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bytesPerRow, width * 4, "bytesPerRow MUST equal width*4 so rows are tightly packed")
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let expected: [UInt8] = ramp.flatMap { [$0, $0, $0, 255] }
        XCTAssertEqual(Array(data.prefix(width * 4)), Array(expected.prefix(width * 4)),
                       "The first row's RGBA bytes MUST equal the snapshot's own bytes painted as grey")
        XCTAssertEqual(Array(data), expected, "Every byte MUST round-trip unchanged through the colour mapping")
    }

    // The preview MUST paint through the SAME mapping the export writes: under a palette background
    // the renderer's byte is an INDEX, and reading it as grey is what made a colour palette
    // impossible to see on screen.
    func testImageResolvesPaletteIndicesToPaletteColours() throws {
        let sepia = [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 80, g: 40, b: 20),
                     SRGBColor(r: 180, g: 130, b: 80), SRGBColor(r: 250, g: 240, b: 210)]
        let settings = try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: sepia),
                                          background: .blackOnWhite)
        let request = RenderRequest(timestamp: 0, width: 4, height: 1, intent: .preview, scale: 1)
        let image = try XCTUnwrap(PreviewSnapshot(request: request, pixels: [0, 1, 2, 3]).makeImage(settings: settings))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let expected: [UInt8] = sepia.flatMap { [$0.r, $0.g, $0.b, 255] }
        XCTAssertEqual(Array(data), expected,
                       "Each palette index MUST paint as its own sRGB colour, not as grey 0…3")
    }

    private func makePipeline(scale: Double) async throws -> PreviewPipeline {
        PreviewPipeline(renderer: MetalFrameRenderer(), settings: try settings(), previewScale: scale)
    }

    private func settings() throws -> RenderSettings {
        try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: blackWhite))
    }
    /// Settings whose renderer output is BRIGHTNESS, so the image tests above can assert the byte
    /// itself survives rather than reasoning about palette-index resolution at the same time.
    private func sdrSettings() throws -> RenderSettings {
        try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: blackWhite),
                           background: .postToneMapSDR)
    }
}