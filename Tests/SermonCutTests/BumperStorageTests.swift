import XCTest
@testable import SermonCut

final class BumperStorageTests: XCTestCase {
    func testDeletionRemovesOnlySelectedManagedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Logo.mp4")
        try Data("fixture".utf8).write(to: original)
        let storage = BumperStorage(root: root.appending(path: "library"))
        let opening = try storage.importCopy(from: original, kind: .opening)
        let closing = try storage.importCopy(from: original, kind: .closing)
        try storage.deleteCopy(of: opening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(storage.url(for: opening)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(storage.url(for: closing)).path))
    }
    func testCopySurvivesOriginalRemovalAndSameNamesDoNotCollide() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Logo.mp4")
        let data = Data("test fixture".utf8)
        try data.write(to: source)
        let storage = BumperStorage(root: root.appending(path: "library"))
        let first = try storage.importCopy(from: source, kind: .opening)
        let second = try storage.importCopy(from: source, kind: .opening)
        try FileManager.default.removeItem(at: source)
        XCTAssertNotEqual(storage.url(for: first), storage.url(for: second))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(storage.url(for: first))), data)
    }
}
