import XCTest
import AppKit
@testable import SermonCut

private final class MemoryYouTubeSecrets: YouTubeSecretStorage {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data?, key: String) throws { values[key] = data }
}

private final class YouTubeMockProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var json = "{}"
        var error: URLError?
    }
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var replies: [Reply] = []
        var requests: [URLRequest] = []
        func reset(_ replies: [Reply]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; requests = [] }
        func next(_ request: URLRequest) -> Reply {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return replies.isEmpty ? Reply(error: URLError(.badServerResponse)) : replies.removeFirst()
        }
        func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }
    static let script = Script()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.script.next(request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class YouTubeTests: XCTestCase {
    @MainActor
    func testSubtitleCheckIsReadOnlyAndReportsMissingTracks() async throws {
        let defaults = UserDefaults(suiteName: "SubtitleDiagnosticTests")!
        let secrets = MemoryYouTubeSecrets()
        try secrets.write(JSONEncoder().encode(GoogleDesktopConfiguration(client_id: "test.apps.googleusercontent.com", client_secret: "test")), key: "configuration")
        try secrets.write(JSONEncoder().encode(GoogleConnection(accessToken: "test", refreshToken: "test", expiresAt: Date().addingTimeInterval(3600), channelID: "church", channelName: "Test")), key: "connection")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [YouTubeMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        YouTubeMockProtocol.script.reset([.init(json: #"{"items":[]}"#)])
        let store = YouTubeStore(secrets: secrets, defaults: defaults, session: session)
        store.checkSubtitles(videoID: "j6MdCr69OfE")
        for _ in 0..<500 {
            if !store.checkingSubtitles { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.checkingSubtitles)
        XCTAssertTrue(store.subtitleDiagnostic.contains("0 subtitle track(s)"), store.subtitleDiagnostic)
        let requests = YouTubeMockProtocol.script.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.url?.path, "/youtube/v3/captions")
    }

    @MainActor
    func testAcceptedSubtitleTrackMustBeReadyBeforeJobIsRemoved() async throws {
        let name = "SubtitleVerification-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "test.mp4")
        try Data([1]).write(to: video)
        let secrets = MemoryYouTubeSecrets()
        try secrets.write(JSONEncoder().encode(GoogleDesktopConfiguration(client_id: "test.apps.googleusercontent.com", client_secret: "test")), key: "configuration")
        try secrets.write(JSONEncoder().encode(GoogleConnection(accessToken: "test", refreshToken: "test", expiresAt: Date().addingTimeInterval(3600), channelID: "church", channelName: "Test")), key: "connection")
        let job = YouTubeUploadJob(draft: .init(title: "Test", description: "", visibility: .private),
            videoBookmark: try YouTubeFiles.bookmark(video), fileSize: 1, modifiedAt: Date(), channelID: "church",
            videoID: "j6MdCr69OfE", captionData: Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8))
        try secrets.write(JSONEncoder().encode(job), key: "uploadJob")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [YouTubeMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let channel = #"{"items":[{"id":"church","snippet":{"title":"Test"}}]}"#
        let pending = #"{"id":"track","snippet":{"videoId":"j6MdCr69OfE","language":"en","name":"English (SermonClip)","isDraft":false,"status":"syncing"}}"#
        let ready = pending.replacingOccurrences(of: "syncing", with: "serving")
        YouTubeMockProtocol.script.reset([
            .init(json: channel), .init(), .init(json: pending),
            .init(json: "{\"items\":[\(pending)]}"),
            .init(json: "{\"items\":[\(ready)]}"),
            .init(json: #"{"items":[{"status":{"privacyStatus":"private"}}]}"#)
        ])
        let store = YouTubeStore(secrets: secrets, defaults: defaults, session: session)
        store.resume()
        try await waitForIdle(store)
        XCTAssertNil(store.job)
        let posts = YouTubeMockProtocol.script.snapshot().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1, "The retry may insert the accepted subtitle once, but must not duplicate it.")
    }
    func testDesktopConfigurationAndPKCE() throws {
        let data = Data(#"{"installed":{"client_id":"example.apps.googleusercontent.com","client_secret":"test","token_uri":"https://untrusted.invalid"}}"#.utf8)
        XCTAssertEqual(try GoogleDesktopConfiguration.parse(data).client_id, "example.apps.googleusercontent.com")
        XCTAssertThrowsError(try GoogleDesktopConfiguration.parse(Data(#"{"web":{"client_id":"x","client_secret":"x"}}"#.utf8)))
        XCTAssertEqual(GoogleOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(GoogleOAuth.callback("/oauth?state=expected&code=hello", state: "expected"), "hello")
        XCTAssertNil(GoogleOAuth.callback("/oauth?state=wrong&code=hello", state: "expected"))
        XCTAssertNil(GoogleOAuth.callback("/oauth?state=expected&code=a&code=b", state: "expected"))
        XCTAssertNil(GoogleOAuth.callback("/other?state=expected&code=hello", state: "expected"))
        XCTAssertEqual(String(decoding: GoogleOAuth.form(["x": "a+b &c"]), as: UTF8.self), "x=a%2Bb%20%26c")
    }
    func testMetadataAndThumbnailValidation() throws {
        try YouTubeUploadDraft(title: "Sermon", description: "Trusted description", visibility: .public).validate()
        XCTAssertThrowsError(try YouTubeUploadDraft(title: "", description: "", visibility: .private).validate())
        XCTAssertThrowsError(try YouTubeUploadDraft(title: "Sermon", description: String(repeating: "é", count: 2501), visibility: .private).validate())
        XCTAssertThrowsError(try YouTubeThumbnail.validate(Data("Not a JPG".utf8)))
        XCTAssertThrowsError(try YouTubeThumbnail.validate(Data(repeating: 0, count: YouTubeThumbnail.maximumBytes + 1)))
    }
    @MainActor
    func testUploadRangeAndURLValidation() throws {
        XCTAssertEqual(try YouTubeStore.nextOffset(nil, total: 100), 0)
        XCTAssertEqual(try YouTubeStore.nextOffset("bytes=0-49", total: 100), 50)
        XCTAssertThrowsError(try YouTubeStore.nextOffset("bytes=0-100", total: 100))
        XCTAssertThrowsError(try YouTubeStore.nextOffset("bytes=20-49", total: 100))
        XCTAssertTrue(YouTubeStore.allowedUploadURL(URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=test")!))
        XCTAssertFalse(YouTubeStore.allowedUploadURL(URL(string: "https://www.googleapis.com.evil.invalid/upload/youtube/v3/videos")!))
        XCTAssertFalse(YouTubeStore.allowedUploadURL(URL(string: "http://www.googleapis.com/upload/youtube/v3/videos")!))
    }
    @MainActor
    func testDescriptionPresetsPersistWithoutChangingUploadDraft() throws {
        let name = "SermonClip.YouTubeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = YouTubeStore(secrets: MemoryYouTubeSecrets(), defaults: defaults)
        store.videoDescription = "Current draft"
        try store.savePreset(id: nil, name: "Sunday", text: "Template")
        let preset = try XCTUnwrap(store.presets.first)
        try store.savePreset(id: preset.id, name: "Sunday updated", text: "Updated")
        XCTAssertEqual(store.videoDescription, "Current draft")
        let restored = YouTubeStore(secrets: MemoryYouTubeSecrets(), defaults: defaults)
        XCTAssertEqual(restored.presets.first?.text, "Updated")
        XCTAssertFalse(restored.enabled)
        restored.deletePreset(preset)
        XCTAssertTrue(restored.presets.isEmpty)
    }
    @MainActor
    func testInterruptedUploadResumesExistingSessionAndReportsPrivateRestriction() async throws {
        let name = "SermonClip.YouTubeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "test.mp4")
        try Data(repeating: 7, count: 600_000).write(to: video)
        let secrets = MemoryYouTubeSecrets()
        try secrets.write(JSONEncoder().encode(GoogleDesktopConfiguration(client_id: "test.apps.googleusercontent.com", client_secret: "test")), key: "configuration")
        try secrets.write(JSONEncoder().encode(GoogleConnection(accessToken: "test-only-token", refreshToken: "test-only-refresh", expiresAt: Date().addingTimeInterval(3600), channelID: "church", channelName: "Test Church")), key: "connection")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [YouTubeMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let channel = #"{"items":[{"id":"church","snippet":{"title":"Test Church"}}]}"#
        YouTubeMockProtocol.script.reset([
            .init(json: channel),
            .init(headers: ["Location": "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=test"]),
            .init(status: 308),
            .init(error: URLError(.networkConnectionLost)),
            .init(json: channel),
            .init(status: 308, headers: ["Range": "bytes=0-262143"]),
            .init(status: 201, json: #"{"id":"test-video"}"#),
            .init(),
            .init(json: #"{"items":[{"status":{"privacyStatus":"private"}}]}"#)
        ])
        let store = YouTubeStore(secrets: secrets, defaults: defaults, session: session)
        try store.enqueue(video: video, draft: .init(title: "Test", description: "", visibility: .public), channelID: "church")
        try await waitForIdle(store)
        XCTAssertNotNil(store.job?.sessionURL)
        XCTAssertNil(store.job?.videoID)
        // Relaunch recovery: no automatic upload is triggered by initialization.
        let restored = YouTubeStore(secrets: secrets, defaults: defaults, session: session)
        XCTAssertFalse(restored.busy)
        restored.resume()
        try await waitForIdle(restored)
        XCTAssertNil(restored.job)
        XCTAssertEqual(restored.completedVideoID, "test-video")
        XCTAssertTrue(restored.status.contains("Private, not Public"), restored.status)
        let requests = YouTubeMockProtocol.script.snapshot()
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(requests.contains { $0.value(forHTTPHeaderField: "Content-Range") == "bytes 262144-599999/600000" })
    }
    @MainActor
    private func waitForIdle(_ store: YouTubeStore) async throws {
        for _ in 0..<500 {
            if !store.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Mock upload did not finish"); store.cancel()
    }

    @MainActor
    func testThumbnailFailureRetriesOnlyThumbnailForExistingVideo() async throws {
        let name = "SermonClip.YouTubeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "test.mp4"), thumbnail = root.appending(path: "test.jpg")
        try Data([1, 2, 3]).write(to: video)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3,
                                      hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        try YouTubeThumbnail.validate(jpeg)
        try jpeg.write(to: thumbnail)
        let secrets = MemoryYouTubeSecrets()
        try secrets.write(JSONEncoder().encode(GoogleDesktopConfiguration(client_id: "test.apps.googleusercontent.com", client_secret: "test")), key: "configuration")
        try secrets.write(JSONEncoder().encode(GoogleConnection(accessToken: "test", refreshToken: "test", expiresAt: Date().addingTimeInterval(3600), channelID: "church", channelName: "Test")), key: "connection")
        let draft = YouTubeUploadDraft(title: "Test", description: "", visibility: .private, thumbnailBookmark: try YouTubeFiles.bookmark(thumbnail))
        let job = YouTubeUploadJob(draft: draft, videoBookmark: try YouTubeFiles.bookmark(video), fileSize: 3, modifiedAt: Date(), channelID: "church", videoID: "existing-video")
        try secrets.write(JSONEncoder().encode(job), key: "uploadJob")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [YouTubeMockProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let channel = #"{"items":[{"id":"church","snippet":{"title":"Test"}}]}"#
        YouTubeMockProtocol.script.reset([
            .init(json: channel), .init(), .init(status: 403),
            .init(json: channel), .init(), .init(), .init(json: #"{"items":[{"status":{"privacyStatus":"private"}}]}"#)
        ])
        let store = YouTubeStore(secrets: secrets, defaults: defaults, session: session)
        store.resume(); try await waitForIdle(store)
        XCTAssertEqual(store.job?.videoID, "existing-video")
        XCTAssertEqual(store.job?.thumbnailDone, false)
        store.resume(); try await waitForIdle(store)
        XCTAssertNil(store.job)
        XCTAssertEqual(store.completedVideoID, "existing-video")
        let posts = YouTubeMockProtocol.script.snapshot().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0.url?.path == "/upload/youtube/v3/thumbnails/set" })
    }

    @MainActor
    func testExistingVideoIsAddedToSelectedPlaylistWithoutReuploading() async throws {
        let name = "SermonClip.YouTubeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "test.mp4")
        try Data(repeating: 7, count: 3).write(to: video)
        let secrets = MemoryYouTubeSecrets()
        try secrets.write(JSONEncoder().encode(GoogleDesktopConfiguration(client_id: "test.apps.googleusercontent.com", client_secret: "test")), key: "configuration")
        try secrets.write(JSONEncoder().encode(GoogleConnection(accessToken: "test", refreshToken: "test", expiresAt: Date().addingTimeInterval(3600), channelID: "church", channelName: "Test")), key: "connection")
        let playlistID = "PLchurch"
        let draft = YouTubeUploadDraft(title: "Test", description: "", visibility: .private, thumbnailBookmark: nil, playlistID: playlistID)
        let job = YouTubeUploadJob(draft: draft, videoBookmark: try YouTubeFiles.bookmark(video), fileSize: 3,
                                   modifiedAt: try video.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast,
                                   channelID: "church", videoID: "existing-video")
        try secrets.write(JSONEncoder().encode(job), key: "uploadJob")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [YouTubeMockProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        YouTubeMockProtocol.script.reset([
            .init(json: #"{"items":[{"id":"church","snippet":{"title":"Test"}}]}"#),
            .init(),
            .init(status: 200, json: #"{"id":"playlist-item"}"#),
            .init(json: #"{"items":[{"status":{"privacyStatus":"private"}}]}"#)
        ])
        let store = YouTubeStore(secrets: secrets, defaults: defaults, session: session)
        store.resume(); try await waitForIdle(store)
        XCTAssertNil(store.job)
        XCTAssertEqual(store.completedVideoID, "existing-video")
        let requests = YouTubeMockProtocol.script.snapshot()
        XCTAssertFalse(requests.contains { $0.url?.path == "/upload/youtube/v3/videos" })
        let playlistRequest = try XCTUnwrap(requests.first { $0.url?.path == "/youtube/v3/playlistItems" })
        XCTAssertEqual(playlistRequest.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
    }
}
