import AVFoundation
import SwiftUI

struct AudioWaveformView: View {
    let sourceURL: URL
    let duration: TimeInterval
    let range: SermonRange
    let player: AVPlayer?
    @Binding var zoomed: Bool
    var subtitleStart: TimeInterval? = nil
    @State private var levels: [Float] = []
    @State private var message = "Building audio waveform locally…"
    @State private var messageTone: NoticeTone = .normal
    @State private var dragWindow: WaveformWindow?
    @State private var scrubTime: Double?
    @State private var seekID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let playhead = player?.currentTime().seconds ?? 0
                let center = scrubTime ?? (playhead.isFinite ? playhead : 0)
                let window = dragWindow ?? WaveformWindow(duration: duration, playhead: center, detail: zoomed)
                let span = window.span
                let lower = window.lower
                Canvas { context, size in
                    guard span > 0 else { return }
                    let waveformHeight: CGFloat = 76
                    let selectedStart = max(lower, range.start)
                    let selectedEnd = min(lower + span, range.end)
                    if selectedEnd > selectedStart {
                        let rectangle = CGRect(
                            x: (selectedStart - lower) / span * size.width,
                            y: 0,
                            width: (selectedEnd - selectedStart) / span * size.width,
                            height: waveformHeight
                        )
                        context.fill(Path(rectangle), with: .color(.accentColor.opacity(0.18)))
                    }
                    let columns = max(1, Int(size.width))
                    var bars = Path()
                    for column in 0..<columns {
                        let start = Int((lower + Double(column) / Double(columns) * span) * 10)
                        let end = max(start + 1, Int((lower + Double(column + 1) / Double(columns) * span) * 10))
                        guard start >= 0, start < levels.count else { continue }
                        let peak = levels[start..<min(end, levels.count)].max() ?? 0
                        let height = max(1, CGFloat(sqrt(peak)) * waveformHeight * 0.9)
                        bars.move(to: CGPoint(x: CGFloat(column), y: (waveformHeight - height) / 2))
                        bars.addLine(to: CGPoint(x: CGFloat(column), y: (waveformHeight + height) / 2))
                    }
                    context.stroke(bars, with: .color(.secondary), lineWidth: 1)
                    var markers: [(time: Double, color: Color, caretY: CGFloat)] = [
                        (range.start, .green, 78), (range.end, .red, 78)
                    ]
                    if let subtitleStart {
                        // A second tiny lane keeps the subtitle caret visible even
                        // when its start coincides with a sermon boundary.
                        markers.append((subtitleStart, Color(red: 1, green: 212.0 / 255, blue: 158.0 / 255), 86))
                    }
                    for (time, color, caretY) in markers {
                        guard time.isFinite, time >= lower, time <= lower + span else { continue }
                        let x = (time - lower) / span * size.width
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x, y: waveformHeight))
                        context.stroke(line, with: .color(color), lineWidth: 2)
                        var markerCaret = Path()
                        markerCaret.move(to: CGPoint(x: x, y: caretY))
                        markerCaret.addLine(to: CGPoint(x: min(size.width, x + 4), y: caretY + 5))
                        markerCaret.addLine(to: CGPoint(x: max(0, x - 4), y: caretY + 5))
                        markerCaret.closeSubpath()
                        context.fill(markerCaret, with: .color(color))
                    }
                    // Draw last so the playhead stays visible over the selection and boundary markers.
                    if center >= lower, center <= lower + span {
                        let x = (center - lower) / span * size.width
                        var stem = Path()
                        stem.move(to: CGPoint(x: x, y: 11))
                        stem.addLine(to: CGPoint(x: x, y: waveformHeight))
                        context.stroke(stem, with: .color(.black), lineWidth: 4)
                        context.stroke(stem, with: .color(.white), lineWidth: 2)

                        var caret = Path()
                        caret.move(to: CGPoint(x: max(0, x - 7), y: 1))
                        caret.addLine(to: CGPoint(x: min(size.width, x + 7), y: 1))
                        caret.addLine(to: CGPoint(x: x, y: 11))
                        caret.closeSubpath()
                        context.fill(caret, with: .color(.white))
                        context.stroke(caret, with: .color(.black), lineWidth: 1)
                    }
                }
                .frame(height: subtitleStart == nil ? 85 : 93)
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 76)
                }
                .overlay {
                    if levels.isEmpty { StatusNotice(text: message, tone: messageTone) }
                }
                .overlay {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    // Freeze the visible time window so dragging cannot chase
                                    // a detail view that keeps recentering underneath the mouse.
                                    if dragWindow == nil { dragWindow = window }
                                    scrub(to: (dragWindow ?? window).time(at: value.location.x, width: geometry.size.width), final: false)
                                }
                                .onEnded { value in
                                    scrub(to: (dragWindow ?? window).time(at: value.location.x, width: geometry.size.width), final: true)
                                })
                    }
                }
                .accessibilityLabel("Audio waveform. Green marks start; red marks end. Upward carets below the waveform mark these boundaries. A white caret and line mark the playhead." + (subtitleStart == nil ? "" : " A peach line and upward caret mark the selected subtitle's display start."))
            }
        }
        .task(id: sourceURL) {
            levels = []
            message = "Building audio waveform locally…"
            messageTone = .normal
            let url = sourceURL
            let work = Task.detached(priority: .utility) { try await WaveformReader.read(url) }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                levels = result
                if result.isEmpty { message = "No audio waveform available."; messageTone = .warning }
            } catch {
                if !Task.isCancelled { message = "Waveform unavailable; video controls still work."; messageTone = .error }
            }
        }
    }

    private func scrub(to time: Double, final: Bool) {
        let id = UUID(); seekID = id
        scrubTime = time
        guard let player else { scrubTime = nil; dragWindow = nil; return }
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        let tolerance = final ? CMTime.zero : CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
            guard final else { return }
            Task { @MainActor in
                guard seekID == id else { return }
                scrubTime = nil; dragWindow = nil
            }
        }
    }
}

struct WaveformWindow {
    let lower: Double
    let span: Double
    init(duration: Double, playhead: Double, detail: Bool) {
        let length = duration.isFinite ? max(0, duration) : 0
        span = detail ? min(15, length) : length
        lower = detail ? max(0, min(length - span, (playhead.isFinite ? playhead : 0) - span / 2)) : 0
    }
    func time(at x: Double, width: Double) -> Double {
        lower + max(0, min(1, x / max(1, width))) * span
    }
}

enum WaveformReader {
    // Ten peak measurements per second; no full-service PCM buffer is retained.
    static func read(_ url: URL) async throws -> [Float] {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        defer { reader.cancelReading() }
        var levels: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length % MemoryLayout<Float>.size == 0 else { continue }
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw CocoaError(.fileReadCorruptFile) }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard timestamp.isFinite else { continue }
            for (index, sample) in samples.enumerated() {
                let binTime = (timestamp + Double(index) / 8000) * 10
                // Ignore negative encoder priming; keep gaps in the source timeline.
                guard binTime >= 0, binTime < 864_000 else { continue }
                let bin = Int(binTime)
                if bin >= levels.count { levels.append(contentsOf: repeatElement(0, count: bin - levels.count + 1)) }
                levels[bin] = max(levels[bin], sample.isFinite ? min(1, abs(sample)) : 0)
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return levels
    }
}
