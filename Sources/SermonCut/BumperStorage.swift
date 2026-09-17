import Foundation

struct BumperStorage {
    let root: URL
    init(root: URL = URL.applicationSupportDirectory.appending(path: "SermonClip/Bumpers", directoryHint: .isDirectory)) {
        self.root = root
    }

    func importCopy(from source: URL, kind: BumperKind) throws -> Bumper {
        let ext = source.pathExtension.lowercased()
        guard ["mp4", "m4v", "mov", "jpg", "jpeg"].contains(ext) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Bumpers must be an MP4/MOV video or JPG image."])
        }
        let id = UUID()
        let filename = id.uuidString + "." + ext
        let folder = root.appending(path: kind.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder.appending(path: filename))
        return Bumper(id: id, name: source.deletingPathExtension().lastPathComponent, kind: kind,
                      bookmark: Data(), createdAt: .now, managedFilename: filename,
                      media: ["jpg", "jpeg"].contains(ext) ? .image : .video)
    }

    func url(for bumper: Bumper) -> URL? {
        guard let filename = bumper.managedFilename, filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        return root.appending(path: bumper.kind.rawValue).appending(path: filename)
    }

    func deleteCopy(of bumper: Bumper) throws {
        guard !bumper.isBundled else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "The included SCB bumper cannot be deleted."])
        }
        // Legacy bookmark entries never own the original file.
        guard bumper.managedFilename != nil else { return }
        guard let copy = url(for: bumper) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        if FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.removeItem(at: copy)
        }
    }
}
