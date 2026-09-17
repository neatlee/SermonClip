import Foundation

enum BumperKind: String, Codable, CaseIterable, Identifiable {
    case opening, closing
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BumperMedia: String, Codable, CaseIterable, Identifiable {
    case video, image
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Bumper: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var kind: BumperKind
    var bookmark: Data
    var createdAt: Date
    var managedFilename: String?
    var media: BumperMedia = .video
    var isBundled = false
    /// Cached integrated loudness in LUFS. This is optional for compatibility
    /// with libraries created before bumper loudness analysis was introduced.
    var audioLoudness: Double?

    init(id: UUID, name: String, kind: BumperKind, bookmark: Data, createdAt: Date,
         managedFilename: String?, media: BumperMedia = .video, audioLoudness: Double? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.bookmark = bookmark
        self.createdAt = createdAt; self.managedFilename = managedFilename; self.media = media
        self.audioLoudness = audioLoudness
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, bookmark, createdAt, managedFilename, media, isBundled, audioLoudness }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(BumperKind.self, forKey: .kind)
        bookmark = try values.decode(Data.self, forKey: .bookmark)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        managedFilename = try values.decodeIfPresent(String.self, forKey: .managedFilename)
        media = try values.decodeIfPresent(BumperMedia.self, forKey: .media) ?? .video
        isBundled = try values.decodeIfPresent(Bool.self, forKey: .isBundled) ?? false
        audioLoudness = try values.decodeIfPresent(Double.self, forKey: .audioLoudness)
    }
}

struct SubtitleCue: Identifiable, Hashable {
    let id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct SermonRange: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Double
    var explanation: String

    var duration: TimeInterval { max(0, end - start) }
}

enum StartupBumperMode: String, Codable, CaseIterable, Identifiable {
    case defaults, lastUsed
    var id: String { rawValue }
    var title: String { self == .defaults ? "Use Defaults" : "Use Last Used" }
}

enum CaptionPlan: Equatable {
    case supplied
    case generated
    case manualWithoutCaptions
    case localTranscriptionPendingEstimate
    case localTranscription(estimatedSeconds: TimeInterval)
    case localTranscribing

    var title: String {
        switch self {
        case .supplied: "Use supplied subtitles"
        case .generated: "Use generated subtitles"
        case .manualWithoutCaptions: "Manual cut — no subtitles"
        case .localTranscriptionPendingEstimate: "Create local subtitles"
        case .localTranscription: "Create local subtitles"
        case .localTranscribing: "Creating local subtitles"
        }
    }
}

struct AppPreferences: Codable {
    var startupBumperMode: StartupBumperMode = .defaults
    var defaultOpeningID: UUID?
    var defaultClosingID: UUID?
    var lastOpeningID: UUID?
    var lastClosingID: UUID?
    var exportDirectoryBookmark: Data?
}
