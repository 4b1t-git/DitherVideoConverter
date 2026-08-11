import AVFoundation
import CoreGraphics
import XCTest
@testable import AnciiVideoGenerator

final class AssetValidatorTests: XCTestCase {
    func testValidFixtureIsSupportedWithOrientedDimensionsAndSourceUnchanged() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let report = await AssetValidator.validate(AVURLAsset(url: fixture.videoURL), maximumDimension: 4_096)
        XCTAssertTrue(report.isSupported, "Supported fixture MUST validate; summary: \(report.summary)")
        XCTAssertNil(report.violation)
        XCTAssertEqual(report.orientedWidth, 16, "Rotated fixture oriented width is 16")
        XCTAssertEqual(report.orientedHeight, 32, "Rotated fixture oriented height is 32")
        XCTAssertTrue(report.sourceUnchanged, "Validation MUST NOT resize or alter source media")
    }

    func testConstraintMatrixReportsActionableReasonForEachUnsupportedInput() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        await assertViolation(AVURLAsset(url: URL(string: "https://example.com/x.mov")!), .streaming)
        let missing = AVURLAsset(url: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).mov"))
        let unreadableReport = await AssetValidator.validate(missing, maximumDimension: 4_096)
        XCTAssertFalse(unreadableReport.isSupported, "Missing file MUST NOT validate")
        if case let .unreadable(reason) = unreadableReport.violation { XCTAssertFalse(reason.isEmpty, "Unreadable summary MUST be actionable") }
        else { XCTFail("Expected .unreadable; got \(String(describing: unreadableReport.violation))") }
        await assertViolation(AVURLAsset(url: fixture.audioURL), .zeroVideo)
        await assertViolation(composition(videoCount: 2, audioCount: 0), .multipleVideo)
        await assertViolation(composition(videoCount: 1, audioCount: 2), .multipleAudio)
        await assertViolation(AVURLAsset(url: fixture.videoURL), .unsupportedDimensions(width: 16, height: 32), maximumDimension: 8)
    }

    func testNonfiniteAndOverflowDimensionsAreRejectedWithoutResizing() throws {
        XCTAssertThrowsError(
            try AssetValidator.orientedDimensions(naturalSize: CGSize(width: CGFloat.nan, height: 16),
                                                  preferredTransform: .identity, maximumDimension: 4_096)
        ) { XCTAssertEqual($0 as? AssetValidationError, .nonfiniteDimensions) }
        XCTAssertThrowsError(
            try AssetValidator.orientedDimensions(naturalSize: CGSize(width: CGFloat.infinity, height: 16),
                                                  preferredTransform: .identity, maximumDimension: 4_096)
        ) { XCTAssertEqual($0 as? AssetValidationError, .nonfiniteDimensions) }
        XCTAssertThrowsError(
            try AssetValidator.orientedDimensions(naturalSize: CGSize(width: 5_000_000_000, height: 5_000_000_000),
                                                  preferredTransform: .identity, maximumDimension: 4_096)
        ) { XCTAssertEqual($0 as? AssetValidationError, .overflowDimensions) }
        let oriented = try AssetValidator.orientedDimensions(naturalSize: CGSize(width: 32, height: 16),
                                                              preferredTransform: .identity, maximumDimension: 4_096)
        XCTAssertEqual(oriented.width, 32)
        XCTAssertEqual(oriented.height, 16)
    }

    private func assertViolation(_ asset: AVAsset, _ expected: AssetValidationError,
                                 maximumDimension: Int = 4_096, line: UInt = #line) async {
        let report = await AssetValidator.validate(asset, maximumDimension: maximumDimension)
        XCTAssertFalse(report.isSupported, "Unsupported input MUST not validate; got \(report.summary)", line: line)
        XCTAssertEqual(report.violation, expected, "Violation MUST name the broken constraint; got \(String(describing: report.violation))", line: line)
        XCTAssertFalse(report.summary.isEmpty, "Violation summary MUST be an actionable reason", line: line)
    }

    private func composition(videoCount: Int, audioCount: Int) -> AVMutableComposition {
        let result = AVMutableComposition()
        for _ in 0..<videoCount {
            _ = result.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        for _ in 0..<audioCount {
            _ = result.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        return result
    }
}