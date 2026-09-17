import XCTest
@testable import SermonCut

final class AppResourceTests: XCTestCase {
    func testBothSidebarLogosAreAvailable() throws {
        for name in ["SermonClip-Lightmode-Logo", "SermonClip-Darkmode-Logo"] {
            let url = try XCTUnwrap(AppResources.url(forResource: name, withExtension: "png"))
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path))
        }
    }

    func testBundledEncoderIsExecutable() throws {
        let url = try XCTUnwrap(AppResources.url(forResource: "ffmpeg", withExtension: nil,
                                                subdirectory: "Resources/Tools"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
    }
}
