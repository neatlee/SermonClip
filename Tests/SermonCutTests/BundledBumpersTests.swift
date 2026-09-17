import XCTest
@testable import SermonCut

final class BundledBumpersTests: XCTestCase {
    func testNewLibraryGetsBothDefaultsAndNeverReinstallsDeletedBumpers() throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appending(path: "SCB-Bumper.mp4")
        let bytes = Data("fixture".utf8)
        try bytes.write(to: source)
        let storage = BumperStorage(root: root.appending(path: "library"))
        try BundledBumpers.installIfNeeded(source: source, defaults: defaults, storage: storage, bumperKey: "bumpers", preferencesKey: "preferences")
        let bumpers = try JSONDecoder().decode([Bumper].self, from: XCTUnwrap(defaults.data(forKey: "bumpers")))
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: XCTUnwrap(defaults.data(forKey: "preferences")))
        XCTAssertEqual(bumpers.count, 2)
        XCTAssertEqual(preferences.defaultOpeningID, bumpers.first { $0.kind == .opening }?.id)
        XCTAssertEqual(preferences.defaultClosingID, bumpers.first { $0.kind == .closing }?.id)
        try FileManager.default.removeItem(at: source)
        for bumper in bumpers {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(storage.url(for: bumper))), bytes)
            XCTAssertTrue(bumper.isBundled)
            XCTAssertThrowsError(try storage.deleteCopy(of: bumper))
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(storage.url(for: bumper)).path))
        }
        let empty = try JSONEncoder().encode([Bumper]())
        defaults.set(empty, forKey: "bumpers")
        try BundledBumpers.installIfNeeded(source: source, defaults: defaults, storage: storage, bumperKey: "bumpers", preferencesKey: "preferences")
        XCTAssertEqual(defaults.data(forKey: "bumpers"), empty)
    }

    func testExistingBundledCopiesAreProtectedWithoutChangingNamesOrPreferences() throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appending(path: "SCB-Bumper.mp4")
        try Data("bundled fixture".utf8).write(to: source)
        let storage = BumperStorage(root: root.appending(path: "library"))
        var opening = try storage.importCopy(from: source, kind: .opening)
        opening.name = "Renamed Church Intro"
        let closing = try storage.importCopy(from: source, kind: .closing)
        try Data("different user video".utf8).write(to: source)
        let userBumper = try storage.importCopy(from: source, kind: .opening)
        try Data("bundled fixture".utf8).write(to: source)
        let original = [opening, closing, userBumper]
        var preferences = AppPreferences()
        preferences.defaultOpeningID = userBumper.id
        let preferenceData = try JSONEncoder().encode(preferences)
        defaults.set(try JSONEncoder().encode(original), forKey: "bumpers")
        defaults.set(preferenceData, forKey: "preferences")
        defaults.set(true, forKey: BundledBumpers.installedKey)
        for _ in 0..<2 {
            try BundledBumpers.installIfNeeded(source: source, defaults: defaults, storage: storage,
                bumperKey: "bumpers", preferencesKey: "preferences")
        }
        let updated = try JSONDecoder().decode([Bumper].self, from: XCTUnwrap(defaults.data(forKey: "bumpers")))
        XCTAssertEqual(updated.map(\.id), original.map(\.id))
        XCTAssertEqual(updated.map(\.name), original.map(\.name))
        XCTAssertEqual(updated.map(\.isBundled), [true, true, false])
        XCTAssertEqual(defaults.data(forKey: "preferences"), preferenceData)
        XCTAssertThrowsError(try storage.deleteCopy(of: updated[0]))
        try storage.deleteCopy(of: updated[2])
    }

    func testExistingLibraryAndPreferencesArePreserved() throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = try JSONEncoder().encode([Bumper]())
        let preferences = try JSONEncoder().encode(AppPreferences())
        defaults.set(existing, forKey: "bumpers")
        defaults.set(preferences, forKey: "preferences")
        // Nonexistent source ensures no copy is attempted for existing users.
        try BundledBumpers.installIfNeeded(source: URL(fileURLWithPath: "/missing/SCB-Bumper.mp4"), defaults: defaults,
            storage: BumperStorage(), bumperKey: "bumpers", preferencesKey: "preferences")
        XCTAssertEqual(defaults.data(forKey: "bumpers"), existing)
        XCTAssertEqual(defaults.data(forKey: "preferences"), preferences)
    }
}
