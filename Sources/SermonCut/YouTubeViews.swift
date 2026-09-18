import SwiftUI
import UniformTypeIdentifiers

struct YouTubeUploadView: View {
    @EnvironmentObject private var youtube: YouTubeStore
    @EnvironmentObject private var project: ProjectStore
    let chooseThumbnail: () -> Void
    let goToYouTubeSettings: () -> Void
    @State private var presetID: UUID?
    @State private var replaceDescription = false
    @State private var discard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $youtube.enabled) {
                    Text("UPLOAD TO YOUTUBE AFTER EXPORT")
                        .tracking(1)
                }.handCursor()
                .onChange(of: youtube.enabled, initial: true) { _, enabled in
                    project.setYouTubeUploadRequirement(enabled)
                }
                if youtube.enabled {
                    if youtube.connection == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            StatusNotice(text: "Connect your channel in YouTube Settings before exporting and uploading.", tone: .warning)
                            SermonClipButton("Go to YouTube Settings", action: goToYouTubeSettings)
                                .buttonStyle(SermonClipSecondaryStyle())
                        }
                    }
                    TextField("Video Title", text: $youtube.title).sermonClipInputStyle(onDarkSurface: true)
                    HStack {
                        Picker("Description Preset:", selection: $presetID) {
                            Text("Choose a preset").tag(UUID?.none)
                            ForEach(youtube.presets) { Text($0.name).tag(Optional($0.id)) }
                        }.sermonClipDropdownStyle()
                        SermonClipButton("Use preset") {
                            if youtube.videoDescription.isEmpty { applyPreset() } else { replaceDescription = true }
                        }.disabled(presetID == nil)
                    }
                    TextEditor(text: $youtube.videoDescription)
                        .sermonClipTextEditorStyle(onDarkSurface: true)
                        .overlay(alignment: .topLeading) {
                            if youtube.videoDescription.isEmpty {
                                Text("Video Description")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 15)
                                    .padding(.top, 14)
                                    .allowsHitTesting(false)
                            }
                        }
                    Text("\(youtube.videoDescription.utf8.count) / 5,000 bytes · Editing here does not change the saved preset.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("Playlist:", selection: $youtube.playlistID) {
                            Text("No playlist").tag(String?.none)
                            ForEach(youtube.playlists) { playlist in
                                Text(playlist.title).tag(Optional(playlist.id))
                            }
                        }.sermonClipDropdownStyle()
                        SermonClipButton { youtube.loadPlaylists() } label: {
                            Label("Refresh playlists", systemImage: "arrow.clockwise")
                        }
                        .disabled(youtube.connection == nil || youtube.playlistsLoading)
                        if youtube.playlistsLoading { ProgressView().controlSize(.small) }
                    }
                    youtubeNotice(.playlists)
                    if youtube.connection != nil && youtube.playlists.isEmpty && !youtube.playlistsLoading {
                        Text("Choose a playlist, or leave this as No playlist. Refresh loads playlists owned by the connected channel.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if let image = youtube.thumbnailPreview {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 120, height: 68)
                        }
                        VStack(alignment: .leading) {
                            HStack {
                                SermonClipButton(youtube.thumbnailName == nil ? "Choose thumbnail JPG…" : "Replace thumbnail…", action: chooseThumbnail)
                                if youtube.thumbnailName != nil {
                                    SermonClipButton("Remove", role: .destructive) { youtube.removeThumbnail() }
                                }
                            }
                            Text(youtube.thumbnailName ?? "Optional · JPG up to 2 MB (YouTube API limit)").font(.caption).lineLimit(1)
                        }
                    }
                    youtubeNotice(.thumbnail)
                    Picker("Visibility:", selection: $youtube.visibility) {
                        ForEach(YouTubeVisibility.allCases) { Text($0.title).tag($0) }
                    }.sermonClipDropdownStyle()
                    Text("New unaudited Google API projects are restricted to Private uploads. Public/Unlisted requests may be rejected or restricted by YouTube; the app checks the returned visibility. Review audience settings in YouTube Studio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(project.isExporting || youtube.busy || youtube.job != nil)
            if youtube.enabled || youtube.busy || youtube.job != nil || youtube.completedVideoID != nil {
                youtubeNotice(.upload)
                if youtube.busy && youtube.job == nil { youtubeNotice(.account) }
                if youtube.busy {
                    ProgressView(value: youtube.progress)
                    Text("\(Int(youtube.progress * 100))% · \(youtube.estimate)").font(.caption)
                    SermonClipButton(youtube.job == nil ? "Cancel sign-in" : "Pause upload") { youtube.cancel() }
                } else if youtube.job != nil {
                    HStack {
                        SermonClipButton("Resume saved upload") { youtube.resume() }.buttonStyle(SermonClipStandardPrimaryStyle()).disabled(youtube.connection == nil || project.isExporting)
                        SermonClipButton("Discard retry record…") { discard = true }.disabled(project.isExporting)
                    }
                    if let draft = youtube.job?.draft { Text("Saved upload: \(draft.title) · \(draft.visibility.title)").font(.caption) }
                }
                if let id = youtube.completedVideoID, let url = URL(string: "https://studio.youtube.com/video/\(id)/edit") {
                    Link("Open in YouTube Studio", destination: url).handCursor()
                }
            }
        }
        .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: youtube.enabled) { if youtube.enabled { youtube.loadPlaylists() } }
        .alert("Replace this upload's description?", isPresented: $replaceDescription) {
            SermonClipButton("Cancel", role: .cancel) { }
            SermonClipButton("Use preset") { applyPreset() }
        } message: { Text("The current description will be replaced. Saved presets are unchanged.") }
        .alert("Discard saved upload retry information?", isPresented: $discard) {
            SermonClipButton("Cancel", role: .cancel) { }
            SermonClipButton("Discard record", role: .destructive) { youtube.discardPending() }
        } message: { Text("This does not delete local files or any video already uploaded to YouTube. Check YouTube Studio before starting again to avoid duplicates.") }
    }
    @ViewBuilder private func youtubeNotice(_ area: YouTubeArea) -> some View {
        if let notice = youtube.notices[area] {
            StatusNotice(text: notice.text, tone: notice.tone)
                .transition(.opacity)
        }
    }
    private func applyPreset() {
        if let preset = youtube.presets.first(where: { $0.id == presetID }) { youtube.videoDescription = preset.text }
    }
}

