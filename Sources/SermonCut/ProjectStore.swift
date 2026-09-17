import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class ProjectStore: ObservableObject {
    @Published var sourceURL: URL? {
        didSet {
            if sourceURL != oldValue {
                bumperVideo.cancel()
                audioAnalysisTask?.cancel()
                bumperAttenuation = [:]
            }
        }
    }
    @Published var subtitleURL: URL?
    let exportNameDraft = ExportNameDraft()
    @Published var exportName = "" {
        didSet { exportNameDraft.replace(with: exportName) }
    }
    @Published private(set) var exportDirectory: URL?
    @Published var sourceDuration: TimeInterval = 0
    @Published var cues: [SubtitleCue] = []
    /// Immutable-in-project copy of the imported SRT. Alignment and trimming
    /// always restart from this copy when the sermon range changes.
    @Published private(set) var originalImportedCues: [SubtitleCue] = []
    @Published private(set) var captionTiming: CaptionTiming?
    @Published var captionPlan: CaptionPlan = .manualWithoutCaptions
    @Published var sermonRange: SermonRange?
    @Published private(set) var boundariesConfirmed = false
    private let bumperVideo = BumperVideoOptimizer()
    private var audioAnalysisTask: Task<Void, Never>?
    private var bumperAttenuation: [UUID: Double] = [:]

    @Published var openingBumperID: UUID?
    @Published var closingBumperID: UUID?
    @Published var isAnalyzing = false
    @Published private(set) var localSubtitleProgress = 0.0
    @Published private(set) var localSubtitleEstimate = ""
    @Published var isExporting = false
    @Published var exportMP4 = true {
        didSet {
            if youtubeRequiresMP4 && !exportMP4 { exportMP4 = true }
            prepareBumperVideo()
        }
    }
    @Published var exportMP3 = true
    @Published private(set) var youtubeRequiresMP4 = false

    func setYouTubeUploadRequirement(_ enabled: Bool) {
        youtubeRequiresMP4 = enabled
        if enabled && !exportMP4 { exportMP4 = true }
    }

    var selectedExportFormats: String {
        ([exportMP4 ? "MP4" : nil, exportMP3 ? "MP3" : nil].compactMap { $0 }
            + (cues.isEmpty ? [] : ["SRT"])).joined(separator: " + ")
    }
    @Published private(set) var exportProgress = 0.0
    @Published private(set) var exportStage = ""
    @Published private(set) var exportEstimate = "Estimating time remaining…"
    private var exportPhase = 0
    private var exportPhaseStarted = Date()

    private func beginExportPhase(_ phase: Int, label: String) {
        exportPhase = phase
        exportStage = label
        exportProgress = 0
        exportPhaseStarted = Date()
        exportEstimate = "Estimating time remaining…"
    }

    private func updateExportProgress(_ fraction: Double, phase: Int) {
        guard isExporting, phase == exportPhase else { return }
        exportProgress = max(exportProgress, min(1, fraction))
        let elapsed = Date().timeIntervalSince(exportPhaseStarted)
        if exportProgress >= 0.99 {
            exportEstimate = "Finalizing this stage…"
        } else if elapsed >= 3, exportProgress > 0.01 {
            let remaining = elapsed * (1 - exportProgress) / exportProgress
            exportEstimate = "About \(format(remaining)) remaining in this stage"
        }
    }
    @Published var status = "Choose a service video to begin."
    @Published private(set) var notices: [ProjectArea: ProjectNotice] = [:]
    @Published private(set) var generatedCoverage: SermonRange?
    @Published private(set) var subtitleAlignmentProgress = 0.0
    @Published private(set) var subtitleAlignmentEstimate = ""
    @Published private(set) var subtitleAlignmentResult: SubtitleAlignmentResult?
    @Published private(set) var subtitleAlignmentRange: SermonRange?
    private var noticeDismissalTasks: [ProjectArea: Task<Void, Never>] = [:]
    func report(_ text: String, in area: ProjectArea, tone: NoticeTone = .normal, dismissAfterSeconds: Double? = nil) {
        noticeDismissalTasks[area]?.cancel()
        noticeDismissalTasks[area] = nil
        status = text
        let notice = ProjectNotice(text: text, tone: tone)
        notices[area] = notice
        guard tone == .normal, let seconds = dismissAfterSeconds else { return }
        noticeDismissalTasks[area] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard !Task.isCancelled, let self, self.notices[area]?.id == notice.id else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.notices[area] = nil
            }
            self.noticeDismissalTasks[area] = nil
        }
    }

    var generatedSubtitlesNeedExpansion: Bool {
        guard let coverage = generatedCoverage, let range = sermonRange else { return false }
        return range.start < coverage.start - 0.01 || range.end > coverage.end + 0.01
    }

    func exportBlockers() -> [String] {
        var reasons: [String] = []
        if isExporting { reasons.append("An export is already running.") }
        if !exportMP4 && !exportMP3 { reasons.append("Select MP4 or MP3 to export.") }
        if sourceURL == nil || sourceDuration <= 0 { reasons.append("Choose a readable source video.") }
        if !boundariesConfirmed { reasons.append("Set the sermon start and end times in the trimming section.") }
        if let range = sermonRange {
            if !range.start.isFinite || !range.end.isFinite || range.start < 0 || range.end > sourceDuration || range.end <= range.start {
                reasons.append("Set valid sermon start and end times.")
            }
        } else { reasons.append("Select the sermon boundaries.") }
        if isAnalyzing { reasons.append("Wait for the current analysis, or cancel it.") }
        if subtitleURL != nil && cues.isEmpty { reasons.append("The SRT contains no usable subtitles. Choose another file or remove it.") }
        if !cues.isEmpty {
            if let timing = captionTiming, let range = sermonRange {
                if !timing.hasExportableCue(cues, selection: range) {
                    reasons.append("No subtitles overlap the sermon. Check synchronization or remove subtitles.")
                }
            } else { reasons.append("Confirm imported subtitle synchronization.") }
        }
        if generatedSubtitlesNeedExpansion { reasons.append("The selection extends beyond the generated subtitles. Regenerate them or restore the covered range.") }
        if exportDirectory == nil { reasons.append("Choose an export folder.") }
        do { _ = try MediaExporter.validatedExportName(exportName) }
        catch { reasons.append(error.localizedDescription) }
        return reasons
    }

    func cancelSubtitleWork() {
        takeOverManually()
        report("Subtitle processing cancelled. You can try again when ready.", in: .subtitles, tone: .warning)
    }

    func acceptSubtitleAlignment() {
        guard let result = subtitleAlignmentResult, let range = sermonRange else { return }
        captionTiming = CaptionTiming(sourceOffset: result.sourceOffset)
        subtitleAlignmentRange = range
        report("Accepted the imported SRT alignment. Preview a few subtitles to check timing.", in: .subtitles, dismissAfterSeconds: 10)
    }
    @Published private(set) var bumpers: [Bumper] = []
    @Published var preferences: AppPreferences

    private let bumperKey = "SermonCut.bumpers.v1"
    private let preferencesKey = "SermonCut.preferences.v1"
    private let defaults: UserDefaults
    private var automationTask: Task<Void, Never>?
    private var automationID = UUID()

    func takeOverManually() {
        automationID = UUID()
        automationTask?.cancel()
        automationTask = nil
        isAnalyzing = false
        if isSubtitleProcessing {
            report("Subtitle processing cancelled because the selection changed. Restart when ready.", in: .subtitles, tone: .warning)
        }
        if subtitleURL == nil { captionPlan = generatedCoverage == nil ? .manualWithoutCaptions : .generated }
        if sermonRange == nil && sourceDuration > 0 {
            sermonRange = SermonRange(start: 0, end: sourceDuration, confidence: 0,
                                      explanation: "Manual selection. Choose the sermon boundaries in the preview.")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var bundledBumperError: Error?
        do {
            try BundledBumpers.installIfNeeded(
                source: AppResources.url(forResource: "SCB-Bumper", withExtension: "mp4", subdirectory: "Resources/DefaultBumpers"),
                defaults: defaults, storage: BumperStorage(),
                bumperKey: bumperKey, preferencesKey: preferencesKey)
        } catch { bundledBumperError = error }
        bumpers = (try? JSONDecoder().decode([Bumper].self, from: defaults.data(forKey: bumperKey) ?? Data())) ?? []
        preferences = (try? JSONDecoder().decode(AppPreferences.self, from: defaults.data(forKey: preferencesKey) ?? Data())) ?? AppPreferences()
        exportDirectory = Self.resolveBookmark(preferences.exportDirectoryBookmark)
        applyStartupBumpers()
        if let bundledBumperError {
            report("Could not install the included bumpers: \(bundledBumperError.localizedDescription)", in: .bumpers, tone: .error)
        }
    }

    var selectedOpening: Bumper? { bumpers.first { $0.id == openingBumperID } }
    var selectedClosing: Bumper? { bumpers.first { $0.id == closingBumperID } }
    var openingBumpers: [Bumper] { bumpers.filter { $0.kind == .opening } }
    var closingBumpers: [Bumper] { bumpers.filter { $0.kind == .closing } }

    func importSource(_ url: URL) {
        guard !isExporting else { return }
        takeOverManually()
        let scoped = url.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: url.path) else { report("The selected video could not be accessed.", in: .source, tone: .error); return }
        sourceURL = url
        cues = []
        originalImportedCues = []
        subtitleURL = nil
        generatedCoverage = nil
        subtitleAlignmentRange = nil
        subtitleAlignmentResult = nil
        captionPlan = .manualWithoutCaptions
        notices = [:]
        exportName = url.deletingPathExtension().lastPathComponent + " — Sermon"
        captionTiming = nil
        sourceDuration = 0
        sermonRange = nil
        boundariesConfirmed = false
        let asset = AVURLAsset(url: url)
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard sourceURL == url else { return }
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard sourceURL == url else { return }
            sourceDuration = duration
            sermonRange = SermonRange(start: 0, end: duration, confidence: 0,
                                      explanation: "Manual selection. Set the sermon start and end in the preview.")
            prepareBumperVideo()
            prepareBumperAudio()
            report("Service loaded — \(format(sourceDuration)). Set the sermon boundaries in the preview.", in: .source, dismissAfterSeconds: 10)
        }
    }

    func importSubtitles(_ url: URL) {
        guard !isExporting else { return }
        takeOverManually()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try SRTParser.parse(url: url)
            guard !imported.isEmpty else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This SRT contains no usable subtitle cues. Choose another file."]) }
            cues = imported
            originalImportedCues = imported
            generatedCoverage = nil
            captionTiming = nil
            subtitleURL = url
            captionPlan = .supplied
            report("Loaded \(cues.count) subtitle cues — \(format(cues.last?.end ?? 0)) total.", in: .subtitles, dismissAfterSeconds: 10)
            autoAlignImportedSubtitles()
        } catch {
            report(error.localizedDescription, in: .subtitles, tone: .error)
        }
    }

    func removeSubtitles() {
        guard !isExporting else { return }
        takeOverManually()
        subtitleURL = nil
        generatedCoverage = nil
        cues = []
        originalImportedCues = []
        captionTiming = nil
        subtitleAlignmentRange = nil
        subtitleAlignmentResult = nil
        captionPlan = .manualWithoutCaptions
        report("Subtitles removed from this project. The original SRT file is unchanged.", in: .subtitles, dismissAfterSeconds: 10)
    }

    func addBumper(_ url: URL, kind: BumperKind) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bumper = try BumperStorage().importCopy(from: url, kind: kind)
            bumpers.append(bumper)
            if kind == .opening { openingBumperID = bumper.id } else { closingBumperID = bumper.id }
            updateSelections()
            prepareBumperAudio()
            report("Saved a permanent copy of \(bumper.name) in the bumper library.", in: .bumpers, dismissAfterSeconds: 10)
        } catch { report("Could not import bumper: \(error.localizedDescription)", in: .bumpers, tone: .error) }
    }

    func setExportDirectory(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            report("The selected export folder could not be accessed.", in: .export, tone: .error)
            return
        }
        do {
            preferences.exportDirectoryBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            exportDirectory = url
            persist()
            report("Exports will be saved to \(url.path).", in: .export)
        } catch { report("Could not save export folder permission: \(error.localizedDescription)", in: .export, tone: .error) }
    }

    func makeDefault(_ bumper: Bumper) {
        if bumper.kind == .opening { preferences.defaultOpeningID = bumper.id } else { preferences.defaultClosingID = bumper.id }
        persist()
    }

    func renameBumper(_ bumper: Bumper, to proposedName: String) {
        guard !isExporting else {
            report("Wait for the current export to finish before renaming a bumper.", in: .bumpers, tone: .warning)
            return
        }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200 else {
            report("Enter a bumper name between 1 and 200 bytes.", in: .bumpers, tone: .error)
            return
        }
        guard let index = bumpers.firstIndex(where: { $0.id == bumper.id }) else { return }
        bumpers[index].name = name
        persist()
        report("Renamed bumper to \(name).", in: .bumpers, dismissAfterSeconds: 10)
    }

    func deleteBumper(_ bumper: Bumper) {
        guard !bumper.isBundled, bumpers.first(where: { $0.id == bumper.id })?.isBundled != true else { return }
        guard !isExporting else {
            report("Wait for the current export to finish before deleting a bumper.", in: .bumpers, tone: .warning)
            return
        }
        guard let saved = bumpers.first(where: { $0.id == bumper.id }) else { return }
        do {
            try BumperStorage().deleteCopy(of: saved)
            bumpers.removeAll { $0.id == saved.id }
            if openingBumperID == saved.id { openingBumperID = nil }
            if closingBumperID == saved.id { closingBumperID = nil }
            if preferences.defaultOpeningID == saved.id { preferences.defaultOpeningID = nil }
            if preferences.defaultClosingID == saved.id { preferences.defaultClosingID = nil }
            if preferences.lastOpeningID == saved.id { preferences.lastOpeningID = nil }
            if preferences.lastClosingID == saved.id { preferences.lastClosingID = nil }
            persist()
            report("Permanently deleted \(saved.name) from the bumper library. The original imported file was not deleted.", in: .bumpers, dismissAfterSeconds: 10)
        } catch {
            report("Could not delete \(saved.name): \(error.localizedDescription)", in: .bumpers, tone: .error)
        }
    }

    func analyze() {
        takeOverManually()
        guard sourceURL != nil, sourceDuration > 0 else {
            report("Import a service video first.", in: .trim, tone: .warning)
            return
        }
        guard !cues.isEmpty else {
            sermonRange = SermonRange(start: 0, end: min(sourceDuration, 45 * 60), confidence: 0,
                                      explanation: "Set the sermon start and end in the preview, or create local subtitles first.")
            report(sermonRange?.explanation ?? "", in: .trim)
            return
        }
        guard let captionTiming else {
            report("Match a subtitle to the video, or confirm that subtitle timestamps already match.", in: .trim, tone: .warning)
            return
        }
        isAnalyzing = true
        let requestID = automationID
        automationTask = Task {
            // TranscriptAligner is deliberately injectable. Its production implementation will match
            // sampled source audio to the externally supplied SRT without uploading the service.
            guard !Task.isCancelled, requestID == automationID else { return }
            if var suggestion = ServiceStructureDetector.suggest(cues: captionTiming.sourceCues(cues)) {
                suggestion.start = max(0, suggestion.start)
                suggestion.end = min(sourceDuration, suggestion.end)
                if suggestion.end > suggestion.start { sermonRange = suggestion }
            }
            isAnalyzing = false
            report(sermonRange?.explanation ?? "No spoken subtitle range was found.", in: .trim)
        }
    }

    func confirmCaptionTiming(offset: TimeInterval) {
        guard offset.isFinite else { return }
        takeOverManually()
        captionTiming = CaptionTiming(sourceOffset: offset)
        subtitleAlignmentRange = sermonRange
        report("Subtitle timing set. Preview a later subtitle too to check synchronization.", in: .subtitles, dismissAfterSeconds: 10)
        notices[.subtitles]?.isSubtitleTimingConfirmation = true
    }

    func adjustCaptionTiming(by seconds: TimeInterval) {
        guard let current = captionTiming else {
            guard let suggested = subtitleAlignmentResult else { return }
            confirmCaptionTiming(offset: suggested.sourceOffset + seconds)
            return
        }
        confirmCaptionTiming(offset: current.sourceOffset + seconds)
    }

    func restoreGeneratedSubtitleTiming() {
        guard subtitleURL == nil, let generatedCoverage else { return }
        confirmCaptionTiming(offset: generatedCoverage.start)
    }

    func autoAlignImportedSubtitles() {
        guard subtitleURL != nil, !originalImportedCues.isEmpty, let sourceURL, let range = sermonRange, range.duration > 0 else {
            report("Choose a source video, sermon range, and imported SRT first.", in: .subtitles, tone: .warning)
            return
        }
        takeOverManually()
        let requestID = automationID
        isAnalyzing = true
        subtitleAlignmentResult = nil
        subtitleAlignmentProgress = 0.02
        subtitleAlignmentEstimate = "Transcribing short samples…"
        report("Analyzing the beginning and end of the selected sermon to align the SRT…", in: .subtitles)
        automationTask = Task {
            let started = Date()
            let window = min(60, range.duration / 2)
            let firstWav = temporaryWavURL()
            let lastWav = temporaryWavURL()
            defer { try? FileManager.default.removeItem(at: firstWav); try? FileManager.default.removeItem(at: lastWav) }
            defer { if requestID == automationID { isAnalyzing = false } }
            do {
                try await FFmpegRunner.extractSpeechAudio(input: sourceURL, output: firstWav, start: range.start, limit: window)
                subtitleAlignmentProgress = 0.35
                let first = try await LocalCaptioner.transcribe(wavURL: firstWav, preserveWordTiming: true)
                try Task.checkCancellation()
                subtitleAlignmentEstimate = "Analyzing the closing sample…"
                let secondStart = max(range.start, range.end - window)
                try await FFmpegRunner.extractSpeechAudio(input: sourceURL, output: lastWav, start: secondStart, limit: window)
                subtitleAlignmentProgress = 0.68
                var last = try await LocalCaptioner.transcribe(wavURL: lastWav, preserveWordTiming: true)
                last = last.map { SubtitleCue(start: $0.start + (secondStart - range.start), end: $0.end + (secondStart - range.start), text: $0.text) }
                var transcript = first + (secondStart > range.start ? last : [])
                if range.duration > window * 3 {
                    subtitleAlignmentEstimate = "Cross-checking a middle sample…"
                    let middleStart = range.start + (range.duration - window) / 2
                    try await FFmpegRunner.extractSpeechAudio(input: sourceURL, output: firstWav, start: middleStart, limit: window)
                    let middle = try await LocalCaptioner.transcribe(wavURL: firstWav, preserveWordTiming: true)
                    transcript += middle.map { SubtitleCue(start: $0.start + middleStart - range.start, end: $0.end + middleStart - range.start, text: $0.text) }
                }
                guard let result = SubtitleAutoAligner.align(transcript: transcript, supplied: originalImportedCues, sourceStart: range.start) else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No reliable subtitle-start phrases were found in the audio samples. A sample may begin inside a long paragraph, or its wording may differ. Retry or align a selected subtitle manually."])
                }
                guard !Task.isCancelled, requestID == automationID else { return }
                subtitleAlignmentResult = result
                if result.confidence >= 0.75 {
                    captionTiming = CaptionTiming(sourceOffset: result.sourceOffset)
                    subtitleAlignmentRange = range
                } else {
                    captionTiming = nil
                    subtitleAlignmentRange = nil
                }
                subtitleAlignmentProgress = 1
                subtitleAlignmentEstimate = "Finished in \(format(Date().timeIntervalSince(started)))"
                report(result.confidence >= 0.75
                    ? "SRT aligned using \(result.anchorCount) agreeing phrase matches. Review the matching details and preview the subtitles."
                    : "The proposed timing needs review: too few independent matches, ambiguous wording, or inconsistent timing. Preview it, then accept it explicitly, retry, or use manual adjustment.",
                    in: .subtitles, tone: result.confidence >= 0.75 ? .normal : .warning)
            } catch {
                guard requestID == automationID else { return }
                subtitleAlignmentProgress = 0
                subtitleAlignmentEstimate = ""
                report(error.localizedDescription, in: .subtitles, tone: .error)
            }
        }
    }

    func refinePauses() {
        takeOverManually()
        guard let sourceURL, let range = sermonRange, range.duration > 0 else { return }
        let requestID = automationID
        isAnalyzing = true
        report("Checking quiet audio near your selected first and last words…", in: .trim)
        automationTask = Task {
            defer { if requestID == automationID { isAnalyzing = false } }
            do {
                let refined = try await PauseBoundaryRefiner.refine(source: sourceURL, range: range, duration: sourceDuration)
                guard !Task.isCancelled, requestID == automationID else { return }
                sermonRange = refined
                boundariesConfirmed = true
                report(refined.explanation, in: .trim)
            } catch {
                guard requestID == automationID else { return }
                report("Could not refine pauses: \(error.localizedDescription). Your selection is unchanged.", in: .trim, tone: .error)
            }
        }
    }

    func prepareLocalTranscription() {
        takeOverManually()
        guard let range = sermonRange, range.duration > 0, sourceDuration > 0 else { report("Import a service video before creating subtitles.", in: .subtitles, tone: .warning); return }
        captionPlan = .localTranscriptionPendingEstimate
        report("Benchmarking a sample from the selected sermon on this Mac…", in: .subtitles)
        let requestID = automationID
        isAnalyzing = true
        automationTask = Task {
            defer { if requestID == automationID { isAnalyzing = false } }
            do {
                let sampleLength = min(30, range.duration)
                let measured = try await transcribeSample(start: range.start, seconds: sampleLength)
                guard !Task.isCancelled, requestID == automationID else { return }
                let estimate = max(60, measured / sampleLength * range.duration * 1.25)
                captionPlan = .localTranscription(estimatedSeconds: estimate)
                report("Local subtitle generation is estimated at about \(format(estimate)) on this Mac. Start when ready.", in: .subtitles)
            } catch {
                guard requestID == automationID else { return }
                captionPlan = generatedCoverage == nil ? .manualWithoutCaptions : .generated
                report("Could not benchmark local subtitle generation: \(error.localizedDescription)", in: .subtitles, tone: .error)
            }
        }
    }

    func createLocalCaptions() {
        let savedEstimate = captionPlanEstimate
        takeOverManually()
        guard let sourceURL, let range = sermonRange, range.duration > 0 else { return }
        let estimated = savedEstimate ?? max(60, range.duration * 0.25)
        captionPlan = .localTranscribing
        localSubtitleProgress = 0
        localSubtitleEstimate = "Estimating time remaining…"
        report("Creating local English subtitles. This can continue while the app is open.", in: .subtitles)
        let requestID = automationID
        isAnalyzing = true
        automationTask = Task {
            let started = Date()
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    guard requestID == automationID else { return }
                    let elapsed = Date().timeIntervalSince(started)
                    localSubtitleProgress = min(0.95, max(0.04, elapsed / max(1, estimated)))
                    localSubtitleEstimate = elapsed > 2 ? elapsed < estimated ? "About \(format(estimated - elapsed)) remaining (estimate)" : "Taking longer than estimated; still processing…" : "Estimating time remaining…"
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { ticker.cancel() }
            defer { if requestID == automationID { isAnalyzing = false } }
            let wav = temporaryWavURL()
            defer { try? FileManager.default.removeItem(at: wav) }
            do {
                try await FFmpegRunner.extractSpeechAudio(input: sourceURL, output: wav, start: range.start, limit: range.duration)
                localSubtitleProgress = max(localSubtitleProgress, 0.18)
                try Task.checkCancellation()
                let generated = try await LocalCaptioner.transcribe(wavURL: wav)
                guard !Task.isCancelled, requestID == automationID else { return }
                guard !generated.isEmpty else { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No speech was found in this selection."]) }
                installGeneratedSubtitles(generated, range: range)
                localSubtitleProgress = 1
                localSubtitleEstimate = "Finished"
                report("Created \(cues.count) local subtitle cues. Timing is aligned automatically to the selected sermon.", in: .subtitles, dismissAfterSeconds: 10)
            } catch {
                guard requestID == automationID else { return }
                captionPlan = generatedCoverage == nil ? .manualWithoutCaptions : .generated
                localSubtitleProgress = 0
                localSubtitleEstimate = ""
                report("Local subtitle generation could not finish: \(error.localizedDescription)", in: .subtitles, tone: .error)
            }
        }
    }

    func regenerateLocalCaptions() {
        guard generatedCoverage != nil, sermonRange != nil else {
            report("Choose the sermon boundaries before regenerating subtitles.", in: .subtitles, tone: .warning)
            return
        }
        // createLocalCaptions reads sermonRange at invocation time, so this
        // always uses the latest start/end values from the trimming section.
        createLocalCaptions()
    }

    private var captionPlanEstimate: TimeInterval? {
        if case let .localTranscription(estimatedSeconds) = captionPlan { return estimatedSeconds }
        return nil
    }

    var isSubtitleProcessing: Bool {
        captionPlan == .localTranscribing || captionPlan == .localTranscriptionPendingEstimate
    }

    var displaySubtitleCues: [SubtitleCue] {
        subtitleURL == nil ? cues : ImportedSubtitleFormatting.addBreathingRoom(cues)
    }

    func adjustedSubtitlesForReview() async throws -> [SubtitleCue] {
        guard let range = sermonRange,
              let timing = captionTiming ?? subtitleAlignmentResult.map({ CaptionTiming(sourceOffset: $0.sourceOffset) }) else {
            throw CocoaError(.validationMissingMandatoryProperty, userInfo: [NSLocalizedDescriptionKey: "Align the subtitles before reviewing adjusted timestamps."])
        }
        let reviewCues = displaySubtitleCues
        let opening = selectedOpening
        let url = exportMP4 || opening?.media == .video ? try bumperURL(opening) : nil
        let scoped = url?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
        let openingDuration = opening?.media == .image ? (exportMP4 ? 6.0 : 0.0) : try await duration(of: url)
        return timing.exportCues(reviewCues, selection: range, openingDuration: openingDuration)
    }

    var importedSubtitlesNeedResync: Bool {
        guard subtitleURL != nil, captionTiming != nil, let aligned = subtitleAlignmentRange, let range = sermonRange else { return false }
        return abs(aligned.start - range.start) > 0.01 || abs(aligned.end - range.end) > 0.01
    }

    func installGeneratedSubtitles(_ generated: [SubtitleCue], range: SermonRange) {
        cues = generated
        generatedCoverage = range
        captionTiming = CaptionTiming(sourceOffset: range.start)
        captionPlan = .generated
        subtitleURL = nil
    }

    func export(youtube: YouTubeStore? = nil) {
        exportNameDraft.flush()
        guard !isExporting else { return }
        if youtube != nil { setYouTubeUploadRequirement(true) }
        let blockers = exportBlockers()
        guard blockers.isEmpty else { report(blockers.joined(separator: "\n"), in: .export, tone: .warning); return }
        guard let sourceURL, let sermonRange, let exportDirectory else {
            report("Choose a source video, sermon boundaries, and export folder first.", in: .export, tone: .warning)
            return
        }
        guard cues.isEmpty || captionTiming != nil else {
            report("Set subtitle timing before exporting the SRT.", in: .export, tone: .warning)
            return
        }
        let selectedExportName = exportName
        do { _ = try MediaExporter.validatedExportName(selectedExportName) }
        catch { report(error.localizedDescription, in: .export, tone: .error); return }
        let uploadDraft: YouTubeUploadDraft?
        do { uploadDraft = try youtube?.snapshot() }
        catch { report(error.localizedDescription, in: .export, tone: .error); return }
        let uploadChannel = youtube?.connection?.channelID
        let exportCues = displaySubtitleCues
        let timing = captionTiming
        let opening = selectedOpening
        let closing = selectedClosing
        let openingGain = opening.map { bumperAttenuation[$0.id] ?? 0 } ?? 0
        let closingGain = closing.map { bumperAttenuation[$0.id] ?? 0 } ?? 0
        let writeVideo = exportMP4
        let writeAudio = exportMP3
        isExporting = true
        beginExportPhase(1, label: writeVideo ? "Preparing video…" : "Preparing MP3 audio…")
        report("Preparing the selected local exports…", in: .export)
        Task {
            do {
                let openingURL = writeVideo || opening?.media == .video ? try bumperURL(opening) : nil
                let closingURL = writeVideo || closing?.media == .video ? try bumperURL(closing) : nil
                let scopedURLs = [sourceURL, exportDirectory, openingURL, closingURL].compactMap { $0 }.filter { $0.startAccessingSecurityScopedResource() }
                defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
                let locations = try MediaExporter.makeLocations(source: sourceURL, directory: exportDirectory, name: selectedExportName)
                if writeVideo {
                    let jobs = [(opening, openingURL), (closing, closingURL)].compactMap { bumper, url -> BumperVideoOptimizer.Job? in
                        guard let bumper, let url else { return nil }
                        return .init(url: url, media: bumper.media)
                    }
                    beginExportPhase(1, label: "Preparing compatible bumpers…")
                    let variants = await bumperVideo.variants(source: sourceURL, jobs: jobs)
                    let preparedOpening = openingURL.flatMap { variants[$0] }
                    let preparedClosing = closingURL.flatMap { variants[$0] }
                    try await MediaExporter.exportVideo(sourceURL: sourceURL, openingURL: preparedOpening ?? openingURL, closingURL: preparedClosing ?? closingURL,
                                                        openingMedia: preparedOpening != nil ? .video : opening?.media ?? .video,
                                                        closingMedia: preparedClosing != nil ? .video : closing?.media ?? .video,
                                                        openingGain: openingGain, closingGain: closingGain,
                                                        sermon: sermonRange, destination: locations.video,
                                                        progress: { fraction in
                        Task { @MainActor [weak self] in self?.updateExportProgress(fraction, phase: 1) }
                    }, mode: { message in
                        Task { @MainActor [weak self] in
                            guard let self, self.isExporting, self.exportPhase == 1 else { return }
                            self.report(message, in: .export)
                            self.beginExportPhase(1, label: message)
                        }
                    })
                }
                if writeAudio {
                    let audioPhase = writeVideo ? 2 : 1
                    beginExportPhase(audioPhase, label: writeVideo ? "MP3 audio · stage 2 of 2" : "MP3 audio")
                    report("Creating 128 kbps MP3…", in: .export)
                    var audioClips: [ExportClip] = []
                    audioClips.reserveCapacity(3)
                    if let openingURL, opening?.media == .video {
                        audioClips.append(ExportClip(url: openingURL, start: 0, duration: try await duration(of: openingURL)))
                    }
                    audioClips.append(ExportClip(url: sourceURL, start: sermonRange.start, duration: sermonRange.duration))
                    if let closingURL, closing?.media == .video {
                        audioClips.append(ExportClip(url: closingURL, start: 0, duration: try await duration(of: closingURL)))
                    }
                    var audioGains: [Double] = []
                    if openingURL != nil, opening?.media == .video { audioGains.append(openingGain) }
                    audioGains.append(0)
                    if closingURL != nil, closing?.media == .video { audioGains.append(closingGain) }
                    try await MediaExporter.exportMP3(from: sourceURL, audioClips: audioClips, audioGains: audioGains, destination: locations.audio) { fraction in
                        Task { @MainActor [weak self] in self?.updateExportProgress(fraction, phase: audioPhase) }
                    }
                }
                if !exportCues.isEmpty, let timing {
                    // With MP3 alone, JPG bumpers are omitted from its timeline.
                    let openingDuration = opening?.media == .image ? (writeVideo ? 6.0 : 0.0) : try await duration(of: openingURL)
                    try MediaExporter.writeAdjustedCaptions(exportCues, sermon: sermonRange, openingDuration: openingDuration, destination: locations.captions, timing: timing)
                }
                exportProgress = 1
                if let youtube, let uploadDraft, let uploadChannel {
                    try youtube.enqueue(video: locations.video, captions: exportCues.isEmpty ? nil : locations.captions,
                                       draft: uploadDraft, channelID: uploadChannel)
                }
                isExporting = false
                let exported = [writeVideo ? "MP4" : nil, writeAudio ? "128 kbps MP3" : nil,
                                exportCues.isEmpty ? nil : "adjusted SRT"].compactMap { $0 }
                report("Exported \(exported.joined(separator: ", ")).", in: .export)
            } catch {
                isExporting = false
                report(error.localizedDescription, in: .export, tone: .error)
            }
        }
    }

    func nudgeStart(_ seconds: TimeInterval) {
        guard let range = sermonRange else { return }
        setStart(range.start + seconds)
    }

    func nudgeEnd(_ seconds: TimeInterval) {
        guard let range = sermonRange else { return }
        setEnd(range.end + seconds)
    }

    func setStart(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        takeOverManually()
        guard var range = sermonRange else { return }
        range.start = min(max(0, seconds), sourceDuration)
        range.confidence = min(range.confidence, 0.60)
        range.explanation = "Boundary adjusted during review."
        sermonRange = range
        boundariesConfirmed = true
        prepareBumperAudio()
    }

    func setEnd(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        takeOverManually()
        guard var range = sermonRange else { return }
        range.end = max(min(sourceDuration, seconds), 0)
        range.confidence = min(range.confidence, 0.60)
        range.explanation = "Boundary adjusted during review."
        sermonRange = range
        boundariesConfirmed = true
        prepareBumperAudio()
    }

    func updateSelections() {
        preferences.lastOpeningID = openingBumperID
        preferences.lastClosingID = closingBumperID
        persist()
        prepareBumperVideo()
        prepareBumperAudio()
    }

    private func prepareBumperVideo() {
        guard exportMP4, let sourceURL, sourceDuration > 0 else { bumperVideo.cancel(); return }
        let jobs = [selectedOpening, selectedClosing].compactMap { bumper -> BumperVideoOptimizer.Job? in
            guard let bumper, let url = try? bumperURL(bumper) else { return nil }
            return .init(url: url, media: bumper.media)
        }
        bumperVideo.prepare(source: sourceURL, jobs: jobs)
    }

    /// Analyze the selected sermon and bumper audio off the export path. A
    /// missing or still-running analysis never blocks export; in that case the
    /// original bumper level is preserved.
    private func prepareBumperAudio() {
        audioAnalysisTask?.cancel()
        guard let sourceURL, let range = sermonRange, range.duration > 0 else { return }
        let snapshot = bumpers
        audioAnalysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let scopedSource = sourceURL.startAccessingSecurityScopedResource()
                defer { if scopedSource { sourceURL.stopAccessingSecurityScopedResource() } }
                guard let sermonLevel = try await BumperAudioAnalyzer.integratedLoudness(url: sourceURL,
                                                                                           start: range.start,
                                                                                           duration: range.duration) else { return }
                var attenuation: [UUID: Double] = [:]
                for bumper in snapshot where bumper.media == .video {
                    try Task.checkCancellation()
                    guard let url = try self.bumperURL(bumper) else { continue }
                    var bumperLevel = bumper.audioLoudness
                    if bumperLevel == nil {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        bumperLevel = try await BumperAudioAnalyzer.integratedLoudness(url: url)
                        if let bumperLevel, let index = self.bumpers.firstIndex(where: { $0.id == bumper.id }) {
                            self.bumpers[index].audioLoudness = bumperLevel
                            self.persist()
                        }
                    }
                    if let bumperLevel {
                        attenuation[bumper.id] = BumperAudioAnalyzer.attenuation(sermon: sermonLevel, bumper: bumperLevel)
                    }
                }
                self.bumperAttenuation = attenuation
            } catch is CancellationError {
                // A changed source, bumper, or boundary starts a fresh pass.
            } catch {
                self.bumperAttenuation = [:]
            }
        }
    }

    func bumperURL(_ bumper: Bumper?) throws -> URL? {
        guard let bumper else { return nil }
        if let managed = BumperStorage().url(for: bumper) { return managed }
        var stale = false
        let url = try URL(resolvingBookmarkData: bumper.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var migrated = try BumperStorage().importCopy(from: url, kind: bumper.kind)
        // Preserve saved selections/defaults while upgrading old reference entries.
        migrated = Bumper(id: bumper.id, name: bumper.name, kind: bumper.kind, bookmark: Data(),
                          createdAt: bumper.createdAt, managedFilename: migrated.managedFilename, media: bumper.media,
                          audioLoudness: bumper.audioLoudness)
        if let index = bumpers.firstIndex(where: { $0.id == bumper.id }) { bumpers[index] = migrated; persist() }
        return BumperStorage().url(for: migrated)
    }

    private func duration(of url: URL?) async throws -> TimeInterval {
        guard let url else { return 0 }
        return try await AVURLAsset(url: url).load(.duration).seconds
    }

    private func transcribeSample(start: TimeInterval, seconds: TimeInterval) async throws -> TimeInterval {
        guard let sourceURL else { return 0 }
        let wav = temporaryWavURL()
        defer { try? FileManager.default.removeItem(at: wav) }
        try await FFmpegRunner.extractSpeechAudio(input: sourceURL, output: wav, start: start, limit: seconds)
        let began = Date.now
        _ = try await LocalCaptioner.transcribe(wavURL: wav)
        return Date.now.timeIntervalSince(began)
    }

    private func temporaryWavURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sermonclip-speech-\(UUID().uuidString).wav")
    }

    private func applyStartupBumpers() {
        switch preferences.startupBumperMode {
        case .defaults:
            openingBumperID = preferences.defaultOpeningID
            closingBumperID = preferences.defaultClosingID
        case .lastUsed:
            openingBumperID = preferences.lastOpeningID ?? preferences.defaultOpeningID
            closingBumperID = preferences.lastClosingID ?? preferences.defaultClosingID
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(bumpers), forKey: bumperKey)
        defaults.set(try? JSONEncoder().encode(preferences), forKey: preferencesKey)
    }

    private static func resolveBookmark(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func format(_ seconds: TimeInterval) -> String {
        let rounded = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d:%02d", rounded / 3600, (rounded / 60) % 60, rounded % 60)
    }
}
