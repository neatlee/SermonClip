import AppKit
import Foundation

struct AppUpdateRelease: Equatable {
    let version: String
    let name: String
    let releaseURL: URL
    let downloadURL: URL
}

struct AppUpdateMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct HomebrewUpdateInstructions: Identifiable {
    let id = UUID()
    let version: String
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    @Published var updateRelease: AppUpdateRelease?
    @Published var message: AppUpdateMessage?
    @Published var homebrewInstructions: HomebrewUpdateInstructions?
    @Published private(set) var isChecking = false

    private let endpoint = URL(string: "https://api.github.com/repos/neatlee/SermonClip/releases/latest")!

    func checkForUpdates(silent: Bool = false) {
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { isChecking = false }
            do {
                let release = try await fetchLatestRelease()
                if isNewer(release.version, than: currentVersion) {
                    updateRelease = release
                } else if !silent {
                    message = AppUpdateMessage(title: "SermonClip is up to date", message: "You are running SermonClip \(currentVersion).")
                }
            } catch {
                if !silent {
                    message = AppUpdateMessage(title: "Update check failed", message: "SermonClip could not check GitHub for a newer release. Please try again later.")
                }
            }
        }
    }

    func openDownload(for release: AppUpdateRelease) {
        NSWorkspace.shared.open(release.downloadURL)
    }

    func chooseHomebrew(for release: AppUpdateRelease) {
        updateRelease = nil
        homebrewInstructions = HomebrewUpdateInstructions(version: release.version)
    }

    func copyToPasteboard(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.2"
    }

    private func fetchLatestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: endpoint)
        request.setValue("SermonClip/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = payload.tagName.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let downloadURL = payload.assets.first(where: { $0.name.hasSuffix("-arm64.dmg") })?.browserDownloadURL
            ?? payload.htmlURL
        return AppUpdateRelease(version: version, name: payload.name, releaseURL: payload.htmlURL, downloadURL: downloadURL)
    }

    private func isNewer(_ candidate: String, than installed: String) -> Bool {
        let candidateParts = versionParts(candidate)
        let installedParts = versionParts(installed)
        let count = max(candidateParts.count, installedParts.count)
        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let installedPart = index < installedParts.count ? installedParts[index] : 0
            if candidatePart != installedPart { return candidatePart > installedPart }
        }
        return false
    }

    private func versionParts(_ version: String) -> [Int] {
        version.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let htmlURL: URL
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
