import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

struct YouTubeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum YouTubeVisibility: String, Codable, CaseIterable, Identifiable {
    case `private`, unlisted, `public`
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct DescriptionPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}

struct GoogleDesktopConfiguration: Codable, Equatable {
    var client_id: String
    var client_secret: String

    static func make(clientID: String, clientSecret: String) throws -> Self {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"), !secret.isEmpty else {
            throw YouTubeFailure(message: "Enter a valid Google Desktop app client ID and client secret.")
        }
        return Self(client_id: id, client_secret: secret)
    }

    static func parse(_ data: Data) throws -> Self {
        struct File: Decodable { let installed: GoogleDesktopConfiguration }
        guard data.count < 100_000,
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            throw YouTubeFailure(message: "Choose the Google JSON downloaded for a Desktop app OAuth client, not a Web client or service account.")
        }
        // Never trust auth/token endpoints from an imported file.
        return try make(clientID: file.installed.client_id, clientSecret: file.installed.client_secret)
    }
}

struct GoogleConnection: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var channelID: String
    var channelName: String
}

struct YouTubePlaylist: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var privacyStatus: String?
}

struct YouTubeUploadDraft: Codable {
    var title: String
    var description: String
    var visibility: YouTubeVisibility
    var thumbnailBookmark: Data?
    var playlistID: String? = nil

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 100, !title.contains("<"), !title.contains(">") else {
            throw YouTubeFailure(message: "Use a title of 1–100 characters, without < or >.")
        }
        guard description.utf8.count <= 5000, !description.contains("<"), !description.contains(">") else {
            throw YouTubeFailure(message: "Descriptions must be at most 5,000 UTF-8 bytes and cannot contain < or >.")
        }
    }
}

struct YouTubeUploadJob: Codable {
    var draft: YouTubeUploadDraft
    var videoBookmark: Data
    var fileSize: Int64
    var modifiedAt: Date
    var channelID: String
    var sessionURL: URL?
    var videoID: String?
    var thumbnailDone = false
    var playlistDone = false
    var captionData: Data?
    var captionDone = false

    init(draft: YouTubeUploadDraft, videoBookmark: Data, fileSize: Int64, modifiedAt: Date,
         channelID: String, sessionURL: URL? = nil, videoID: String? = nil,
         thumbnailDone: Bool = false, playlistDone: Bool = false,
         captionData: Data? = nil, captionDone: Bool = false) {
        self.draft = draft; self.videoBookmark = videoBookmark; self.fileSize = fileSize
        self.modifiedAt = modifiedAt; self.channelID = channelID; self.sessionURL = sessionURL
        self.videoID = videoID; self.thumbnailDone = thumbnailDone; self.playlistDone = playlistDone
        self.captionData = captionData; self.captionDone = captionDone
    }

    private enum CodingKeys: String, CodingKey {
        case draft, videoBookmark, fileSize, modifiedAt, channelID, sessionURL, videoID, thumbnailDone, playlistDone, captionData, captionDone
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        draft = try values.decode(YouTubeUploadDraft.self, forKey: .draft)
        videoBookmark = try values.decode(Data.self, forKey: .videoBookmark)
        fileSize = try values.decode(Int64.self, forKey: .fileSize)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        channelID = try values.decode(String.self, forKey: .channelID)
        sessionURL = try values.decodeIfPresent(URL.self, forKey: .sessionURL)
        videoID = try values.decodeIfPresent(String.self, forKey: .videoID)
        thumbnailDone = try values.decodeIfPresent(Bool.self, forKey: .thumbnailDone) ?? false
        playlistDone = try values.decodeIfPresent(Bool.self, forKey: .playlistDone) ?? false
        captionData = try values.decodeIfPresent(Data.self, forKey: .captionData)
        captionDone = try values.decodeIfPresent(Bool.self, forKey: .captionDone) ?? false
    }
}

enum YouTubeThumbnail {
    static let maximumBytes = 2 * 1024 * 1024
    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw YouTubeFailure(message: "Choose a JPG no larger than 2 MB, the YouTube upload API limit.")
        }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(image) as String? == UTType.jpeg.identifier,
              CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else {
            throw YouTubeFailure(message: "The selected file is not a readable JPG image.")
        }
    }
}

protocol YouTubeSecretStorage {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data?, key: String) throws
}

struct YouTubeKeychain: YouTubeSecretStorage {
    private let service = "local.sermonclip.youtube"
    func read(_ key: String) throws -> Data? {
        let cache = cacheKey(key)
        if let value = YouTubeKeychainCache.value(for: cache) { return value }
        var result: CFTypeRef?
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        guard let data = result as? Data else { return nil }
        YouTubeKeychainCache.set(data, for: cache)
        return data
    }
    func write(_ data: Data?, key: String) throws {
        let query = base(key)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            YouTubeKeychainCache.remove(cacheKey(key))
            return
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
        YouTubeKeychainCache.set(data, for: cacheKey(key))
    }
    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    private func failure(_ status: OSStatus) -> YouTubeFailure {
        YouTubeFailure(message: "SermonClip couldn't access the saved Google credentials. Please re-enter your Client ID and Client Secret in Step 1, save them, and then try connecting again. Your credentials were not logged or saved elsewhere.")
    }

    private func cacheKey(_ key: String) -> String { service + "\u{1F}" + key }

}

private enum YouTubeKeychainCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [String: Data] = [:]
    static func value(for key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    static func set(_ value: Data, for key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    static func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}

enum YouTubeFiles {
    static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static func resolve(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    static func thumbnail(_ bookmark: Data) throws -> Data {
        let url = try resolve(bookmark)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= YouTubeThumbnail.maximumBytes else {
            throw YouTubeFailure(message: "The thumbnail must be a JPG no larger than 2 MB.")
        }
        let data = try Data(contentsOf: url)
        try YouTubeThumbnail.validate(data)
        return data
    }
}
