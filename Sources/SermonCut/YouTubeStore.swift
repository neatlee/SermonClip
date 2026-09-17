import AppKit
import Foundation
import SwiftUI

private final class NoYouTubeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // In particular, 308 is resumable-upload status, not a redirect.
    }
}

@MainActor
final class YouTubeStore: ObservableObject {
    @Published var enabled = false // Deliberately not remembered across app launches.
    @Published var title = ""
    @Published var videoDescription = ""
    @Published var visibility: YouTubeVisibility = .private
    @Published var playlistID: String?
    @Published private(set) var thumbnailName: String?
    @Published private(set) var thumbnailPreview: NSImage?
    @Published private(set) var presets: [DescriptionPreset] = []
    @Published private(set) var connection: GoogleConnection?
    @Published private(set) var configured = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Import your Google Desktop app JSON to begin."
    @Published private(set) var notices: [YouTubeArea: ProjectNotice] = [:]
    private var noticeDismissalTasks: [YouTubeArea: Task<Void, Never>] = [:]
    func report(_ text: String, in area: YouTubeArea, tone: NoticeTone = .normal, dismissAfterSeconds: Double? = nil) {
        noticeDismissalTasks[area]?.cancel()
        noticeDismissalTasks[area] = nil
        status = text
        let notice = ProjectNotice(text: text, tone: tone)
        notices[area] = notice
        guard tone == .normal, let seconds = dismissAfterSeconds else { return }
        noticeDismissalTasks[area] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard !Task.isCancelled, let self, self.notices[area]?.id == notice.id else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.notices[area] = nil
            }
            self.noticeDismissalTasks[area] = nil
        }
    }
    @Published private(set) var progress = 0.0
    @Published private(set) var estimate = ""
    @Published private(set) var job: YouTubeUploadJob?
    @Published private(set) var completedVideoID: String?
    @Published private(set) var playlists: [YouTubePlaylist] = []
    @Published private(set) var playlistsLoading = false
    @Published private(set) var checkingSubtitles = false
    @Published private(set) var subtitleDiagnostic = ""

    struct CaptionTrack: Decodable {
        struct Snippet: Decodable {
            let videoId: String
            let language: String
            let name: String
            let isDraft: Bool?
            let status: String?
            let failureReason: String?
        }
        let id: String
        let snippet: Snippet
    }
    private struct CaptionList: Decodable { let items: [CaptionTrack] }

    private func captionTracks(videoID: String) async throws -> [CaptionTrack] {
        let (data, response) = try await authorized("https://www.googleapis.com/youtube/v3/captions?part=snippet&videoId=\(videoID)")
        try requireSuccess(response, data)
        return try JSONDecoder().decode(CaptionList.self, from: data).items
    }

    func checkSubtitles(videoID: String) {
        guard !checkingSubtitles, !busy, connection != nil else { return }
        let id = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            subtitleDiagnostic = "Enter the 11-character YouTube video ID."
            return
        }
        checkingSubtitles = true
        subtitleDiagnostic = "Checking subtitle tracks on YouTube…"
        Task {
            defer { checkingSubtitles = false }
            do {
                let tracks = try await captionTracks(videoID: id)
                var lines = ["Video ID: \(id)", "YouTube returned \(tracks.count) subtitle track(s)."]
                for track in tracks {
                    lines.append("Track: \(track.id)\nName: \(track.snippet.name)\nLanguage: \(track.snippet.language)\nDraft: \(track.snippet.isDraft.map { $0 ? "yes" : "no" } ?? "not reported")\nProcessing: \(track.snippet.status ?? "not reported")\nFailure reason: \(track.snippet.failureReason ?? "none reported")")
                }
                if let job, job.videoID == id {
                    lines.append("Saved retry: SRT payload \(job.captionData?.count ?? 0) bytes; upload marked accepted: \(job.captionDone).")
                } else if let receipt = defaults.dictionary(forKey: "SermonClip.lastSubtitleUploadEvidence"),
                          receipt["videoID"] as? String == id {
                    lines.append("Recorded upload: SRT payload \(receipt["srtBytes"] as? Int ?? 0) bytes. Track ID: \(receipt["trackID"] as? String ?? "not recorded").")
                } else {
                    lines.append("No matching saved retry record. This build cannot determine whether an earlier upload included SRT data.")
                }
                subtitleDiagnostic = lines.joined(separator: "\n\n")
            } catch {
                subtitleDiagnostic = "Subtitle check failed for \(id): \(error.localizedDescription)"
            }
        }
    }
    private var thumbnailBookmark: Data?
    private var configuration: GoogleDesktopConfiguration?
    private var task: Task<Void, Never>?
    private var loopback: GoogleLoopback?
    private let secrets: any YouTubeSecretStorage
    private let defaults: UserDefaults
    private let session: URLSession
    private let presetKey = "SermonClip.descriptionPresets.v1"
    private let legacyPresetKey = "Pulpit.descriptionPresets.v1"

    init(secrets: any YouTubeSecretStorage = YouTubeKeychain(), defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.secrets = secrets; self.defaults = defaults
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoYouTubeRedirects(), delegateQueue: nil)
        do {
            var bundledConfigurationWasUpdated = false
            let bundled: GoogleDesktopConfiguration? = {
                guard let bundledURL = AppResources.url(forResource: "StoneyCreekGoogleConfiguration", withExtension: "json"),
                      let data = try? Data(contentsOf: bundledURL),
                      let parsed = try? GoogleDesktopConfiguration.parse(data) else { return nil }
                return parsed
            }()
            configuration = try read("configuration")
            if let bundled {
                if let stored = configuration {
                    // The packaged Stoney Creek build is managed by the app. When
                    // its embedded OAuth client changes, silently migrate the
                    // stored configuration and require a fresh channel sign-in.
                    // Restrict this behavior to the real app defaults domain so
                    // isolated test stores never consume the bundled credentials.
                    if defaults === UserDefaults.standard && stored != bundled {
                        try save(bundled, "configuration")
                        try secrets.write(nil, key: "connection")
                        configuration = bundled
                        bundledConfigurationWasUpdated = true
                    }
                } else {
                    try save(bundled, "configuration")
                    configuration = bundled
                }
            }
            connection = try read("connection")
            job = try read("uploadJob")
            configured = configuration != nil
            report(job != nil ? "An unfinished upload is saved. Resume it when ready." : bundledConfigurationWasUpdated ? "Built-in Google configuration updated. Reconnect your YouTube channel." : connection != nil ? "YouTube connected." : configured ? "Configuration imported. Connect your channel." : status, in: .account, tone: job != nil ? .warning : .normal)
        } catch { report(error.localizedDescription, in: .account, tone: .error) }
        presets = loadPresetsWithMigration()
        if job != nil { report("An unfinished upload is saved. Resume it when ready.", in: .upload, tone: .warning) }
    }

    private func read<T: Decodable>(_ key: String) throws -> T? {
        guard let data = try secrets.read(key) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func save<T: Encodable>(_ value: T, _ key: String) throws { try secrets.write(JSONEncoder().encode(value), key: key) }

    private func loadPresetsWithMigration() -> [DescriptionPreset] {
        if let data = defaults.data(forKey: presetKey),
           let decoded = try? JSONDecoder().decode([DescriptionPreset].self, from: data) {
            return decoded
        }
        // The bundle identifier changed from local.pulpit.development to
        // local.sermonclip.development. Migrate only the user's standard domain;
        // injected test stores must remain isolated from the real account.
        guard defaults === UserDefaults.standard,
              let legacyDefaults = UserDefaults(suiteName: "local.pulpit.development"),
              let data = legacyDefaults.data(forKey: legacyPresetKey),
              let decoded = try? JSONDecoder().decode([DescriptionPreset].self, from: data) else {
            return []
        }
        defaults.set(data, forKey: presetKey)
        return decoded
    }

    func importConfiguration(_ url: URL) {
        guard !busy, job == nil else { report("Finish or discard the pending upload before replacing the configuration.", in: .account, tone: .warning); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 100_000 else { throw YouTubeFailure(message: "This is not a Google Desktop app configuration file.") }
            let parsed = try GoogleDesktopConfiguration.parse(Data(contentsOf: url))
            try secrets.write(nil, key: "connection")
            connection = nil
            try save(parsed, "configuration")
            configuration = parsed; configured = true
            report("Google configuration saved in Keychain. Connect your YouTube channel next.", in: .account, tone: .normal)
        } catch { report(error.localizedDescription, in: .account, tone: .error) }
    }

    func connect() {
        guard !busy, let configuration else { return }
        busy = true
        report("Complete Google sign-in in your browser. Choose the church channel if prompted.", in: .account, tone: .normal)
        task = Task {
            defer { busy = false; loopback?.cancel(); loopback = nil; task = nil }
            do {
                let state = try GoogleOAuth.random(), verifier = try GoogleOAuth.random()
                let receiver = GoogleLoopback(state: state); loopback = receiver
                let port = try await receiver.start()
                let redirect = "http://127.0.0.1:\(port)/oauth"
                var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                auth.queryItems = ["client_id": configuration.client_id, "redirect_uri": redirect, "response_type": "code",
                                   "scope": GoogleOAuth.scopes, "access_type": "offline", "prompt": "consent select_account",
                                   "state": state, "code_challenge": GoogleOAuth.challenge(verifier), "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
                guard NSWorkspace.shared.open(auth.url!) else { throw YouTubeFailure(message: "Could not open Google's sign-in page.") }
                let code = try await receiver.code()
                try Task.checkCancellation()
                let token = try await tokenRequest(["client_id": configuration.client_id, "client_secret": configuration.client_secret,
                                                   "code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"])
                guard let refresh = token.refresh_token else { throw YouTubeFailure(message: "Google did not grant offline access. Reconnect and approve the requested access.") }
                var candidate = GoogleConnection(accessToken: token.access_token, refreshToken: refresh,
                                                 expiresAt: Date().addingTimeInterval(token.expires_in), channelID: "", channelName: "")
                let (data, response) = try await raw("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true", token: candidate.accessToken)
                try requireSuccess(response, data)
                let channels = try JSONDecoder().decode(ChannelList.self, from: data)
                guard channels.items.count == 1, let channel = channels.items.first else {
                    throw YouTubeFailure(message: "Google did not identify exactly one channel. Reconnect and select the church's channel account.")
                }
                if let job, job.channelID != channel.id { throw YouTubeFailure(message: "This pending upload belongs to a different channel. Connect the original channel to resume it.") }
                candidate.channelID = channel.id; candidate.channelName = channel.snippet.title
                try save(candidate, "connection"); connection = candidate
                report("Connected to \(candidate.channelName).", in: .account, tone: .normal)
                loadPlaylists()
            } catch { report(error is CancellationError ? "Sign-in cancelled." : error.localizedDescription, in: .account, tone: .error) }
        }
    }

    func disconnect() {
        guard !busy, job == nil else { report("Finish or discard the pending upload first.", in: .account, tone: .warning); return }
        do {
            try secrets.write(nil, key: "connection"); connection = nil; enabled = false; playlistID = nil; playlists = []
            report("Disconnected on this Mac. To revoke Google's grant too, remove SermonClip in your Google Account's third-party connections.", in: .account, tone: .normal)
        } catch { report(error.localizedDescription, in: .account, tone: .error) }
    }
    func cancel() {
        task?.cancel()
        loopback?.cancel()
        // Closing the browser does not produce an OAuth callback. Release the
        // busy state immediately so the user can reconnect without restarting.
        busy = false
        task = nil
        loopback = nil
        report("Sign-in cancelled. You can reconnect when ready.", in: .account, tone: .warning)
    }

    func selectThumbnail(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try YouTubeFiles.bookmark(url)
            let data = try YouTubeFiles.thumbnail(bookmark)
            thumbnailBookmark = bookmark; thumbnailName = url.lastPathComponent; thumbnailPreview = NSImage(data: data)
            report("Thumbnail selected.", in: .thumbnail, dismissAfterSeconds: 10)
        } catch { report(error.localizedDescription, in: .thumbnail, tone: .error) }
    }
    func removeThumbnail() { thumbnailBookmark = nil; thumbnailName = nil; thumbnailPreview = nil; notices[.thumbnail] = nil }
    func savePreset(id: UUID?, name: String, text: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw YouTubeFailure(message: "Give the preset a name.") }
        try YouTubeUploadDraft(title: "Preset", description: text, visibility: .private).validate()
        var next = presets
        if let id, let index = next.firstIndex(where: { $0.id == id }) { next[index].name = name; next[index].text = text }
        else { next.append(DescriptionPreset(name: name, text: text)) }
        defaults.set(try JSONEncoder().encode(next), forKey: presetKey); presets = next
    }
    func deletePreset(_ preset: DescriptionPreset) {
        let next = presets.filter { $0.id != preset.id }
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: presetKey); presets = next }
    }
    func snapshot() throws -> YouTubeUploadDraft {
        guard connection != nil, !busy, job == nil else { throw YouTubeFailure(message: "Connect YouTube and finish or discard any pending upload before starting a new one.") }
        if let playlistID, !playlists.contains(where: { $0.id == playlistID }) {
            throw YouTubeFailure(message: "Refresh the playlist list before exporting; the selected playlist is no longer available.")
        }
        let draft = YouTubeUploadDraft(title: title, description: videoDescription, visibility: visibility,
                                       thumbnailBookmark: thumbnailBookmark, playlistID: playlistID)
        try draft.validate()
        if let bookmark = draft.thumbnailBookmark { _ = try YouTubeFiles.thumbnail(bookmark) }
        return draft
    }

    func loadPlaylists() {
        guard connection != nil, !playlistsLoading else { return }
        playlistsLoading = true
        Task { @MainActor in
            defer { playlistsLoading = false }
            do {
                let loaded = try await fetchPlaylists()
                playlists = loaded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                if let playlistID, !playlists.contains(where: { $0.id == playlistID }) { self.playlistID = nil }
                report(playlists.isEmpty ? "No playlists found on this channel." : "Loaded \(playlists.count) YouTube playlist\(playlists.count == 1 ? "" : "s").", in: .playlists, tone: .normal, dismissAfterSeconds: 10)
            } catch { report("Could not load YouTube playlists: \(error.localizedDescription)", in: .playlists, tone: .error) }
        }
    }

    func enqueue(video: URL, captions: URL? = nil, draft: YouTubeUploadDraft, channelID: String) throws {
        guard !busy, job == nil, connection?.channelID == channelID else { throw YouTubeFailure(message: "The YouTube connection changed. Your local export is safe; reconnect before uploading.") }
        let info = try video.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let captionData = try captions.map { try Data(contentsOf: $0) }
        var item = YouTubeUploadJob(draft: draft, videoBookmark: try YouTubeFiles.bookmark(video), fileSize: Int64(info.fileSize ?? 0),
                                   modifiedAt: info.contentModificationDate ?? .distantPast, channelID: channelID)
        item.captionData = captionData
        try save(item, "uploadJob"); job = item
        resume()
    }
    func discardPending() {
        guard !busy else { return }
        do {
            try secrets.write(nil, key: "uploadJob")
            job = nil
            report("Retry record discarded. Local files and any video already on YouTube were not deleted.", in: .upload, tone: .normal, dismissAfterSeconds: 10)
            report(connection != nil ? "YouTube connected." : configured ? "Configuration imported. Connect your channel." : "Import your Google Desktop app JSON to begin.", in: .account, tone: .normal)
        }
        catch { report(error.localizedDescription, in: .upload, tone: .error) }
    }
    func resume() {
        guard !busy, job != nil, connection != nil else { return }
        busy = true; progress = 0; estimate = "Estimating upload time…"; completedVideoID = nil
        task = Task {
            defer { busy = false; task = nil }
            do { try await performUpload() }
            catch { report(error is CancellationError || (error as? URLError)?.code == .cancelled ? "Upload paused. Resume when ready; an already uploaded video is not deleted." : "Upload needs attention: \(error.localizedDescription) Local exports are safe. Resume retries the saved step, not the export.", in: .upload, tone: .error) }
        }
    }

    private func performUpload() async throws {
        guard var current = job, current.channelID == connection?.channelID else { throw YouTubeFailure(message: "Connect the original upload channel.") }
        let video = try YouTubeFiles.resolve(current.videoBookmark)
        let scoped = video.startAccessingSecurityScopedResource()
        defer { if scoped { video.stopAccessingSecurityScopedResource() } }
        // Check the channel before any write, not merely the locally cached name.
        let (channelData, channelResponse) = try await authorized("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true")
        try requireSuccess(channelResponse, channelData)
        guard try JSONDecoder().decode(ChannelList.self, from: channelData).items.map(\.id) == [current.channelID] else {
            throw YouTubeFailure(message: "Google's current channel does not match this upload. Reconnect the correct channel.")
        }
        if current.videoID == nil {
            let info = try video.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard Int64(info.fileSize ?? 0) == current.fileSize, info.contentModificationDate == current.modifiedAt, current.fileSize > 0 else {
                throw YouTubeFailure(message: "The exported MP4 changed or is missing. It cannot safely resume this upload.")
            }
            if current.sessionURL == nil {
                report("Starting YouTube upload (\(current.draft.visibility.title))…", in: .upload, tone: .normal)
                let metadata: [String: Any] = ["snippet": ["title": current.draft.title, "description": current.draft.description,
                                                         "categoryId": "22", "defaultLanguage": "en"],
                                               "status": ["privacyStatus": current.draft.visibility.rawValue]]
                let (data, response) = try await authorized("https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status", method: "POST",
                    body: JSONSerialization.data(withJSONObject: metadata), headers: ["Content-Type": "application/json; charset=UTF-8",
                    "X-Upload-Content-Type": "video/mp4", "X-Upload-Content-Length": String(current.fileSize)])
                try requireSuccess(response, data)
                guard let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location), Self.allowedUploadURL(url) else {
                    throw YouTubeFailure(message: "Google did not return a valid resumable upload address.")
                }
                current.sessionURL = url; try persist(current)
            }
            guard let url = current.sessionURL, Self.allowedUploadURL(url) else { throw YouTubeFailure(message: "Invalid saved upload session.") }
            let (probe, response) = try await authorized(url.absoluteString, method: "PUT", body: Data(), headers: ["Content-Range": "bytes */\(current.fileSize)"])
            if response.statusCode == 200 || response.statusCode == 201 {
                current.videoID = try JSONDecoder().decode(VideoResult.self, from: probe).id; try persist(current)
            } else {
                guard response.statusCode == 308 else { try requireSuccess(response, probe); throw YouTubeFailure(message: "Unexpected upload status.") }
                var offset = try Self.nextOffset(response.value(forHTTPHeaderField: "Range"), total: current.fileSize)
                let handle = try FileHandle(forReadingFrom: video)
                defer { try? handle.close() }
                let began = Date(), initialOffset = offset
                while offset < current.fileSize {
                    try Task.checkCancellation()
                    try handle.seek(toOffset: UInt64(offset))
                    let bytes = try handle.read(upToCount: Int(min(4 * 1024 * 1024, current.fileSize - offset))) ?? Data()
                    guard !bytes.isEmpty else { throw YouTubeFailure(message: "Could not read the next part of the MP4.") }
                    report("Uploading to YouTube (\(current.draft.visibility.title))…", in: .upload, tone: .normal)
                    let (data, reply) = try await authorized(url.absoluteString, method: "PUT", body: bytes,
                        headers: ["Content-Type": "video/mp4", "Content-Range": "bytes \(offset)-\(offset + Int64(bytes.count) - 1)/\(current.fileSize)"])
                    if reply.statusCode == 200 || reply.statusCode == 201 {
                        current.videoID = try JSONDecoder().decode(VideoResult.self, from: data).id; try persist(current)
                        progress = 1; break
                    }
                    guard reply.statusCode == 308 else { try requireSuccess(reply, data); throw YouTubeFailure(message: "Unexpected upload status.") }
                    let next = try Self.nextOffset(reply.value(forHTTPHeaderField: "Range"), total: current.fileSize)
                    guard next > offset, next <= offset + Int64(bytes.count) else { throw YouTubeFailure(message: "Upload made no confirmed progress. Resume to check Google's saved position.") }
                    offset = next; progress = Double(offset) / Double(current.fileSize)
                    let elapsed = Date().timeIntervalSince(began)
                    if elapsed > 3, offset > initialOffset {
                        let remaining = elapsed * Double(current.fileSize - offset) / Double(offset - initialOffset)
                        estimate = "About \(Int(ceil(remaining / 60))) min remaining in upload"
                    }
                }
            }
        }
        guard let id = current.videoID else { throw YouTubeFailure(message: "Upload completion is not confirmed. Resume to query the existing session.") }
        completedVideoID = id
        var evidence: [String: Any] = ["videoID": id, "srtBytes": current.captionData?.count ?? 0]
        if let previous = defaults.dictionary(forKey: "SermonClip.lastSubtitleUploadEvidence"),
           previous["videoID"] as? String == id, let trackID = previous["trackID"] {
            evidence["trackID"] = trackID
        }
        defaults.set(evidence, forKey: "SermonClip.lastSubtitleUploadEvidence")
        // Explicitly set the language after the resumable upload completes.
        // This makes the caption track immediately discoverable in Studio even
        // if Google's initial insert metadata did not persist the language.
        report("Setting English video language…", in: .upload, tone: .normal)
        let languagePayload: [String: Any] = [
            "id": id,
            "snippet": [
                "title": current.draft.title,
                "description": current.draft.description,
                "categoryId": "22",
                "defaultLanguage": "en",
                "defaultAudioLanguage": "en"
            ]
        ]
        let languageBody = try JSONSerialization.data(withJSONObject: languagePayload)
        let (languageData, languageResponse) = try await authorized("https://www.googleapis.com/youtube/v3/videos?part=snippet", method: "PUT", body: languageBody,
                                                                    headers: ["Content-Type": "application/json; charset=UTF-8"])
        try requireSuccess(languageResponse, languageData)
        if let bookmark = current.draft.thumbnailBookmark, !current.thumbnailDone {
            report("Video uploaded. Setting thumbnail…", in: .upload, tone: .normal)
            let thumbnail = try YouTubeFiles.thumbnail(bookmark)
            let (data, response) = try await authorized("https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=\(id)&uploadType=media", method: "POST", body: thumbnail,
                                                       headers: ["Content-Type": "image/jpeg"])
            try requireSuccess(response, data)
            current.thumbnailDone = true; try persist(current)
        }
        if let playlistID = current.draft.playlistID, !current.playlistDone {
            report("Adding video to playlist…", in: .upload, tone: .normal)
            let payload: [String: Any] = ["snippet": ["playlistId": playlistID,
                                                         "resourceId": ["kind": "youtube#video", "videoId": id]]]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let endpoint = "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet"
            let (data, response) = try await authorized(endpoint, method: "POST", body: body,
                                                        headers: ["Content-Type": "application/json; charset=UTF-8"])
            try requireSuccess(response, data)
            current.playlistDone = true; try persist(current)
        }
        if let captionData = current.captionData, !current.captionDone {
            report("Uploading English subtitles to YouTube…", in: .upload, tone: .normal)
            let body = try Self.captionMultipart(videoID: id, srt: captionData)
            let (data, response) = try await authorized("https://www.googleapis.com/upload/youtube/v3/captions?uploadType=multipart&part=snippet", method: "POST", body: body.data,
                headers: ["Content-Type": "multipart/related; boundary=\(body.boundary)",
                          "Content-Length": "\(body.data.count)"])
            do { try requireSuccess(response, data) }
            catch let error as YouTubeFailure {
                throw YouTubeFailure(message: "YouTube subtitle upload failed: \(error.localizedDescription)")
            }
            let track = try JSONDecoder().decode(CaptionTrack.self, from: data)
            guard !track.id.isEmpty, track.snippet.videoId == id, track.snippet.language == "en" else {
                throw YouTubeFailure(message: "Google did not return the expected English subtitle track.")
            }
            evidence["trackID"] = track.id
            defaults.set(evidence, forKey: "SermonClip.lastSubtitleUploadEvidence")
            current.captionDone = true; try persist(current)
        }
        if current.captionData != nil {
            let tracks = try await captionTracks(videoID: id)
            guard let track = tracks.first(where: {
                $0.snippet.language == "en" && ["English", "English (SermonClip)"].contains($0.snippet.name)
            }) else {
                throw YouTubeFailure(message: "The English subtitle upload was accepted, but YouTube does not list the track. The retry record has been retained.")
            }
            guard track.snippet.status == "serving", track.snippet.isDraft == false else {
                throw YouTubeFailure(message: "English subtitles are not confirmed ready: status \(track.snippet.status ?? "unknown"), draft \(track.snippet.isDraft.map(String.init) ?? "unknown"), reason \(track.snippet.failureReason ?? "none reported"). Resume checks the existing track without uploading it again.")
            }
        }
        report("Checking YouTube visibility…", in: .upload, tone: .normal)
        let (data, response) = try await authorized("https://www.googleapis.com/youtube/v3/videos?part=status&id=\(id)")
        try requireSuccess(response, data)
        let result = try JSONDecoder().decode(VideoList.self, from: data)
        guard let actual = result.items.first?.status.privacyStatus else { throw YouTubeFailure(message: "Could not confirm visibility. Check YouTube Studio before assuming the video is published.") }
        try secrets.write(nil, key: "uploadJob"); job = nil; progress = 1; estimate = ""
        report(actual == current.draft.visibility.rawValue ? "Upload complete — \(actual.capitalized). YouTube may still be processing HD video." : "Video uploaded, but YouTube reports \(actual.capitalized), not \(current.draft.visibility.title). Your API project may be private-only pending audit. Check YouTube Studio.", in: .upload, tone: actual == current.draft.visibility.rawValue ? .normal : .warning)
    }
    private func persist(_ current: YouTubeUploadJob) throws { try save(current, "uploadJob"); job = current }

    private static func captionMultipart(videoID: String, srt: Data) throws -> (data: Data, boundary: String) {
        let boundary = "SermonClipCaption-\(UUID().uuidString)"
        let metadata: [String: Any] = ["snippet": ["videoId": videoID, "language": "en", "name": "English", "isDraft": false]]
        let json = try JSONSerialization.data(withJSONObject: metadata)
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        data.append(json); append("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n")
        data.append(srt); append("\r\n--\(boundary)--\r\n")
        return (data, boundary)
    }
    static func allowedUploadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "www.googleapis.com" && url.port == nil && url.user == nil && url.password == nil && url.path == "/upload/youtube/v3/videos"
    }
    static func nextOffset(_ range: String?, total: Int64) throws -> Int64 {
        guard let range else { return 0 }
        guard range.hasPrefix("bytes=0-"), let end = Int64(range.dropFirst(8)), end >= 0, end < total else {
            throw YouTubeFailure(message: "Google returned an invalid upload byte range.")
        }
        return end + 1
    }

    private struct TokenReply: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double }
    private struct ChannelList: Decodable {
        struct Item: Decodable { struct Snippet: Decodable { let title: String }; let id: String; let snippet: Snippet }
        let items: [Item]
    }
    private struct VideoResult: Decodable { let id: String }
    private struct VideoList: Decodable {
        struct Item: Decodable { struct Status: Decodable { let privacyStatus: String }; let status: Status }
        let items: [Item]
    }
    private struct PlaylistList: Decodable {
        struct Item: Decodable {
            struct Snippet: Decodable { let title: String }
            struct Status: Decodable { let privacyStatus: String? }
            let id: String; let snippet: Snippet; let status: Status?
        }
        let items: [Item]
        let nextPageToken: String?
    }
    private func fetchPlaylists() async throws -> [YouTubePlaylist] {
        var result: [YouTubePlaylist] = []; var page: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlists")!
            components.queryItems = [URLQueryItem(name: "part", value: "snippet,status"),
                                     URLQueryItem(name: "mine", value: "true"),
                                     URLQueryItem(name: "maxResults", value: "50")]
            if let page { components.queryItems?.append(URLQueryItem(name: "pageToken", value: page)) }
            let (data, response) = try await authorized(components.url!.absoluteString)
            try requireSuccess(response, data)
            let decoded = try JSONDecoder().decode(PlaylistList.self, from: data)
            result += decoded.items.map { YouTubePlaylist(id: $0.id, title: $0.snippet.title, privacyStatus: $0.status?.privacyStatus) }
            page = decoded.nextPageToken
        } while page != nil
        return result
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> TokenReply {
        let (data, response) = try await raw("https://oauth2.googleapis.com/token", method: "POST", body: GoogleOAuth.form(fields), headers: ["Content-Type": "application/x-www-form-urlencoded"])
        try requireSuccess(response, data)
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }
    private func accessToken() async throws -> String {
        guard var connection, let configuration else { throw YouTubeFailure(message: "Connect YouTube first.") }
        if connection.expiresAt.timeIntervalSinceNow < 60 {
            let token = try await tokenRequest(["client_id": configuration.client_id, "client_secret": configuration.client_secret,
                                               "refresh_token": connection.refreshToken, "grant_type": "refresh_token"])
            connection.accessToken = token.access_token; connection.expiresAt = Date().addingTimeInterval(token.expires_in)
            if let refresh = token.refresh_token { connection.refreshToken = refresh }
            try save(connection, "connection"); self.connection = connection
        }
        return connection.accessToken
    }
    private func authorized(_ url: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let token = try await accessToken()
        let result = try await raw(url, method: method, body: body, headers: headers, token: token)
        if result.1.statusCode == 401 {
            connection?.expiresAt = .distantPast
            return try await raw(url, method: method, body: body, headers: headers, token: accessToken())
        }
        return result
    }
    private func raw(_ url: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method; request.timeoutInterval = 120
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let result: (Data, URLResponse)
        if let body { result = try await session.upload(for: request, from: body) }
        else { result = try await session.data(for: request) }
        guard let response = result.1 as? HTTPURLResponse else { throw YouTubeFailure(message: "Invalid response from Google.") }
        return (result.0, response)
    }
    private func requireSuccess(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            // Keep the useful Google diagnostic while excluding credentials and
            // resumable URLs. This is especially important for caption retries,
            // where a generic HTTP 400 is otherwise impossible to troubleshoot.
            let message: String
            switch response.statusCode {
            case 400:
                if let details = try? JSONDecoder().decode(GoogleAPIError.self, from: data),
                   let error = details.error,
                   let item = error.errors?.first {
                    message = "Google rejected the request (HTTP 400, \(item.reason ?? "invalid request")): \(item.message ?? error.message ?? "Check the metadata and SRT format.")"
                } else { message = "Google rejected the request (HTTP 400): \(sanitizedResponseBody(data))" }
            case 401: message = "Google authorization expired or was revoked (HTTP 401). Reconnect your channel."
            case 403: message = "Google denied this operation (HTTP 403): \(sanitizedResponseBody(data))"
            case 404, 410: message = "The upload session or video was not found. Check YouTube Studio before discarding the retry record and starting another upload."
            case 429, 500...599: message = "Google is temporarily unavailable or rate-limiting requests. Wait, then resume the saved upload."
            default: message = "Google request failed (HTTP \(response.statusCode))."
            }
            throw YouTubeFailure(message: message)
        }
    }

    private func sanitizedResponseBody(_ data: Data) -> String {
        guard var text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "No diagnostic message was returned."
        }
        // Avoid putting an unexpectedly large response into the notice area.
        text = text.replacingOccurrences(of: "Bearer", with: "[redacted]")
        return String(text.prefix(700))
    }
}

private struct GoogleAPIError: Decodable {
    struct Detail: Decodable { let reason: String?; let message: String? }
    struct Body: Decodable { let message: String?; let errors: [Detail]? }
    let error: Body?
}
