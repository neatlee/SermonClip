import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var youtube: YouTubeStore
    @EnvironmentObject private var updates: AppUpdateChecker
    @State private var importer: ImportTarget?
    @State private var showingImporter = false
    @State private var section: MainSection? = .project
    @State private var confirmUpload = false
    @State private var confirmDiscardSavedUpload = false
    @State private var showGeneratedSubtitles = false
    @State private var showAdjustedSubtitles = false
    @State private var player: AVPlayer?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                GeometryReader { _ in
                    VStack(spacing: 14) {
                        ForEach(MainSection.allCases) { item in
                            sidebarButton(for: item)
                        }
                    }
                    .padding(14)
                    .coordinateSpace(name: "sidebar-items")
                    .backgroundPreferenceValue(SidebarRowFrames.self) { frames in
                        if let frame = frames[section ?? .project] {
                            SidebarSelectionHighlight(frame: frame, selectionKey: (section ?? .project).rawValue, reduceMotion: reduceMotion, outlineOnly: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                sidebarLogo
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(SermonClipPalette.primaryFill, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .navigationTitle(AppIdentity.displayName)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 350)
        } detail: {
            // Keep page identities alive so navigation does not discard draft edits,
            // reset the playhead, or restart waveform extraction.
            ZStack {
                projectPanel.panelVisible(section == .project || section == nil)
                ScrollView {
                    BumperLibraryView()
                }
                .panelVisible(section == .bumpers)
                YouTubeSettingsView()
                    .panelVisible(section == .youtube)
            }
            .safeAreaInset(edge: .top, spacing: 0) { Divider() }
        }
        .confirmationDialog(
            "SermonClip \(updates.updateRelease?.version ?? "") is available",
            isPresented: Binding(
                get: { updates.updateRelease != nil },
                set: { if !$0 { updates.updateRelease = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let release = updates.updateRelease {
                Button("Download DMG") {
                    updates.updateRelease = nil
                    updates.openDownload(for: release)
                }
                Button("Use Homebrew") {
                    updates.chooseHomebrew(for: release)
                }
            }
            Button("Later", role: .cancel) { updates.updateRelease = nil }
        } message: {
            Text("Choose how you want to update SermonClip.")
        }
        .sheet(item: $updates.homebrewInstructions) { instructions in
            HomebrewUpdateView(version: instructions.version)
                .environmentObject(updates)
        }
        .alert(item: $updates.message) { message in
            Alert(title: Text(message.title), message: Text(message.message), dismissButton: .default(Text("OK")))
        }
    }

    private func sidebarButton(for item: MainSection) -> some View {
        let isSelected = section == item || (section == nil && item == .project)
        return Button { section = item } label: {
            VStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(isSelected ? SermonClipPalette.primaryFill : SermonClipPalette.sidebarOutline)
                Text(item.rawValue.uppercased())
                    .font(.body)
                    .tracking(1)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(MainSidebarNavigationStyle(selected: isSelected))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: SidebarRowFrames.self,
                    value: [item: geometry.frame(in: .named("sidebar-items"))])
            }
        }
        .handCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var sidebarLogo: some View {
        let resourceName = colorScheme == .dark ? "SermonClip-Darkmode-Logo" : "SermonClip-Lightmode-Logo"
        GeometryReader { proxy in
            if let url = AppResources.url(forResource: resourceName, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                let logoWidth = min(proxy.size.width * 0.60, 140)
                let logoHeight = logoWidth * image.size.height / max(1, image.size.width)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoWidth, height: logoHeight)
                    .position(x: proxy.size.width / 2,
                              y: proxy.size.height / 2)
                    .accessibilityLabel("SermonClip")
            }
        }
        .frame(height: 220)
        .background(Color.black.opacity(colorScheme == .dark ? 0.14 : 0.04))
    }

    private var projectPanel: some View {
        return ScrollViewReader { scrollProxy in
        ScrollView {
              VStack(alignment: .leading, spacing: 22) {
                if youtube.job != nil && !youtube.busy {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusNotice(text: "An unfinished YouTube upload is saved. Resume it or discard the retry record before starting another upload.", tone: .warning)
                        HStack {
                            SermonClipButton("Go to upload retry") {
                                withAnimation { scrollProxy.scrollTo("export-upload", anchor: .top) }
                            }
                            .buttonStyle(SermonClipStandardPrimaryStyle())
                            SermonClipButton("Remove retry record…", role: .destructive) {
                                confirmDiscardSavedUpload = true
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("1 · Bumpers").font(.title2.bold())
                        Spacer()
                        SermonClipButton("Manage Library") { section = .bumpers }
                            .buttonStyle(SermonClipSecondaryStyle())
                    }
                    bumperPickers
                    HStack(spacing: 24) {
                        if let opening = store.selectedOpening {
                            HStack(spacing: 8) {
                                BumperThumbnailView(bumper: opening)
                                Text("Opening · " + opening.name)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let closing = store.selectedClosing {
                            HStack(spacing: 8) {
                                Text("Closing · " + closing.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                                BumperThumbnailView(bumper: closing)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    // Library success confirmations belong only on the library panel.
                    if let bumperNotice = store.notices[.bumpers], bumperNotice.tone != .normal {
                        StatusNotice(text: bumperNotice.text, tone: bumperNotice.tone)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
                .disabled(store.isExporting)
                WorkflowSection(title: "2 · Source Video") {
                    ImportCard(title: "Service MP4", detail: store.sourceURL?.lastPathComponent ?? "No video selected", icon: "video.fill") {
                        importer = .video; showingImporter = true
                    }.disabled(store.isExporting)
                    notice(.source)
                }
                WorkflowSection(title: "3 · Trim Sermon") {
                    reviewSection
                    if store.sermonRange == nil {
                        Text("Choose a video above to set the sermon start and end.").foregroundStyle(.secondary)
                    }
                    notice(.trim)
                }.disabled(store.isExporting)
                WorkflowSection(title: "4 · Subtitles") {
                    if (!store.boundariesConfirmed || (store.sermonRange?.duration ?? 0) <= 0) {
                        StatusNotice(text: "Set the sermon start and end in section 3 before choosing subtitles. SermonClip uses those selected boundaries to align the SRT against the correct audio.", tone: .warning)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ImportCard(title: "Subtitles", detail: subtitleDetail, icon: "captions.bubble.fill",
                                   reservesRemovalSpace: store.subtitleURL != nil || !store.cues.isEmpty) {
                            importer = .srt; showingImporter = true
                        }.disabled((!store.boundariesConfirmed || (store.sermonRange?.duration ?? 0) <= 0))
                        .overlay(alignment: .trailing) {
                            if store.subtitleURL != nil || !store.cues.isEmpty {
                                SermonClipButton("Remove subtitles", systemImage: "xmark.circle.fill") { store.removeSubtitles() }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(SermonClipDestructiveStyle())
                                    .frame(width: ImportCard.removalWidth)
                                    .padding(.trailing, ImportCard.fileIconWidth + 2 * ImportCard.edgeInset)
                                    .disabled(store.isExporting)
                                    .help("Remove subtitles from this project without deleting the original file.")
                            }
                        }
                        if store.generatedCoverage != nil {
                            SermonClipButton("Review app-generated subtitles") { showGeneratedSubtitles = true }
                                .buttonStyle(SermonClipLinkStyle())
                            SermonClipButton("Regenerate for current sermon range") { store.regenerateLocalCaptions() }
                                .buttonStyle(SermonClipLinkStyle())
                        }
                        if store.subtitleURL != nil {
                            SermonClipButton("Review adjusted subtitles") { showAdjustedSubtitles = true }
                                .buttonStyle(SermonClipLinkStyle())
                                .disabled(store.isAnalyzing || (store.captionTiming == nil && store.subtitleAlignmentResult == nil))
                        }
                    }
                if store.subtitleURL == nil {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Generate English subtitles for the selected sermon only.").font(.headline)
                            Text("SermonClip will benchmark this Mac first and show an estimated completion time before starting.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if case let .localTranscription(estimate) = store.captionPlan {
                            SermonClipButton("Create subtitles (~\(store.format(estimate)))") { store.createLocalCaptions() }
                                .buttonStyle(SermonClipStandardPrimaryStyle())
                        } else if store.captionPlan == .localTranscribing || store.captionPlan == .localTranscriptionPendingEstimate {
                            ProgressView().controlSize(.small)
                        } else {
                            SermonClipButton(store.captionPlan == .generated ? "Estimate regeneration" : "Estimate local subtitles") { store.prepareLocalTranscription() }
                        }
                    }
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if store.captionPlan == .localTranscribing {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Creating local subtitles…")
                            Spacer()
                            Text("\(Int(store.localSubtitleProgress * 100))%").monospacedDigit()
                        }
                        ProgressView(value: store.localSubtitleProgress)
                        Text(store.localSubtitleEstimate).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }

                    if store.isAnalyzing && (store.captionPlan == .localTranscribing || store.captionPlan == .localTranscriptionPendingEstimate || store.subtitleAlignmentProgress > 0) {
                        SermonClipButton(store.subtitleURL != nil ? "Cancel subtitle alignment" : "Cancel subtitle processing") { store.cancelSubtitleWork() }
                    }
                    if store.subtitleURL != nil && !store.cues.isEmpty {
                        HStack {
                            if store.importedSubtitlesNeedResync {
                                StatusNotice(text: "The sermon boundaries changed after this SRT was aligned. Export will trim subtitle cues outside the selected sermon; re-sync is optional if the timing needs correction.", tone: .warning)
                            }
                            Spacer()
                        }
                        if store.captionTiming == nil {
                            StatusNotice(text: "SermonClip can align this SRT automatically by matching short audio samples against its text.", tone: .normal)
                        }
                        if store.isAnalyzing && store.subtitleAlignmentProgress > 0 {
                            VStack(alignment: .leading, spacing: 5) {
                                ProgressView(value: store.subtitleAlignmentProgress)
                                Text(store.subtitleAlignmentEstimate).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let result = store.subtitleAlignmentResult {
                            let tone: NoticeTone = result.confidence >= 0.75 ? .normal : .warning
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("SRT alignment result").font(.headline)
                                    Spacer()
                                    Text("\(Int(result.confidence * 100)) / 100 alignment score")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(tone == .normal ? .green : .orange)
                                }
                                Text("Earliest verified match").font(.caption.weight(.semibold))
                                Text("“\(result.firstMatch)”").font(.caption).foregroundStyle(.secondary)
                                Text("Latest verified match").font(.caption.weight(.semibold))
                                Text("“\(result.lastMatch)”").font(.caption).foregroundStyle(.secondary)
                                let alignedCues = store.cues.filter { cue in
                                    let offset = store.captionTiming?.sourceOffset ?? result.sourceOffset
                                    return cue.end + offset > (store.sermonRange?.start ?? 0) && cue.start + offset < (store.sermonRange?.end ?? 0)
                                }.count
                                Text("\(result.anchorCount) agreeing phrase matches · \(Int(result.wordAgreement * 100))% wording agreement · \(String(format: "%.2f", result.timingSpread))s difference between timing estimates.\n\(alignedCues) subtitle cues fall within the selected sermon. This score summarizes the evidence; it is not a probability or a guarantee of exact sentence timing.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background((tone == .normal ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke((tone == .normal ? Color.green : Color.orange).opacity(0.22)))
                        }
                    }
                    if !store.cues.isEmpty {
                        SubtitleSynchronizationView()
                    }
                    if store.generatedSubtitlesNeedExpansion {
                        StatusNotice(text: "The sermon now extends beyond the transcribed range. Regenerate subtitles for the new selection, or restore the previous boundaries.", tone: .warning)
                    }
                    if store.subtitleURL != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            if let subtitleNotice = store.notices[.subtitles],
                               !subtitleNotice.isSubtitleTimingConfirmation {
                                StatusNotice(text: subtitleNotice.text, tone: subtitleNotice.tone)
                            }
                            HStack {
                                Text("If you adjust the sermon boundaries after importing and aligning your subtitles, you can re-sync the subtitles here.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                SermonClipButton("Re-sync subtitles") { store.autoAlignImportedSubtitles() }
                                    .fixedSize()
                                    .disabled(store.isAnalyzing || (!store.boundariesConfirmed || (store.sermonRange?.duration ?? 0) <= 0))
                            }.buttonStyle(SermonClipStandardPrimaryStyle())
                                if store.captionTiming == nil, store.subtitleAlignmentResult != nil {
                                    SermonClipButton("Accept alignment") { store.acceptSubtitleAlignment() }
                                        .buttonStyle(SermonClipStandardPrimaryStyle())
                                }
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    } else if store.notices[.subtitles]?.isSubtitleTimingConfirmation != true {
                        notice(.subtitles)
                    }
                }.disabled(store.sourceURL == nil || (!store.boundariesConfirmed || (store.sermonRange?.duration ?? 0) <= 0) || store.isExporting)
                WorkflowSection(title: "5 · Export & Upload") {
                HStack {
                    Label(store.exportDirectory?.path ?? "Choose an Export Folder", systemImage: "folder.fill")
                        .lineLimit(1)
                        .foregroundStyle(store.exportDirectory == nil ? .orange : .secondary)
                    Spacer()
                    SermonClipButton(store.exportDirectory == nil ? "Choose folder" : "Change") { importer = .exportFolder; showingImporter = true }
                }
                .id("export-upload")
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                YouTubeUploadView(chooseThumbnail: chooseThumbnail,
                                  goToYouTubeSettings: { section = .youtube })
                    .environmentObject(youtube).environmentObject(store)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Export Name").font(.headline)
                    ExportNameEditor(draft: store.exportNameDraft) { [weak store] value in
                        if store?.exportName != value { store?.exportName = value }
                    }
                        .disabled(store.isExporting)
                    Text("Used for the selected exports and any SRT. Extensions are added automatically; existing filenames receive a numbered suffix.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let currentExportBlockers = exportBlockers
                if !currentExportBlockers.isEmpty {
                    StatusNotice(text: currentExportBlockers.joined(separator: "\n"), tone: .warning)
                }
                HStack(spacing: 12) {
                    Toggle(isOn: $store.exportMP4) {
                        Text(youtube.enabled ? "MP4 (Required for YouTube Upload)" : "MP4")
                            .textCase(.uppercase).tracking(1)
                    }
                        .toggleStyle(.checkbox)
                        .handCursor()
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .disabled(youtube.enabled || store.isExporting || youtube.busy)
                        .help(youtube.enabled ? "MP4 is required for YouTube upload." : "Export the trimmed video with its selected bumpers.")
                    Toggle(isOn: $store.exportMP3) { Text("MP3").tracking(1) }
                        .toggleStyle(.checkbox)
                        .handCursor()
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .disabled(store.isExporting || youtube.busy)
                        .help("Export 128 kbps audio. Video bumpers are included; JPG bumpers are omitted.")
                    Spacer(minLength: 0)
                }
                SermonClipButton {
                    store.exportNameDraft.flush()
                    if youtube.enabled { confirmUpload = true } else { store.export() }
                } label: {
                    Label(store.isExporting ? "Exporting…" : youtube.enabled ? "Export & Upload" : "Export \(store.selectedExportFormats)",
                          systemImage: youtube.enabled ? "arrow.up.circle.fill" : "square.and.arrow.up")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                    .buttonStyle(SermonClipLargePrimaryStyle())
                    .disabled(!currentExportBlockers.isEmpty || store.isExporting || youtube.busy)
                    .help(currentExportBlockers.isEmpty ? "Export the selected sermon" : currentExportBlockers.joined(separator: "\n"))
                if store.isExporting {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(store.exportStage)
                            Spacer()
                            Text("\(Int(store.exportProgress * 100))%").monospacedDigit()
                        }
                        ProgressView(value: store.exportProgress)
                        Text(store.exportEstimate).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let exportNotice = store.notices[.export], exportNotice.text.hasPrefix("Exported ") {
                    StatusNotice(text: exportNotice.text, tone: exportNotice.tone,
                                 actionTitle: "Open export folder", action: openExportFolder,
                                 verticalAlignment: .center)
                }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: importer?.types ?? []) { result in
                if case let .failure(error) = result, (error as NSError).code != NSUserCancelledError {
                    let area: ProjectArea = importer == .srt ? .subtitles : importer == .exportFolder ? .export : .source
                    if importer == .thumbnail { youtube.report(error.localizedDescription, in: .thumbnail, tone: .error) }
                    else { store.report(error.localizedDescription, in: area, tone: .error) }
                }
                guard case let .success(url) = result, let importer else { return }
                switch importer {
                case .video: store.importSource(url)
                case .srt: store.importSubtitles(url)
                case .opening: store.addBumper(url, kind: .opening)
                case .closing: store.addBumper(url, kind: .closing)
                case .exportFolder: store.setExportDirectory(url)
                case .thumbnail: youtube.selectThumbnail(url)
                }
                self.importer = nil
            }
            .alert("Export and upload to YouTube?", isPresented: $confirmUpload) {
                SermonClipButton("Cancel", role: .cancel) { }
                SermonClipButton("Export & Upload") { store.export(youtube: youtube) }
            } message: {
                Text("\(youtube.title)\nChannel: \(youtube.connection?.channelName ?? "Not connected")\nVisibility: \(youtube.visibility.title)\n\nThe final MP4, title, description, and selected thumbnail will be sent to YouTube. Public videos may become visible before the thumbnail finishes uploading. Your selected local exports will be kept.")
            }
            .alert("Remove saved upload retry record?", isPresented: $confirmDiscardSavedUpload) {
                SermonClipButton("Cancel", role: .cancel) { }
                SermonClipButton("Remove retry record", role: .destructive) { youtube.discardPending() }
            } message: {
                Text("This removes SermonClip’s saved retry information. It does not delete local files or any video already uploaded to YouTube.")
            }
            .sheet(isPresented: $showGeneratedSubtitles) {
                SubtitleReviewView(cues: store.cues)
            }
            .sheet(isPresented: $showAdjustedSubtitles) {
                AdjustedSubtitleReviewView().environmentObject(store)
            }
        }
    }

    @ViewBuilder private func notice(_ area: ProjectArea) -> some View {
        if let notice = store.notices[area] { StatusNotice(text: notice.text, tone: notice.tone) }
    }

    private var exportBlockers: [String] {
        var reasons = store.exportBlockers()
        // Progress is already shown below the export button; don't surface the
        // transient "already running" blocker as a second changing alert.
        if store.isExporting {
            reasons.removeAll { $0 == "An export is already running." }
        }
        if youtube.enabled {
            if youtube.connection == nil { reasons.append("Connect your YouTube channel, or turn off upload.") }
            // A job is also present during an active upload. Only surface this
            // as a blocker once the upload has stopped and needs a retry or
            // explicit discard.
            if youtube.job != nil && !youtube.busy {
                reasons.append("Resume or discard the saved upload before creating another.")
            }
            if let id = youtube.playlistID, !youtube.playlists.contains(where: { $0.id == id }) {
                reasons.append("Refresh playlists or choose No playlist.")
            }
            do { try YouTubeUploadDraft(title: youtube.title, description: youtube.videoDescription, visibility: youtube.visibility).validate() }
            catch { reasons.append("YouTube: " + error.localizedDescription) }
        }
        return reasons
    }

    private func openExportFolder() {
        guard let folder = store.exportDirectory else { return }
        NSWorkspace.shared.open(folder)
    }

    private var subtitleDetail: String {
        store.generatedCoverage != nil ? "Using app-generated subtitles" : store.subtitleURL?.lastPathComponent ?? "No subtitle file selected"
    }

    private var bumperPickers: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Opening Bumper:").fixedSize(horizontal: true, vertical: false)
                openingBumperPicker
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("Closing Bumper:").fixedSize(horizontal: true, vertical: false)
                closingBumperPicker
            }
        }
    }

    private var openingBumperPicker: some View {
        Picker("Opening Bumper:", selection: $store.openingBumperID) {
            Text("None").tag(UUID?.none)
            ForEach(store.openingBumpers) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
        .sermonClipDropdownStyle()
        .frame(width: 140)
        .onChange(of: store.openingBumperID) { store.updateSelections() }
    }

    private var closingBumperPicker: some View {
        Picker("Closing Bumper:", selection: $store.closingBumperID) {
            Text("None").tag(UUID?.none)
            ForEach(store.closingBumpers) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
        .sermonClipDropdownStyle()
        .frame(width: 140)
        .onChange(of: store.closingBumperID) { store.updateSelections() }
    }

    private func chooseThumbnail() {
        importer = .thumbnail
        showingImporter = true
    }

    @ViewBuilder private var reviewSection: some View {
        if let range = store.sermonRange {
            VStack(alignment: .leading, spacing: 14) {
                Text(range.explanation).foregroundStyle(.secondary)
                if let sourceURL = store.sourceURL {
                    ReviewPlayer(sourceURL: sourceURL, range: range, player: $player, isActive: section == .project || section == nil)
                        .id(sourceURL)
                        .environmentObject(store)
                }
                if range.end <= range.start {
                    StatusNotice(text: "Start must be earlier than End. Mark a different start or end time before exporting.", tone: .warning)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        SermonClipButton { store.setStart(player?.currentTime().seconds ?? range.start) } label: {
                            Label("Mark playhead as start", systemImage: "arrowtriangle.down.fill")
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(SermonClipUnifiedButtonStyle(kind: .trimStart))

                        BoundaryControl(label: "Start", seconds: range.start, setTime: {
                            store.setStart($0); return store.sermonRange?.start ?? range.start
                        }, nudge: store.nudgeStart)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 8) {
                        SermonClipButton { store.setEnd(player?.currentTime().seconds ?? range.end) } label: {
                            Label("Mark playhead as end", systemImage: "arrowtriangle.down.fill")
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(SermonClipUnifiedButtonStyle(kind: .trimEnd))

                        BoundaryControl(label: "End", seconds: range.end, setTime: {
                            store.setEnd($0); return store.sermonRange?.end ?? range.end
                        }, nudge: store.nudgeEnd)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Text("Duration \(store.format(range.duration)) · Type a time and press Return, or adjust by 1 or 5 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                SermonClipButton("Find nearby pauses") { store.refinePauses() }.disabled(store.isAnalyzing || range.duration <= 0)
                Text("Set the first and last words, then find nearby pauses. Review the cut to exclude the next speaker or unrelated remarks. Manual boundaries are exported exactly as selected.")
                    .font(.footnote).foregroundStyle(.secondary)

              }
        }
    }
}

private struct SubtitleReviewView: View {
    let cues: [SubtitleCue]
    var title = "App-generated subtitles"
    var detail = "Review the generated wording and timing before exporting. The displayed groups are arranged for natural speech-sized subtitle blocks."
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                SermonClipButton("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(detail)
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                if cues.isEmpty { Text("No subtitles fall within the selected sermon.").padding() }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(index + 1)  \(BoundaryTimecode.format(cue.start)) → \(BoundaryTimecode.format(cue.end))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Text(cue.text).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 500)
    }
}

private struct AdjustedSubtitleReviewView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var cues: [SubtitleCue]?
    @State private var error: String?

    var body: some View {
        Group {
            if let cues {
                SubtitleReviewView(cues: cues, title: "Adjusted subtitles",
                    detail: "Export timestamps include the current synchronization, breathing room, sermon trimming, and opening bumper. Original wording and cue grouping are preserved."
                        + (store.captionTiming == nil ? " This previews the proposed alignment; accept or adjust it before exporting." : ""))
            } else {
                VStack(spacing: 16) {
                    if let error { StatusNotice(text: error, tone: .error) }
                    else { ProgressView("Preparing adjusted subtitles…") }
                    SermonClipButton("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }.padding(24).frame(minWidth: 600, minHeight: 300)
            }
        }
        .task {
            do { cues = try await store.adjustedSubtitlesForReview() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ReviewPlayer: View {
    @EnvironmentObject private var store: ProjectStore
    let sourceURL: URL
    let range: SermonRange
    @Binding var player: AVPlayer?
    let isActive: Bool
    @State private var waveformZoomed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeReviewPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            AudioWaveformView(sourceURL: sourceURL, duration: store.sourceDuration, range: range, player: player, zoomed: $waveformZoomed)
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let current = player?.currentTime().seconds ?? 0
                HStack(spacing: 10) {
                    SermonClipButton {
                        if player?.rate ?? 0 > 0 { player?.pause() } else { player?.play() }
                    } label: {
                        let playing = (player?.rate ?? 0) > 0
                        Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                            .frame(minWidth: 92, minHeight: 36)
                    }
                    .buttonStyle(SermonClipStandardPrimaryStyle())
                    .controlSize(.large)
                    .help((player?.rate ?? 0) > 0 ? "Pause" : "Play")
                    Text(BoundaryTimecode.format(current)).monospacedDigit().font(.headline)
                    Toggle("15-second detail", isOn: $waveformZoomed).toggleStyle(.checkbox).handCursor()
                }
                .controlSize(.small)
            }

        }
        .onAppear {
            player?.pause()
            let newPlayer = AVPlayer(url: sourceURL)
            player = newPlayer
            newPlayer.seek(to: CMTime(seconds: max(0, range.start), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onDisappear { player?.pause() }
        .onChange(of: isActive) { if !isActive { player?.pause() } }
        .onChange(of: range.start) { previewBoundary(range.start) }
        .onChange(of: range.end) { previewBoundary(range.end) }
    }

    private func previewBoundary(_ seconds: TimeInterval) {
        player?.pause()
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func seek(_ seconds: TimeInterval, on target: AVPlayer? = nil) {
        let current = target ?? player
        current?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current?.play()
    }
}


private struct SubtitleSynchronizationView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var syncPlayer: AVPlayer?
    @State private var selectedCue = 0
    @State private var waveformZoomed = false

    var body: some View {
        if !store.cues.isEmpty, let sourceURL = store.sourceURL, let range = store.sermonRange {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Subtitle Preview & Timing").font(.headline)
                    Spacer()
                }
                Text("Preview subtitles over the video and optionally adjust their timing. The wording stays unchanged; timing adjustments move all subtitles together. Select a cue and place the playhead where it should first appear, then choose Align Selected Subtitle.")
                    .font(.caption).foregroundStyle(.secondary)
                ZStack(alignment: .bottom) {
                    NativeReviewPlayer(player: syncPlayer)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    subtitleOverlay
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
                AudioWaveformView(sourceURL: sourceURL, duration: store.sourceDuration, range: range, player: syncPlayer, zoomed: $waveformZoomed, subtitleStart: selectedSubtitleStart)
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    HStack(spacing: 10) {
                        SermonClipButton {
                            if syncPlayer?.rate ?? 0 > 0 { syncPlayer?.pause() } else { syncPlayer?.play() }
                        } label: {
                            Image(systemName: (syncPlayer?.rate ?? 0) > 0 ? "pause.fill" : "play.fill")
                        }
                        Text(BoundaryTimecode.format(syncPlayer?.currentTime().seconds ?? range.start)).monospacedDigit().font(.headline)
                        Toggle("15-second detail", isOn: $waveformZoomed).toggleStyle(.checkbox).handCursor()
                        Spacer()
                    }
                    .controlSize(.small)
                }
                Picker("Subtitle cue", selection: Binding(get: { selectedCue }, set: { index in
                    selectedCue = index
                    seekToSelectedCue(index)
                })) {
                    ForEach(Array(store.cues.indices), id: \.self) { index in
                        Text(verbatim: subtitleTitle(index)).tag(index)
                    }
                }.sermonClipDropdownStyle()
                if store.cues.indices.contains(selectedCue) {
                    Text(store.cues[selectedCue].text).textSelection(.enabled)
                    HStack {
                        Text(store.subtitleURL != nil
                             ? "Pause about 1/2 a second before the first spoken word, then align it to the playhead. This adjusts all subtitles together."
                             : "Pause where the selected subtitle should first appear, then align it to the playhead. This adjusts all subtitles together.")
                            .font(.caption).foregroundStyle(.secondary)
                        SermonClipButton { matchSelectedCue() } label: {
                            Text("Align selected subtitle with playhead")
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(SermonClipStandardPrimaryStyle())
                        .controlSize(.large)
                        .disabled(syncPlayer == nil)
                    }
                    HStack {
                        SermonClipButton("−0.5 sec") { store.adjustCaptionTiming(by: -0.5) }
                            .disabled(effectiveTiming == nil)
                        SermonClipButton("+0.5 sec") { store.adjustCaptionTiming(by: 0.5) }
                            .disabled(effectiveTiming == nil)
                        if store.subtitleURL != nil {
                            SermonClipButton("Use original SRT timing") { store.confirmCaptionTiming(offset: 0) }
                        } else {
                            SermonClipButton("Restore generated timing") { store.restoreGeneratedSubtitleTiming() }
                        }
                    }
                }
                if let timing = effectiveTiming {
                    let adjustment = timing.sourceOffset - (store.subtitleURL == nil ? store.generatedCoverage?.start ?? 0 : 0)
                    Text("Current timing adjustment: \(String(format: "%+.1f", adjustment)) seconds. This offset applies to every subtitle.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let subtitleNotice = store.notices[.subtitles],
                   subtitleNotice.isSubtitleTimingConfirmation {
                    StatusNotice(text: subtitleNotice.text, tone: subtitleNotice.tone)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .onAppear {
                if syncPlayer == nil {
                    let newPlayer = AVPlayer(url: sourceURL)
                    syncPlayer = newPlayer
                    newPlayer.seek(to: CMTime(seconds: max(0, range.start), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                selectFirstSermonCue()
            }
            .onDisappear { syncPlayer?.pause() }
            .onChange(of: store.subtitleAlignmentResult) { _, _ in selectFirstSermonCue() }
            .onChange(of: store.cues) { _, _ in selectFirstSermonCue() }
            .onChange(of: range) { _, _ in selectFirstSermonCue() }
            .onChange(of: range.start) { syncPlayer?.pause(); syncPlayer?.seek(to: CMTime(seconds: $0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            .onChange(of: range.end) { _ in syncPlayer?.pause() }
        }
    }

    private func matchSelectedCue() {
        guard let player = syncPlayer, store.displaySubtitleCues.indices.contains(selectedCue) else { return }
        player.pause()
        // Match against the cue timing shown in the player and exported SRT,
        // including its available breathing room.
        let timing = CaptionTiming.matching(cue: store.displaySubtitleCues[selectedCue], sourceTime: player.currentTime().seconds)
        store.confirmCaptionTiming(offset: timing.sourceOffset)
    }

    private var selectedSubtitleStart: TimeInterval? {
        let cues = store.displaySubtitleCues
        guard cues.indices.contains(selectedCue) else { return nil }
        return cues[selectedCue].start + (effectiveTiming?.sourceOffset ?? 0)
    }

    private func selectFirstSermonCue() {
        guard let range = store.sermonRange, let timing = effectiveTiming else { selectedCue = 0; return }
        selectedCue = store.cues.indices.first {
            store.cues[$0].end + timing.sourceOffset > range.start &&
            store.cues[$0].start + timing.sourceOffset < range.end
        } ?? 0
    }

    private func subtitleTitle(_ index: Int) -> String {
        String(index + 1) + ": " + String(store.cues[index].text.prefix(90))
    }

    private func seekToSelectedCue(_ index: Int) {
        let cues = store.displaySubtitleCues
        guard let player = syncPlayer, cues.indices.contains(index) else { return }
        let timing = effectiveTiming ?? CaptionTiming(sourceOffset: 0)
        player.pause()
        player.seek(to: CMTime(seconds: max(0, cues[index].start + timing.sourceOffset), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @ViewBuilder
    private var subtitleOverlay: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let time = syncPlayer?.currentTime().seconds ?? 0
            let text = (effectiveTiming ?? CaptionTiming(sourceOffset: 0)).sourceCues(store.displaySubtitleCues).filter { cue in
                cue.start <= time && cue.end > time
            }
                .map(\.text).joined(separator: "\n")
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: 650)
            }
        }
    }

    private var effectiveTiming: CaptionTiming? {
        store.captionTiming ?? store.subtitleAlignmentResult.map { CaptionTiming(sourceOffset: $0.sourceOffset) }
    }
}

// Avoid the _AVKit_SwiftUI generic metadata crash seen during video import.
// AVPlayerView provides the same native playback and scrubbing controls directly.
struct NativeReviewPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> ScrollingReviewPlayerView {
        let view = ScrollingReviewPlayerView()
        view.playerView.controlsStyle = .none
        view.playerView.videoGravity = .resizeAspect
        view.playerView.allowsVideoFrameAnalysis = false
        view.playerView.player = player
        return view
    }

    func updateNSView(_ view: ScrollingReviewPlayerView, context: Context) {
        if view.playerView.player !== player { view.playerView.player = player }
    }

    static func dismantleNSView(_ view: ScrollingReviewPlayerView, coordinator: ()) {
        view.playerView.player?.pause()
        view.playerView.player = nil
    }
}

final class ScrollingReviewPlayerView: NSView {
    let playerView = AVPlayerView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(playerView)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor), playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor), playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .scrollWheel, bounds.contains(convert(point, from: superview)) { return self }
        return super.hitTest(point)
    }
    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) }
        else { nextResponder?.scrollWheel(with: event) }
    }
}

private enum ImportTarget {
    case video, srt, opening, closing, exportFolder, thumbnail
    var types: [UTType] {
        switch self {
        case .video, .opening, .closing: [.mpeg4Movie, .movie]
        case .srt: [UTType(filenameExtension: "srt") ?? .plainText]
        case .exportFolder: [.folder]
        case .thumbnail: [.jpeg]
        }
    }
}

private struct ImportCard: View {
    static let edgeInset: CGFloat = 16
    static let fileIconWidth: CGFloat = 40
    static let removalWidth: CGFloat = 44
    let title: String; let detail: String; let icon: String
    var reservesRemovalSpace = false
    let action: () -> Void
    var body: some View {
        SermonClipButton(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title)
                    .foregroundStyle(Color(red: 173.0 / 255, green: 144.0 / 255, blue: 98.0 / 255))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(detail).textCase(nil).tracking(0).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .frame(width: Self.fileIconWidth, alignment: .trailing)
                    .padding(.leading, reservesRemovalSpace ? Self.removalWidth + Self.edgeInset : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(.horizontal, Self.edgeInset)
            .padding(.vertical, 12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("Choose (title.lowercased())")
    }
}

private struct BoundaryControl: View {
    let label: String
    let seconds: TimeInterval
    let setTime: (TimeInterval) -> TimeInterval
    let nudge: (TimeInterval) -> Void
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            TextField("H:MM:SS", text: $draft)
                .sermonClipInputStyle()
                .font(.body.monospacedDigit())
                .frame(minHeight: 48)
                .accessibilityLabel("\(label) time")
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { if !editing { commit() } }
            HStack(spacing: 6) {
                ForEach([-5, -1, 1, 5], id: \.self) { delta in
                    SermonClipButton("\(delta > 0 ? "+" : "−")\(abs(delta))s") {
                        nudge(Double(delta))
                        draft = BoundaryTimecode.format(seconds)
                        invalid = false
                    }.help("Move \(label.lowercased()) by \(delta) seconds")
                }
            }.controlSize(.small)
            if invalid { StatusNotice(text: "Use H:MM:SS, M:SS, or seconds.", tone: .error) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { draft = BoundaryTimecode.format(seconds) }
        .onChange(of: seconds) { draft = BoundaryTimecode.format(seconds); invalid = false }
    }

    private func commit() {
        guard let time = BoundaryTimecode.parse(draft) else { invalid = true; return }
        draft = BoundaryTimecode.format(setTime(time))
        invalid = false
        // Keep edits within the source; markers may cross while the user adjusts the cut.
        editing = false
    }
}

private struct BumperLibraryView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var addingKind: BumperKind = .opening
    @State private var showingImport = false
    @State private var bumperToDelete: Bumper?
    @State private var confirmingDeletion = false
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    var body: some View {
        VStack(alignment: .leading) {
            if let notice = store.notices[.bumpers] {
                StatusNotice(text: notice.text, tone: notice.tone)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            Text("Add MP4 videos or JPG images to your bumper library. JPG bumpers are displayed for 6 seconds before the sermon begins or after it ends. JPG bumpers are not included in the MP3 export. Imported bumpers are copied into the library, and you can safely move or delete the originals afterward.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Picker("For new projects:", selection: $store.preferences.startupBumperMode) {
                ForEach(StartupBumperMode.allCases) { Text($0.title).tag($0) }
            }.sermonClipDropdownStyle().onChange(of: store.preferences.startupBumperMode) { store.updateSelections() }
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(BumperKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(kind.title).font(.title2.bold())
                                Spacer()
                                SermonClipButton("Add \(kind.title) Bumper") {
                                    addingKind = kind
                                    showingImport = true
                                }
                            .buttonStyle(SermonClipStandardPrimaryStyle())
                            }
                            Divider()
                        }
                        .padding(.bottom, 8)
                        let bumpers = store.bumpers.filter { $0.kind == kind }
                        ForEach(Array(bumpers.enumerated()), id: \.element.id) { bumperIndex, bumper in
                            HStack(alignment: .center) {
                                BumperThumbnailView(bumper: bumper)
                                VStack(alignment: .leading, spacing: 6) {
                                    if renamingID == bumper.id {
                                        HStack {
                                            TextField("Bumper Name", text: $renameDraft)
                                                .sermonClipInputStyle()
                                                .frame(width: 220)
                                            SermonClipButton("Save") {
                                                store.renameBumper(bumper, to: renameDraft)
                                                renamingID = nil
                                            }
                                            .buttonStyle(SermonClipLinkStyle())
                                            .font(.caption)
                                            .fixedSize()
                                            SermonClipButton("Cancel") { renamingID = nil }
                                                .buttonStyle(SermonClipLinkStyle())
                                                .font(.caption)
                                                .fixedSize()
                                        }
                                    } else {
                                        HStack(spacing: 8) {
                                            Text(bumper.name)
                                            SermonClipButton("Rename") {
                                                renameDraft = bumper.name
                                                renamingID = bumper.id
                                            }
                                            .buttonStyle(SermonClipLinkStyle())
                                            .font(.caption)
                                            .fixedSize()
                                        }
                                    }
                                    Label(bumper.media.title, systemImage: bumper.media == .image ? "photo" : "video.fill")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                let defaultID = kind == .opening ? store.preferences.defaultOpeningID : store.preferences.defaultClosingID
                                if defaultID == bumper.id { Label("Default", systemImage: "star.fill").foregroundStyle(.secondary) }
                                else {
                                    SermonClipButton("Set default") { store.makeDefault(bumper) }
                                        .buttonStyle(SermonClipSecondaryStyle())
                                }
                                if !bumper.isBundled {
                                    SermonClipButton("Delete…", role: .destructive) {
                                        bumperToDelete = bumper
                                        confirmingDeletion = true
                                    }
                                    .buttonStyle(SermonClipDestructiveStyle())
                                    .disabled(store.isExporting)
                                }
                            }
                            .padding(.top, bumper.id == bumpers.first?.id ? 8 : 0)
                            if bumperIndex < bumpers.count - 1 {
                                Divider()
                                    .padding(.vertical, 8)
                            }
                        }

                    }
                    .modifier(WorkflowCardStyle())
                }
            }
            .padding(.top, 12)
        }.padding(.horizontal, 20).padding(.vertical, 32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .fileImporter(isPresented: $showingImport, allowedContentTypes: [.mpeg4Movie, .jpeg]) { result in
                if case let .success(url) = result { store.addBumper(url, kind: addingKind) }
                if case let .failure(error) = result, (error as NSError).code != NSUserCancelledError {
                    store.report(error.localizedDescription, in: .bumpers, tone: .error)
                }
            }
            .alert("Permanently delete bumper?", isPresented: $confirmingDeletion, presenting: bumperToDelete) { bumper in
                SermonClipButton("Cancel", role: .cancel) { bumperToDelete = nil }
                SermonClipButton("Delete permanently", role: .destructive) {
                    store.deleteBumper(bumper)
                    bumperToDelete = nil
                }
            } message: { bumper in
                Text("\"\(bumper.name)\" will be permanently removed from the library. This cannot be undone. Any default or current selection using it will be cleared. Your original imported file will not be deleted.")
            }
    }
}

private struct BumperThumbnailView: View {
    @EnvironmentObject private var store: ProjectStore
    let bumper: Bumper
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay { Image(systemName: bumper.media == .image ? "photo" : "film") .foregroundStyle(.secondary) }
            }
        }
        .frame(width: 96, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: bumper.id) {
            guard let url = try? store.bumperURL(bumper) else { return }
            if bumper.media == .image {
                image = NSImage(contentsOf: url)
            } else {
                do {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    let time = CMTime(seconds: max(0, duration.seconds / 2), preferredTimescale: 600)
                    image = NSImage(cgImage: try generator.copyCGImage(at: time, actualTime: nil), size: .zero)
                } catch { }
            }
        }
    }
}

struct SidebarNavigationStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SidebarNavigationBody(selected: selected, configuration: configuration)
    }
}

private struct SidebarNavigationBody: View {
    let selected: Bool
    let configuration: ButtonStyleConfiguration
    @Environment(\.controlActiveState) private var activeState
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(selected ? Color.black : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if !selected && hovering {
                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
            .opacity(activeState == .inactive ? 0.55 : configuration.isPressed ? 0.75 : 1)
            .onHover { hovering = $0 }
    }
}

struct MainSidebarNavigationStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        MainSidebarNavigationBody(selected: selected, configuration: configuration)
    }
}

private struct MainSidebarNavigationBody: View {
    let selected: Bool
    let configuration: ButtonStyleConfiguration
    @Environment(\.controlActiveState) private var activeState
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Reserve the vertical selection bar and the same 14-point gap
            // between the bar and the button edge for the label content.
            .padding(.leading, 36)
            .padding(.trailing, 36)
            .padding(.vertical, 12)
            .background {
                if selected || hovering {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05))
                }
            }
            .overlay(alignment: .trailing) {
                if hovering && !selected {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(SermonClipPalette.sidebarOutline)
                            .frame(width: 8, height: proxy.size.height * 0.72)
                            .offset(x: proxy.size.width - 22, y: proxy.size.height * 0.14)
                            .opacity(0.1)
                    }
                }
            }
            .contentShape(Rectangle())
            .opacity(activeState == .inactive ? 0.55 : configuration.isPressed ? 0.75 : 1)
            .onHover { hovering = $0 }
    }
}

private struct SidebarRowFrames: PreferenceKey {
    static var defaultValue: [MainSection: CGRect] { [:] }
    static func reduce(value: inout [MainSection: CGRect], nextValue: () -> [MainSection: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// One persistent background moves between measured rows; it isn't recreated
/// inside separate button-style hosts when the selection changes.
struct SidebarSelectionHighlight: View {
    let frame: CGRect
    let selectionKey: String
    let reduceMotion: Bool
    var outlineOnly = false
    @Environment(\.controlActiveState) private var activeState
    @State private var displayedOrigin: CGPoint?
    @State private var barOpacity = 0.0
    @State private var displayedSelection = ""

    init(frame: CGRect, selectionKey: String = "", reduceMotion: Bool, outlineOnly: Bool = false) {
        self.frame = frame
        self.selectionKey = selectionKey
        self.reduceMotion = reduceMotion
        self.outlineOnly = outlineOnly
    }

    var body: some View {
        Color.clear.overlay(alignment: .topLeading) {
            Group {
                if outlineOnly {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(SermonClipPalette.sidebarOutline, lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(SermonClipPalette.secondaryFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(SermonClipPalette.hoverOverlayOpacity))
                        }
                    }
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: displayedOrigin?.x ?? frame.minX, y: displayedOrigin?.y ?? frame.minY)
            .opacity(activeState == .inactive ? 0.55 : 1)
        }
        .overlay(alignment: .topLeading) {
            if outlineOnly {
                RoundedRectangle(cornerRadius: 6)
                    .fill(SermonClipPalette.sidebarOutline)
                    .frame(width: 8, height: frame.height * 0.72)
                    .offset(x: frame.maxX - 22, y: frame.minY + frame.height * 0.14)
                    .opacity(barOpacity * (activeState == .inactive ? 0.55 : 1))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            displayedOrigin = frame.origin
            barOpacity = 1
            displayedSelection = selectionKey
        }
        .onChange(of: frame) { oldFrame, newFrame in
            // A window/sidebar resize changes the row dimensions as well as its
            // origin. Keep the highlight locked to that layout change instead
            // of animating it as though the user selected another section.
            if reduceMotion || oldFrame.size != newFrame.size {
                displayedOrigin = newFrame.origin
                barOpacity = 1
            } else if selectionKey.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedOrigin = newFrame.origin
                }
                flickerBar()
            }
        }
        .onChange(of: selectionKey) { _, newSelection in
            guard !newSelection.isEmpty else { return }
            guard displayedSelection != newSelection else { return }
            displayedSelection = newSelection
            if reduceMotion {
                displayedOrigin = frame.origin
                barOpacity = 1
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedOrigin = frame.origin
                }
                flickerBar()
            }
        }
    }

    private func flickerBar() {
        barOpacity = 0
        withAnimation(.easeIn(duration: 0.07)) { barOpacity = 0.9 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.linear(duration: 0.05)) { barOpacity = 0.15 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.easeOut(duration: 0.14)) { barOpacity = 1 }
        }
    }
}

private enum MainSection: String, CaseIterable, Identifiable {
    case project = "Project"
    case bumpers = "Bumper Library"
    case youtube = "YouTube Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .project: "scissors"
        case .bumpers: "rectangle.stack"
        case .youtube: "play.rectangle"
        }
    }
}

private extension View {
    func panelVisible(_ visible: Bool) -> some View {
        PersistentPanel(content: self, visible: visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(visible)
            .disabled(!visible)
            .accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
    }
}

/// Opacity alone leaves hidden NSTextView cursor regions active. Hide the native
/// page host while retaining its SwiftUI identity and unsaved editing state.
private struct PersistentPanel<Content: View>: NSViewRepresentable {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var youtube: YouTubeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: Content
    let visible: Bool
    func makeCoordinator() -> PanelAnimationCoordinator { PanelAnimationCoordinator() }
    func makeNSView(context: Context) -> PanelHostingView {
        let host = PanelHostingView(rootView: root)
        host.sizingOptions = []
        host.isHidden = !visible
        host.alphaValue = visible ? 1 : 0
        host.acceptsPanelInput = visible
        context.coordinator.visible = visible
        return host
    }
    func updateNSView(_ host: PanelHostingView, context: Context) {
        host.rootView = root
        host.acceptsPanelInput = visible
        host.window?.invalidateCursorRects(for: host)
        let coordinator = context.coordinator
        guard coordinator.visible != visible else { return }
        coordinator.visible = visible
        coordinator.generation += 1
        let generation = coordinator.generation
        if reduceMotion {
            host.alphaValue = visible ? 1 : 0
            host.isHidden = !visible
            return
        }
        host.isHidden = false
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.2
            host.animator().alphaValue = visible ? 1 : 0
        } completionHandler: {
            Task { @MainActor in
                guard coordinator.generation == generation else { return }
                host.isHidden = !visible
                host.window?.invalidateCursorRects(for: host)
            }
        }
    }
    private var root: AnyView {
        AnyView(content
            .environmentObject(store)
            .environmentObject(youtube)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .buttonStyle(SermonClipSecondaryStyle()))
    }
}

@MainActor
private final class PanelAnimationCoordinator {
    var visible: Bool?
    var generation = 0
}

private final class PanelHostingView: NSHostingView<AnyView> {
    var acceptsPanelInput = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsPanelInput ? super.hitTest(point) : nil
    }
}
