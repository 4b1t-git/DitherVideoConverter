import CryptoKit
import Metal
import XCTest
@testable import AnciiVideoGenerator

final class ErrorDiffusionSpikeTests: XCTestCase {
    private let fixtures: [(pixels: [UInt8], width: Int, height: Int)] = [
        ([0, 48, 96, 144, 192, 240, 32, 80, 128, 176, 224, 255], 6, 2),
        ([127, 128, 129, 64, 192, 16, 240, 96, 160, 32, 224, 80, 176, 48, 208], 5, 3),
    ]

    func testAtkinsonMatchesReferenceDeterministically() throws {
        try assertReferenceEquality(for: .atkinson)
    }

    func testFloydSteinbergMatchesReferenceDeterministically() throws {
        try assertReferenceEquality(for: .floydSteinberg)
    }

    func testAppleM5SustainsThirtyFramesPerSecondWithoutSubstitution() throws {
        XCTAssertEqual(sysctlString("machdep.cpu.brand_string"), "Apple M5")
        let renderer = try MetalErrorDiffusionSpike()
        let sourceWidth = 1_920
        let sourceHeight = 1_080
        let width = 64
        let height = 36
        let input = (0..<(sourceWidth * sourceHeight)).map {
            UInt8(truncatingIfNeeded: $0 &* 37 &+ 11)
        }
        let totalFrames = 1_800
        let measuredFrames = 1_740

        for algorithm in ErrorDiffusionAlgorithm.allCases {
            let expected = reference(
                adapt(input, sourceWidth, sourceHeight, width, height), width, height, algorithm
            )
            XCTAssertEqual(
                try renderer.renderAdaptive(input, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                            width: width, height: height, algorithm: algorithm),
                expected,
                "Adaptive resolution must retain the selected exact algorithm"
            )
            for _ in 0..<60 {
                _ = try renderer.renderAdaptive(input, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                                width: width, height: height, algorithm: algorithm)
            }
            var digest = SHA256()
            let start = ContinuousClock.now
            for _ in 60..<totalFrames {
                digest.update(data: Data(try renderer.renderAdaptive(
                    input, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                    width: width, height: height, algorithm: algorithm
                )))
            }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let fps = Double(measuredFrames) / seconds
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()

            XCTAssertGreaterThanOrEqual(fps, 30)
            print("M5_ONLY algorithm=\(algorithm) source=1920x1080@30 duration=60s "
                + "measured=2-60s adaptive=\(width)x\(height) frames=\(measuredFrames) "
                + "elapsed=\(String(format: "%.6f", seconds)) fps=\(String(format: "%.2f", fps)) "
                + "hash=\(hash) device=\(renderer.deviceName) model=\(sysctlString("hw.model")) "
                + "candidate=unit2-uncommitted scope=Apple-M5-only-not-M1-or-older")
        }
    }

    private func assertReferenceEquality(for algorithm: ErrorDiffusionAlgorithm) throws {
        let renderer = try MetalErrorDiffusionSpike()
        for fixture in fixtures {
            let expected = reference(fixture.pixels, fixture.width, fixture.height, algorithm)
            let first = try renderer.render(
                fixture.pixels, width: fixture.width, height: fixture.height, algorithm: algorithm
            )
            let second = try renderer.render(
                fixture.pixels, width: fixture.width, height: fixture.height, algorithm: algorithm
            )
            XCTAssertEqual(first, expected)
            XCTAssertEqual(second, expected)
            print("REFERENCE algorithm=\(algorithm) size=\(fixture.width)x\(fixture.height) "
                + "hash=\(SHA256.hash(data: Data(expected)).map { String(format: "%02x", $0) }.joined())")
        }
    }

    private func adapt(
        _ pixels: [UInt8], _ sourceWidth: Int, _ sourceHeight: Int, _ width: Int, _ height: Int
    ) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                pixels[(y * sourceHeight / height) * sourceWidth + x * sourceWidth / width]
            }
        }
    }

    private func reference(
        _ pixels: [UInt8], _ width: Int, _ height: Int, _ algorithm: ErrorDiffusionAlgorithm
    ) -> [UInt8] {
        var work = pixels.map { Int($0) * 16 }
        var output = [UInt8](repeating: 0, count: pixels.count)
        func add(_ x: Int, _ y: Int, _ value: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            work[y * width + x] += value
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let quantized = work[index] >= 128 * 16 ? 255 : 0
                output[index] = UInt8(quantized)
                let error = work[index] - quantized * 16
                if algorithm == .atkinson {
                    let eighth = error / 8
                    for offset in [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] {
                        add(x + offset.0, y + offset.1, eighth)
                    }
                } else {
                    add(x + 1, y, error * 7 / 16)
                    add(x - 1, y + 1, error * 3 / 16)
                    add(x, y + 1, error * 5 / 16)
                    add(x + 1, y + 1, error / 16)
                }
            }
        }
        return output
    }

    private func sysctlString(_ key: String) -> String {
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &value, &size, nil, 0)
        return String(cString: value)
    }
}
