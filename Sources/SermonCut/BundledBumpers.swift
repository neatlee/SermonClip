import Foundation

enum BundledBumpers {
    static let installedKey = "SermonClip.bundledBumpers.installed.v1"

    /// Seed only a new library. An existing (even deliberately empty) library
    /// and its defaults always belong to the user and must not be replaced.
    static func installIfNeeded(source: URL?, defaults: UserDefaults, storage: BumperStorage,
                                bumperKey: String, preferencesKey: String) throws {
        guard let source else { return }
        try protectExistingCopies(source: source, defaults: defaults, storage: storage, bumperKey: bumperKey)
        guard !defaults.bool(forKey: installedKey) else { return }
        guard defaults.object(forKey: bumperKey) == nil,
              defaults.object(forKey: preferencesKey) == nil else {
            defaults.set(true, forKey: installedKey)
            return
        }
        var copies: [Bumper] = []
        do {
            let opening = try storage.importCopy(from: source, kind: .opening)
            copies.append(opening)
            let closing = try storage.importCopy(from: source, kind: .closing)
            copies.append(closing)
            var preferences = AppPreferences()
            preferences.defaultOpeningID = opening.id
            preferences.defaultClosingID = closing.id
            preferences.lastOpeningID = opening.id
            preferences.lastClosingID = closing.id
            let bumperData = try JSONEncoder().encode(copies.map { original in
                var protected = original
                protected.isBundled = true
                return protected
            })
            let preferencesData = try JSONEncoder().encode(preferences)
            defaults.set(bumperData, forKey: bumperKey)
            defaults.set(preferencesData, forKey: preferencesKey)
            defaults.set(true, forKey: installedKey)
        } catch {
            for bumper in copies { try? storage.deleteCopy(of: bumper) }
            throw error
        }
    }

    /// Earlier builds did not persist bundled identity. Adopt an exact managed
    /// copy in each category, preserving its ID, name, selections and defaults.
    /// Never infer protection from a display name or reinstall deleted entries.
    private static func protectExistingCopies(source: URL, defaults: UserDefaults, storage: BumperStorage,
                                              bumperKey: String) throws {
        guard let data = defaults.data(forKey: bumperKey) else { return }
        var bumpers = try JSONDecoder().decode([Bumper].self, from: data)
        let kinds = BumperKind.allCases.filter { kind in
            !bumpers.contains { $0.kind == kind && $0.isBundled }
                && bumpers.contains { $0.kind == kind && $0.media == .video && $0.managedFilename != nil }
        }
        guard !kinds.isEmpty, FileManager.default.fileExists(atPath: source.path) else { return }
        let bundledBytes = try Data(contentsOf: source, options: .mappedIfSafe)
        var changed = false
        for kind in kinds {
            if let index = bumpers.firstIndex(where: { bumper in
                guard bumper.kind == kind, bumper.media == .video,
                      let url = storage.url(for: bumper),
                      let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
                return bytes == bundledBytes
            }) {
                bumpers[index].isBundled = true
                changed = true
            }
        }
        if changed { defaults.set(try JSONEncoder().encode(bumpers), forKey: bumperKey) }
    }
}
