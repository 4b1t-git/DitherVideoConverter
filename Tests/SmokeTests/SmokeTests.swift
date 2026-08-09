import XCTest

final class SmokeTests: XCTestCase {
    func testBundleIsExecutable() {
        XCTAssertEqual(Bundle(for: Self.self).bundleURL.pathExtension, "xctest")
    }
}