struct YouTubeSettingsView: View {
    @EnvironmentObject private var youtube: YouTubeStore
    @EnvironmentObject private var project: ProjectStore
    @State private var disconnect = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkflowSection(title: "Account Connection") {
                if !youtube.configured {
                    Label("The bundled Google configuration is unavailable. Reinstall the production build or contact the app administrator.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if let notice = youtube.notices[.account], notice.tone == .error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("YouTube connection needs attention", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(notice.text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.28)))
                } else if let channel = youtube.connection {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(channel.channelName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                        Text("Channel ID: \(channel.channelID)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.25)))
                } else {
                    Text("No YouTube channel connected.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    SermonClipButton(youtube.connection == nil ? "Connect to YouTube" : "Reconnect to YouTube") { youtube.connect() }
                        .buttonStyle(SermonClipStandardPrimaryStyle())
                        .disabled(!youtube.configured || youtube.busy)
                    if youtube.connection != nil {
                        SermonClipButton("Disconnect…", role: .destructive) { disconnect = true }
                            .disabled(youtube.busy || youtube.job != nil || project.isExporting)
                    }
                }
                if let notice = youtube.notices[.account], notice.tone == .warning {
                    StatusNotice(text: notice.text, tone: notice.tone)
                }
                if youtube.busy && youtube.job == nil {
                    SermonClipButton("Cancel sign-in") { youtube.cancel() }
                        .buttonStyle(SermonClipSecondaryStyle())
                }
            }
            .disabled(!youtube.configured || youtube.busy)
            .opacity(youtube.configured ? 1 : 0.58)
            DescriptionLibraryView()
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Disconnect this Mac from YouTube?", isPresented: $disconnect) {
            SermonClipButton("Cancel", role: .cancel) { }
            SermonClipButton("Disconnect", role: .destructive) { youtube.disconnect() }
        } message: { Text("The saved authorization tokens will be removed from Keychain. Videos and description presets are not deleted.") }
    }
}

struct DescriptionLibraryView: View {
    @EnvironmentObject private var youtube: YouTubeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: UUID?
    @State private var name = ""
    @State private var text = ""
    @State private var error = ""
    @State private var saveNoticeID = UUID()
    @State private var deleting = false
    @State private var savedName = ""
    @State private var savedText = ""
    private var dirty: Bool { name != savedName || text != savedText }
    @State private var pendingSelection: UUID?
    @State private var changeSelection = false

    var body: some View {
        WorkflowSection(title: "Description Presets") {
            VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Saved Presets").font(.headline)
                        Spacer()
                        SermonClipButton("New Preset") { select(nil) }
                            .buttonStyle(SermonClipStandardPrimaryStyle())
                    }
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(youtube.presets) { preset in
                                Button(action: { select(preset.id) }) {
                                    HStack(spacing: 8) {
                                        Text(preset.name)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if selected == preset.id {
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                        }
                                    }
                                }
                                .buttonStyle(SidebarNavigationStyle(selected: selected == preset.id))
                                .handCursor()
                                .accessibilityAddTraits(selected == preset.id ? .isSelected : [])
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: PresetRowFrames.self,
                                            value: [preset.id: geometry.frame(in: .named("preset-items"))])
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .coordinateSpace(name: "preset-items")
                        .backgroundPreferenceValue(PresetRowFrames.self) { frames in
                            if let selected, let frame = frames[selected] {
                                SidebarSelectionHighlight(frame: frame, reduceMotion: reduceMotion)
                            }
                        }
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                }
                .frame(width: 280, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Preset Details").font(.headline)
                    TextField("Preset Name", text: $name)
                        .sermonClipInputStyle()
                        .controlSize(.large)
                    TextEditor(text: $text)
                        .sermonClipTextEditorStyle(minimumHeight: 0)
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Description")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 15)
                                    .padding(.top, 14)
                                    .allowsHitTesting(false)
                            }
                        }
                    Text("\(text.count) / 5,000 characters").font(.caption)
                    HStack {
                        SermonClipButton("Save preset") {
                            saveNoticeID = UUID()
                            do { try youtube.savePreset(id: selected, name: name, text: text); selected = selected ?? youtube.presets.last?.id; savedName = name; savedText = text; error = "Saved." }
                            catch { self.error = error.localizedDescription }
                        }.buttonStyle(SermonClipStandardPrimaryStyle())
                        if selected != nil {
                            SermonClipButton("Delete…", role: .destructive) { deleting = true }
                                .buttonStyle(SermonClipDestructiveStyle())
                        }
                    }
                    if !error.isEmpty {
                        StatusNotice(text: error, tone: error == "Saved." ? .normal : .error)
                            .transition(.opacity)
                            .task(id: saveNoticeID) {
                                guard error == "Saved." else { return }
                                let noticeID = saveNoticeID
                                do { try await Task.sleep(for: .seconds(10)) }
                                catch { return }
                                guard !Task.isCancelled, saveNoticeID == noticeID, error == "Saved." else { return }
                                withAnimation(.easeOut(duration: 0.3)) { error = "" }
                            }
                    }
                }
                .padding(.top, 14)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                Text("Presets are saved on this Mac. Applying one copies its text into an upload; later preset edits do not change that upload.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .alert("Permanently delete this description preset?", isPresented: $deleting) {
            SermonClipButton("Cancel", role: .cancel) { }
            SermonClipButton("Delete permanently", role: .destructive) {
                if let preset = youtube.presets.first(where: { $0.id == selected }) { youtube.deletePreset(preset) }
                load(nil)
            }
        } message: { Text("The saved preset cannot be recovered. Descriptions already copied into uploads remain unchanged.") }
        .alert("Discard unsaved preset edits?", isPresented: $changeSelection) {
            SermonClipButton("Cancel", role: .cancel) { }
            SermonClipButton("Discard edits", role: .destructive) { load(pendingSelection) }
        }
    }
    private func select(_ id: UUID?) {
        if dirty { pendingSelection = id; changeSelection = true } else { load(id) }
    }
    private func load(_ id: UUID?) {
        selected = id
        let preset = youtube.presets.first(where: { $0.id == id })
        name = preset?.name ?? ""; text = preset?.text ?? ""; error = ""; savedName = name; savedText = text
    }
}

private struct PresetRowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
