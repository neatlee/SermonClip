import XCTest
@testable import SermonCut

final class NoticeLifecycleTests: XCTestCase {
    @MainActor
    func testRoutineConfirmationExpiresButReviewAndErrorsRemain() async throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(defaults: defaults)
        store.report("Loaded", in: .source, dismissAfterSeconds: 0.02)
        store.report("Review alignment", in: .subtitles)
        store.report("Import failed", in: .bumpers, tone: .error, dismissAfterSeconds: 0.02)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(store.notices[.source])
        XCTAssertEqual(store.notices[.subtitles]?.text, "Review alignment")
        XCTAssertEqual(store.notices[.bumpers]?.text, "Import failed")
    }

    @MainActor
    func testOldTimerCannotDismissReplacementNotice() async throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(defaults: defaults)
        store.report("Saved", in: .bumpers, dismissAfterSeconds: 0.02)
        await Task.yield()
        store.report("New problem", in: .bumpers, tone: .error)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.notices[.bumpers]?.text, "New problem")
    }
}
