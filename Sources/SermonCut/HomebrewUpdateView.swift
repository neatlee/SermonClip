import SwiftUI

struct HomebrewUpdateView: View {
    @EnvironmentObject private var updates: AppUpdateChecker
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCommand: String?

    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Update with Homebrew")
                .font(.title2.weight(.semibold))
            Text("Use the command that matches how SermonClip is installed. Homebrew will preserve your preferences, bumper library, presets, and Keychain authorization.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            commandRow(
                title: "Trust this cask once",
                command: "brew trust --cask neatlee/sermonclip/sermonclip"
            )
            commandRow(
                title: "Already adopted by Homebrew",
                command: "brew upgrade --cask neatlee/sermonclip/sermonclip"
            )
            commandRow(
                title: "Installed from the website",
                command: "brew install --cask --adopt neatlee/sermonclip/sermonclip"
            )

            Text("If this is your first Homebrew install, run `brew tap neatlee/sermonclip` once before trusting the cask.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Terminal") { updates.openTerminal() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder
    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack(spacing: 10) {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copiedCommand == command ? "Copied" : "Copy") {
                    updates.copyToPasteboard(command)
                    copiedCommand = command
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
