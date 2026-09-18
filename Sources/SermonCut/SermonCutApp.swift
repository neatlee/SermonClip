import SwiftUI

@main
struct SermonCutApp: App {
    @StateObject private var store = ProjectStore()
    @StateObject private var youtube = YouTubeStore()
    @StateObject private var updates = AppUpdateChecker()

    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            ContentView()
                .environmentObject(store)
                .environmentObject(youtube)
                .environmentObject(updates)
                .tint(Color(red: 1.0, green: 151.0 / 255.0, blue: 2.0 / 255.0))
                .frame(minWidth: 980, minHeight: 680)
                .task { updates.checkForUpdates(silent: true) }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(updates.isChecking)
            }
        }
    }
}
