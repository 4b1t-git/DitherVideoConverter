import AVFoundation
import CoreVideo
import XCTest
@testable import AnciiVideoGenerator
final class FixtureGateTests: XCTestCase {
    func testAVFoundationFixturePreservesTimingGeometryAndColorMetadata() async throws {
        let factory = MediaFixtureFactory()
        let fixture = try factory.makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let inspection = try await factory.inspect(fixture)

        assertTimes(inspection.video.map(\.presentationTime), [t(1_200), t(1_224), t(1_320), t(1_380)])
        assertTimes(inspection.video.map(\.duration), [t(24), t(48), t(24), t(60)])
        assertTimes(gaps(inspection.video), [t(0), t(48), t(36)])
        XCTAssertEqual(CMTimeCompare(try XCTUnwrap(inspection.audio.first?.presentationTime), t(72_000, 48_000)), 0)
        XCTAssertTrue(inspection.audio.allSatisfy { CMTimeCompare($0.duration, .zero) > 0 })
        XCTAssertEqual(inspection.decodedVideoCount, 4, "AVAssetReader must return every authored video sample")
        XCTAssertEqual(inspection.naturalSize, CGSize(width: 32, height: 16))
        XCTAssertEqual(inspection.preferredTransform, CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        XCTAssertEqual(inspection.cleanAperture.size, CGSize(width: 30, height: 14))
        XCTAssertEqual(inspection.pixelAspectRatio, CGSize(width: 2, height: 1))
        XCTAssertEqual(inspection.colorPrimaries, kCVImageBufferColorPrimaries_P3_D65 as String)
        XCTAssertEqual(inspection.transferFunction, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        XCTAssertEqual(inspection.yCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
    }
    func testTimelineNormalizerUsesCommonEpochWithoutChangingCadence() throws {
        let video = [sample(1_200, 24), sample(1_224, 48), sample(1_320, 24), sample(1_380, 60)]
        let audio = [sample(72_000, 4_800, 48_000), sample(76_800, 4_800, 48_000)]
        let timeline = try TimelineNormalizer.normalize(video: video, audio: audio)

        XCTAssertEqual(timeline.epoch, t(72_000, 48_000))
        assertTimes(timeline.video.map(\.presentationTime), [t(300), t(324), t(420), t(480)])
        assertTimes(timeline.video.map(\.duration), video.map(\.duration))
        assertTimes(timeline.videoGaps, gaps(video))
        assertTimes(timeline.audio.map(\.presentationTime), [.zero, t(4_800, 48_000)])
        XCTAssertEqual(timeline.video.count, video.count)
        XCTAssertEqual(timeline.sourceDuration, t(540))
        XCTAssertTrue(timeline.isWithinFinalVideoSample(of: t(570)))
    }
    func testTimelineNormalizerTriangulatesWhenVideoStartsBeforeAudio() throws {
        let timeline = try TimelineNormalizer.normalize(
            video: [sample(600, 60), sample(780, 30)], audio: [sample(900, 60)]
        )
        assertTimes(timeline.video.map(\.presentationTime), [.zero, t(180)])
        assertTimes(timeline.audio.map(\.presentationTime), [t(300)])
        assertTimes(timeline.videoGaps, [t(120)])
        XCTAssertEqual(timeline.sourceDuration, t(210))
    }

    func testGeometryPlanProducesUprightMirroredSDRRec709Intent() throws {
        let plan = try geometryPlan()

        XCTAssertEqual(plan.outputDimensions, CGSize(width: 16, height: 32))
        XCTAssertEqual(plan.orientedDisplayDimensions, CGSize(width: 14, height: 60))
        XCTAssertTrue(plan.isMirrored)
        XCTAssertEqual(plan.cleanAperture.size, CGSize(width: 30, height: 14))
        XCTAssertEqual(plan.pixelAspectRatio, CGSize(width: 2, height: 1))
        XCTAssertEqual(plan.colorNormalization.output, "8-bit SDR Rec.709")
        XCTAssertFalse(plan.colorNormalization.supportsHDROutput)
        XCTAssertEqual(
            plan.colorNormalization.description,
            "Tone-map HDR/wide-color input to 100-nit linear Rec.709 before styling; encode 8-bit SDR Rec.709. HDR output is unsupported."
        )
    }

    func testGeometryPlanRejectsUnsupportedDimensionsWithoutResizing() {
        XCTAssertThrowsError(try geometryPlan(size: CGSize(width: 5_000, height: 3_000))) {
            XCTAssertEqual($0 as? GeometryPlanError,
                           .unsupportedDimensions(CGSize(width: 3_000, height: 5_000)))
        }
    }

    private func sample(_ pts: Int64, _ duration: Int64, _ scale: Int32 = 600) -> MediaSampleTiming {
        MediaSampleTiming(presentationTime: t(pts, scale), duration: t(duration, scale))
    }

    private func geometryPlan(size: CGSize = CGSize(width: 32, height: 16)) throws -> GeometryPlan {
        try GeometryPlan(naturalSize: size,
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0),
            cleanAperture: CGRect(x: 1, y: 1, width: 30, height: 14),
            pixelAspectRatio: CGSize(width: 2, height: 1),
            sourceColor: SourceColorSignal(isHDR: true, isWideColor: true), maximumDimension: 4_096)
    }

    private func t(_ value: Int64, _ scale: Int32 = 600) -> CMTime {
        CMTime(value: value, timescale: scale)
    }

    private func gaps(_ samples: [MediaSampleTiming]) -> [CMTime] {
        zip(samples, samples.dropFirst()).map {
            CMTimeSubtract($1.presentationTime, CMTimeAdd($0.presentationTime, $0.duration))
        }
    }

    private func assertTimes(_ actual: [CMTime], _ expected: [CMTime], line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(CMTimeCompare(actual, expected), 0, line: line)
        }
    }
}
