import AVFoundation
import CoreGraphics
import XCTest
@testable import AnciiVideoGenerator

/// H3 — `import-asset-frames`. `testOrientedLumaMapPermutesSyntheticBytesExactly` proves the
/// D3 forward pixel-center map with an exact-byte assertion (safe: synthetic bytes, no
/// colorspace involved). `testAssetFrameExtractorDecodesRotatedFixtureWithCorrectCountDimsPTS`
/// proves the real `AVAssetReader` decode path against the existing rotated fixture with
/// count/dims/PTS assertions plus per-frame STRUCTURAL uniformity (never exact bytes —
/// YCbCr/BT.2020 round-trip through HEVC makes exact luma fragile).
final class AssetImportTests: XCTestCase {
    // MARK: - H3-010 RED: pure permutation, exact bytes safe (no colorspace involved)

    func testOrientedLumaMapPermutesSyntheticBytesExactly() {
        // 4×2 coded luma, row-major: [[0,1,2,3],[4,5,6,7]].
        let coded: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        // Fixture's exact transform: swaps axes (90°-equivalent), coded 4×2 → oriented 2×4.
        let transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        let map = OrientedLumaMap(codedWidth: 4, codedHeight: 2, preferredTransform: transform)

        XCTAssertEqual(map.orientedWidth, 2, "Transposed 4×2 coded rect MUST standardize to 2×4 oriented")
        XCTAssertEqual(map.orientedHeight, 4)

        let oriented = map.permute(coded)

        // Forward map per D3: pixel center (x+0.5, y+0.5) -> (y+0.5, x+0.5) under this transform,
        // floor, no clamp needed here. dest[x*2+y] = src[y*4+x] for every coded (x,y).
        XCTAssertEqual(oriented, [0, 4, 1, 5, 2, 6, 3, 7],
                       "Oriented buffer MUST be the exact D3 forward-mapped permutation of coded bytes")
    }

    // MARK: - H3-020 RED: real decode against the existing rotated fixture

    func testAssetFrameExtractorDecodesRotatedFixtureWithCorrectCountDimsPTS() async throws {
        let fixture = try MediaFixtureFactory().makeFixture()
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let asset = AVURLAsset(url: fixture.videoURL)
        let sources = try await AssetFrameExtractor.extract(from: asset, maximumDimension: 4_096)

        XCTAssertEqual(sources.count, 4, "Fixture writes exactly 4 samples")
        for source in sources {
            XCTAssertEqual(source.sourceWidth, 16, "Oriented width MUST match AssetValidator.orientedDimensions")
            XCTAssertEqual(source.sourceHeight, 32, "Oriented height MUST match AssetValidator.orientedDimensions")
            XCTAssertEqual(source.pixels.count, 16 * 32, "Oriented luma buffer MUST be tightly packed width×height")
        }

        // PTS MUST come from CMSampleBufferGetPresentationTimeStamp, never index * frameDuration —
        // this is what makes VFR spacing an observation rather than a restatement of a loop counter.
        XCTAssertEqual(sources.map(\.presentationTime), [0.0, 0.04, 0.08, 0.12])

        // Structural (not exact-byte) uniformity: the fixture writes a single solid brightness
        // per frame before HEVC round-trip, so decoded luma should cluster tightly around one value.
        for (index, source) in sources.enumerated() {
            let sum = source.pixels.reduce(0) { $0 + Int($1) }
            let average = Double(sum) / Double(source.pixels.count)
            for byte in source.pixels {
                XCTAssertLessThanOrEqual(abs(Double(byte) - average), 24,
                                         "Frame \(index) luma MUST be structurally uniform (avg \(average))")
            }
        }
    }
}
