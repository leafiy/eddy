import XCTest
@testable import eddy

final class SmokeTests: XCTestCase {
    func testQuickShareDefaultsAreNotConfigured() {
        XCTAssertFalse(AppSettings.defaults.quickShare.isConfigured)
    }

    func testSaveFormatValuesAreStable() {
        XCTAssertEqual(SaveFormat.keep.rawValue, "keep")
        XCTAssertEqual(SaveFormat.png.rawValue, "png")
        XCTAssertEqual(SaveFormat.jpeg.rawValue, "jpeg")
    }
}
