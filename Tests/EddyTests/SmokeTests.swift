import XCTest
@testable import eddy

final class SmokeTests: XCTestCase {
    func testQuickShareDefaultsAreNotConfigured() {
        let settings = QuickShareSettings(
            provider: .s3Compatible,
            endpointURL: "",
            region: "",
            bucket: "",
            accessKeyID: "",
            secretAccessKey: "",
            keyPrefix: "eddy"
        )
        XCTAssertFalse(settings.isConfigured)
    }

    func testSaveFormatValuesAreStable() {
        XCTAssertEqual(SaveFormat.keep.rawValue, "keep")
        XCTAssertEqual(SaveFormat.png.rawValue, "png")
        XCTAssertEqual(SaveFormat.jpeg.rawValue, "jpeg")
    }
}
