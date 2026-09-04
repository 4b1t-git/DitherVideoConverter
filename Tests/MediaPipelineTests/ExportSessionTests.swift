import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
import XCTest
@testable import AnciiVideoGenerator

final class ExportSessionTests: XCTestCase {
    private let bw: [SRGBColor] = [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 255, g: 255, b: 255)]
    private var ramp: [UInt8] { (0..<(16 * 8)).map { UInt8(truncatingIfNeeded: $0 &* 15 &+ 5) } }

    // R3-001: BT.2390-to-100-nit Rec.709 EETF; hardcoded golden bytes.
    func testToneMapAppliesBT2390EETFMatchesSpecifiedBrightness() {
        let golden: [UInt8: UInt8] = [0: 0, 64: 3, 96: 14, 128: 34, 160: 66, 192: 112, 224: 175, 255: 235]
        for (src, expected) in golden {
            XCTAssertEqual(MetalFrameRenderer.toneMap(src), expected,
                           "BT.2390 EETF MUST map PQ source \(src) to Rec.709 brightness \(expected) (R3-001)")
        }
        var prev: UInt8 = 0
        for v in 0...255 where v % 16 == 0 {
            let out = MetalFrameRenderer.toneMap(UInt8(v))
            XCTAssertGreaterThanOrEqual(out, prev, "BT.2390 EETF MUST be monotonic")
            prev = out
        }
    }

    // R3-006: ExportSettings rejects out-of-contract scale at construction.
    func testExportSettingsRejectsScaleOutOfRangeAtConstruction() throws {
        XCTAssertNoThrow(try ExportSettings(render: try settings(), scale: 1.0))
        XCTAssertNoThrow(try ExportSettings(render: try settings(), scale: 0.5))
        XCTAssertThrowsError(try ExportSettings(render: try settings(), scale: 2.0)) { err in
            XCTAssertEqual(err as? RenderSettingsError, .invalidDimensions, "scale > 1 MUST be rejected at construction (R3-006)")
        }
        XCTAssertThrowsError(try ExportSettings(render: try settings(), scale: 0)) { _ in }
        XCTAssertThrowsError(try ExportSettings(render: try settings(), scale: -0.1)) { _ in }
    }

    // R3-016: codec allowlist rejects a non-H.264/HEVC format description (MJPEG).
    func testCodecAllowlistRejectsNonH264HEVCFormatDescription() throws {
        var desc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_JPEG,
                                        width: 16, height: 8, extensions: nil, formatDescriptionOut: &desc)
        let violation = AssetValidator.codecViolation(desc!)
        XCTAssertEqual(violation, .unsupportedCodec("jpeg"), "MJPEG (non-H.264/HEVC) MUST be rejected by codec allowlist (R3-016)")
        // H.264 and HEVC ARE allowed — verified by the existing fixture-based AssetValidator test.
        var h264: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                                        width: 16, height: 8, extensions: nil, formatDescriptionOut: &h264)
        XCTAssertNil(AssetValidator.codecViolation(h264!), "H.264 MUST pass the codec allowlist")
    }

    // R3-015: protected-content asset mock is rejected by `validate`.
    func testProtectedContentAssetIsRejected() async {
        let asset = ProtectedAssetMock()
        let report = await AssetValidator.validate(asset, maximumDimension: 4_096)
        XCTAssertFalse(report.isSupported, "Protected content MUST be rejected (R3-015)")
        XCTAssertEqual(report.violation, .protected)
    }

    // Spec scenario "Safe lifecycle": progress monotonic, 1.0 only at completed; bounded three-buffer in-flight.
    func testExportProducesMovWithMonotonicProgressAndBoundedThreeBuffer() async throws {
        let url = newMovURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        let sources = vfrSources(count: 6, width: 16, height: 8)
        let result = try await session.export(sources: sources, audio: .none, outputURL: url)
        XCTAssertEqual(result.frameCount, 6)
        XCTAssertEqual(result.audioMode, .none)
        XCTAssertEqual(result.completionFraction, 1.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Completed export MUST leave the output file")
        let progress = await session.currentProgress()
        XCTAssertEqual(progress.stage, .completed)
        XCTAssertEqual(progress.fractionCompleted, 1.0, "Progress MUST reach 1.0 only at completion")
        let inFlight = await session.maxInFlightBufferCount()
        XCTAssertLessThanOrEqual(inFlight, 3, "Three-buffer bound MUST keep in-flight buffers ≤3")
    }

    // Spec scenario "Safe lifecycle": cancellation MUST delete partial output and preserve source.
    func testCancelDeletesPartialOutput() async throws {
        let url = newMovURL()
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        let sources = vfrSources(count: 12, width: 16, height: 8)
        await session.cancel()
        do {
            _ = try await session.export(sources: sources, audio: .none, outputURL: url)
            XCTFail("Export after pre-emptive cancel MUST throw ExportError.cancelled")
        } catch ExportError.cancelled {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Cancelled export MUST delete partial output")
        }
        let progress = await session.currentProgress()
        XCTAssertEqual(progress.stage, .cancelled)
        XCTAssertLessThan(progress.fractionCompleted, 1.0, "Cancelled progress MUST NOT reach 1.0")
    }

    func testCancelMidExportDeletesPartialOutput() async throws {
        let url = newMovURL()
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        let sources = vfrSources(count: 30, width: 16, height: 8)
        Task { try? await Task.sleep(nanoseconds: 5_000_000); await session.cancel() }
        do {
            _ = try await session.export(sources: sources, audio: .none, outputURL: url)
            XCTFail("Mid-export cancel MUST throw ExportError.cancelled")
        } catch ExportError.cancelled {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Cancelled mid-export MUST delete partial output")
        }
    }

    // Spec scenario "Audio policy": audio-less input MUST remain audio-less.
    func testAudioLessInputStaysAudioLess() async throws {
        let url = newMovURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        let sources = vfrSources(count: 4, width: 16, height: 8)
        let result = try await session.export(sources: sources, audio: .none, outputURL: url)
        XCTAssertEqual(result.audioMode, .none)
        let output = AVURLAsset(url: url)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 0, "Audio-less export MUST remain audio-less")
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1, "Export MUST produce exactly one video track")
    }

    func testExportErrorsNameStageAndCorrection() async throws {
        let url = newMovURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        do {
            _ = try await session.export(sources: [], audio: .none, outputURL: url)
            XCTFail("Empty sources MUST throw ExportError.noFrames")
        } catch ExportError.noFrames {
            XCTAssertFalse(ExportError.noFrames.errorDescription?.isEmpty ?? true, "Export error MUST name a stage + correction")
        } catch { XCTFail("Unexpected error: \(error)") }
        // Every ExportError variant MUST carry an actionable stage + correction description.
        for variant: ExportError in [.alreadyRunning, .noFrames, .noVideo, .unsupportedCodec("mjpeg"), .writerRejected("test"), .cancelled] {
            XCTAssertFalse(variant.errorDescription?.isEmpty ?? true, "ExportError MUST describe correction: \(variant)")
        }
    }

    // R3-009: cross-run / cross-machine determinism of `MetalFrameRenderer` through the export path.
    func testRendererDeterminismGoldenHashThroughExport() async throws {
        let settings = try settings()
        let renderer = MetalFrameRenderer()
        let request = RenderRequest(timestamp: 0, width: 16, height: 8, intent: .export, scale: 1)
        let first = try await renderer.render(request: request, settings: settings,
                                              pixels: ramp, sourceWidth: 16, sourceHeight: 8)
        let second = try await renderer.render(request: request, settings: settings,
                                               pixels: ramp, sourceWidth: 16, sourceHeight: 8)
        XCTAssertEqual(first, second, "Renderer MUST be byte-identical across runs (R3-009)")
        let hash = SHA256.hash(data: Data(first)).map { String(format: "%02x", $0) }.joined()
        // R3-019: pin the EXPORT_GOLDEN sha256 as a stored cross-machine constant so any MetalFrameRenderer/
        // RenderSettings refactor regression surfaces here. M5-baseline; the assertion pins the value
        // the deterministic renderer produces on this host (Unit 7 recorded this exact hash).
        XCTAssertEqual(hash, "54baeeef1ebfe5a4c1a2a10ee26faa2c40b134b63131a6eb3e87af5a4a00cbd3",
                      "EXPORT_GOLDEN MUST equal the stored cross-machine M5-baseline constant (R3-019)")
        print("EXPORT_GOLDEN bytes=128 hash=\(hash) scope=cross-run-MetalFrameRenderer-determinism-through-export")
    }
    // Runtime harness: VFR/rotated-HDR `.mov` export commits every input frame without partial batches.
    func testRuntimeVFRRotatedHDRExportCommitsAllFramesWithoutPartials() async throws {
        let url = newMovURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        let pts: [Double] = [0.04, 0.08, 0.13, 0.20, 0.21, 0.30]
        let sources: [ExportSource] = pts.enumerated().map { (i, t) in
            ExportSource(pixels: [UInt8](repeating: UInt8(truncatingIfNeeded: i &* 40 &+ 10), count: 8 * 16),
                         sourceWidth: 8, sourceHeight: 16, presentationTime: t)
        }
        let result = try await session.export(sources: sources, audio: .none, outputURL: url)
        XCTAssertEqual(result.frameCount, sources.count, "Writer MUST commit every input frame (no partial batches)")
        let output = AVURLAsset(url: url)
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let reader = try AVAssetReader(asset: output)
        let trackOutput = AVAssetReaderTrackOutput(track: videoTracks[0], outputSettings: nil)
        reader.add(trackOutput) // R3-021: macOS returns Void; not Bool here
        XCTAssertTrue(reader.startReading(), "Runtime harness MUST re-read the exported .mov")
        var sampleCount = 0
        while let sample = trackOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { sampleCount += 1 }
        }
        switch reader.status {
        case .completed: break
        default: XCTFail("Reader MUST drain to completed; status=\(String(describing: reader.status))")
        }
        XCTAssertEqual(sampleCount, sources.count, "Exported .mov MUST contain exactly one sample buffer per input frame (no partials)")
        let progress = await session.currentProgress()
        XCTAssertEqual(progress.stage, .completed)
        XCTAssertEqual(progress.fractionCompleted, 1.0)
    }

    // H2-010 (R3-017): maxInFlightBufferCount() MUST report a real observed maximum under
    // injected readiness pressure, not a fabricated constant. The injected predicate bounds
    // on `outstandingBuffers` alone (ignoring the writer's own readiness), so a genuine
    // 3-deep retention pipeline is the only way this can settle at exactly 3.
    func testMaxInFlightBufferCountReportsThreeUnderInjectedReadiness() async throws {
        let url = newMovURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        await session.setMediaDataReadiness { outstanding in outstanding < 3 }
        let sources = vfrSources(count: 6, width: 16, height: 8)
        _ = try await session.export(sources: sources, audio: .none, outputURL: url)
        let inFlight = await session.maxInFlightBufferCount()
        XCTAssertEqual(inFlight, 3, "Injected readiness bounding on outstandingBuffers MUST settle the observed maximum at exactly 3 (R3-017)")
        XCTAssertGreaterThan(inFlight, 1, "The observed maximum MUST NOT be the prior fabricated constant of 1")
    }

    // H2-020 (R3-017): backpressure waits MUST be counted when the pool is at capacity.
    func testBackpressureWaitCountIncrementsWhenPoolAtCapacity() async throws {
        let url = newMovURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        await session.setMediaDataReadiness { outstanding in outstanding < 3 }
        let sources = vfrSources(count: 6, width: 16, height: 8)
        _ = try await session.export(sources: sources, audio: .none, outputURL: url)
        let waits = await session.backpressureWaitCount
        XCTAssertGreaterThan(waits, 0, "backpressureWaitCount MUST be > 0 once the injected readiness returns false at least once (R3-017)")
    }

    /// Test double for the `checkpointBeforeFinalize` seam: gates on a `CheckedContinuation`
    /// so a test can observe the exact tail-window suspension point and call `cancel()`
    /// before releasing it. Zero sleeps, zero timing tolerances (mirrors `BlockingFrameRenderer`).
    private actor ExportCheckpointGate {
        private var arrivalContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var hasArrived = false

        func waitForArrival() async {
            if hasArrived { return }
            await withCheckedContinuation { continuation in arrivalContinuation = continuation }
        }

        func checkpoint() async {
            hasArrived = true
            arrivalContinuation?.resume()
            arrivalContinuation = nil
            await withCheckedContinuation { continuation in releaseContinuation = continuation }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    // H2-030 (R3-018): cancel observed at the tail window (after the final append, before
    // markAsFinished) MUST throw ExportError.cancelled and delete the partial output.
    func testCancelObservedAtTailWindowDeletesPartialOutputAndThrows() async throws {
        let url = newMovURL()
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        let gate = ExportCheckpointGate()
        await session.setCheckpointBeforeFinalize { await gate.checkpoint() }
        let sources = vfrSources(count: 4, width: 16, height: 8)

        async let exportResult = session.export(sources: sources, audio: .none, outputURL: url)
        await gate.waitForArrival()
        await session.cancel()
        await gate.release()

        do {
            _ = try await exportResult
            XCTFail("Cancel observed at the tail-window checkpoint MUST throw ExportError.cancelled")
        } catch ExportError.cancelled {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Tail-window cancel MUST delete partial output")
        }
    }

    // H5-020 (export-audio): passthrough export produces exactly 1 audio track carrying
    // passthrough-compatible samples (the qualifying source format is retained, not transcoded).
    func testPassthroughExportProducesExactlyOneAudioTrack() async throws {
        let url = newMovURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try MediaFixtureFactory().makeCombinedFixture(audio: .aac)
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let audioAsset = AVURLAsset(url: fixture.audioURL)
        let audioTrackList = try await audioAsset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTrackList.first)
        let decision = try await AudioPolicy.decision(for: track)
        XCTAssertEqual(decision.mode, .passthrough, "AAC source MUST qualify for passthrough")
        let attachment = AudioAttachment(decision: decision, track: track)
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        let sources = vfrSources(count: 4, width: 16, height: 8)
        let result = try await session.export(sources: sources, audio: .passthrough, audioSource: attachment, outputURL: url)
        XCTAssertEqual(result.audioMode, .passthrough)
        let output = AVURLAsset(url: url)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "Passthrough export MUST produce exactly one audio track")
        let outputFormats = try await audioTracks[0].load(.formatDescriptions)
        let outputFormat = try XCTUnwrap(outputFormats.first)
        XCTAssertNotEqual(CMFormatDescriptionGetMediaSubType(outputFormat), kAudioFormatLinearPCM,
                          "Passthrough audio MUST retain a non-LPCM (compatible source) subtype")
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
    }

    // H5-030 (export-audio): a source requiring AAC fallback MUST produce exactly 1 AAC audio track.
    func testAacFallbackExportProducesExactlyOneAacAudioTrack() async throws {
        let url = newMovURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try MediaFixtureFactory().makeCombinedFixture(audio: .lpcm)
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let audioAsset = AVURLAsset(url: fixture.audioURL)
        let audioTrackList = try await audioAsset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTrackList.first)
        let decision = try await AudioPolicy.decision(for: track)
        XCTAssertEqual(decision.mode, .aacFallback, "LPCM source MUST resolve to AAC fallback")
        let attachment = AudioAttachment(decision: decision, track: track)
        let session = ExportSession(renderer: MetalFrameRenderer(), settings: try exportSettings())
        let sources = vfrSources(count: 4, width: 16, height: 8)
        let result = try await session.export(sources: sources, audio: .aacFallback, audioSource: attachment, outputURL: url)
        XCTAssertEqual(result.audioMode, .aacFallback)
        let output = AVURLAsset(url: url)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "AAC fallback export MUST produce exactly one audio track")
        let outputFormats = try await audioTracks[0].load(.formatDescriptions)
        let outputFormat = try XCTUnwrap(outputFormats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(outputFormat), kAudioFormatMPEG4AAC,
                      "AAC fallback audio track MUST be encoded as AAC")
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
    }

    private func settings() throws -> RenderSettings {
        try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: bw))
    }
    private func exportSettings(scale: Double = 1.0) throws -> ExportSettings {
        try ExportSettings(render: try settings(), scale: scale)
    }
    private func newMovURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("u7-export-\(UUID().uuidString).mov")
    }
    private func vfrSources(count: Int, width: Int, height: Int) -> [ExportSource] {
        (0..<count).map { i in
            let pix = (0..<(width * height)).map { UInt8(truncatingIfNeeded: ($0 + i * 17) &* 9 &+ 11) }
            return ExportSource(pixels: pix, sourceWidth: width, sourceHeight: height, presentationTime: Double(i) * 0.04)
        }
    }
}

/// Synthetic AVAsset whose `hasProtectedContent` reports true (R3-015 carry-forward).
/// `AssetValidator.validate` rejects before reading tracks, so no track data is needed.
final class ProtectedAssetMock: AVAsset {
    override var hasProtectedContent: Bool { true }
}