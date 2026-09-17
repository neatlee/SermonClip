import XCTest
@testable import SermonCut

final class ExportNameTests: XCTestCase {
    func testSharedNameAndCollisionAcrossFormats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Sunday.srt"))
        let locations = try MediaExporter.makeLocations(source: root.appendingPathComponent("service.mp4"), directory: root, name: " Sunday ")
        XCTAssertEqual(locations.video.lastPathComponent, "Sunday 2.mp4")
        XCTAssertEqual(locations.audio.lastPathComponent, "Sunday 2.mp3")
        XCTAssertEqual(locations.captions.lastPathComponent, "Sunday 2.srt")
    }

    func testUnsafeNamesAreRejected() {
        for name in ["", "   ", "../other", "folder/file", "bad:name", "line\nname", String(repeating: "x", count: 201)] {
            XCTAssertThrowsError(try MediaExporter.validatedExportName(name))
        }
    }
}
