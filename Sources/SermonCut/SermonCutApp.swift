import SwiftUI

@main
struct SermonCutApp: App {
    @StateObject private var store = ProjectStore()
    @StateObject private var youtube = YouTubeStore()

    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            ContentView()
                .environmentObject(store)
                .environmentObject(youtube)
                .tint(Color(red: 1.0, green: 151.0 / 255.0, blue: 2.0 / 255.0))
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
