import Foundation
import SwiftUI

struct AudioLevel: Sendable {
    let time: Double
    let decibels: Double
}

struct SilenceCut: Identifiable {
    var id: String { "\(segmentID)-\(start)-\(end)" }
    let segmentID: UUID
    let start: Double
    let end: Double
    let timelineStart: Double
    let duration: Double
    var included = true
}

struct AudioOverview: Sendable {
    static let interval = 0.05
    let levels: [AudioLevel]

    func cuts(in timeline: ClipTimeline, fps: Double, threshold: Double, minimum: Double, padding: Double) -> [SilenceCut] {
        var quiet: [(Double, Double)] = []
        var beginning: Double?
        var previousEnd = 0.0
        for level in levels {
            // Never infer silence across an unmeasured gap.
            if level.time > previousEnd + Self.interval * 0.5, let start = beginning {
                quiet.append((start, previousEnd)); beginning = nil
            }
            if level.decibels <= threshold {
                if beginning == nil { beginning = level.time }
            } else if let start = beginning { quiet.append((start, level.time)); beginning = nil }
            previousEnd = level.time + Self.interval
        }
        if let beginning { quiet.append((beginning, previousEnd)) }
        var result: [SilenceCut] = []
        for segment in timeline.segments {
            for (start, end) in quiet where end - start >= minimum {
                let lower = max(segment.start, ceil((start + padding) * fps) / fps)
                let upper = min(segment.end, floor((end - padding) * fps) / fps)
                guard upper - lower >= max(1 / fps, 0.1) else { continue }
                let head = (lower - segment.start) / segment.speed
                let tail = (segment.end - upper) / segment.speed
                guard (head < 0.000001 || head >= 1 / fps - 0.000001),
                      (tail < 0.000001 || tail >= 1 / fps - 0.000001) else { continue }
                result.append(SilenceCut(segmentID: segment.id, start: lower, end: upper,
                    timelineStart: timeline.offset(of: segment.id) + (lower - segment.start) / segment.speed,
                    duration: (upper - lower) / segment.speed))
            }
        }
        return result
    }
}

// FFmpeg emits one RMS value per 50 ms window. Streaming metadata avoids keeping
// decoded PCM in memory, and overall RMS prevents opposite-phase stereo cancellation.
private final class AudioLevelCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    private var levels: [AudioLevel] = []
    func consume(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if let range = line.range(of: "pts_time:"), let value = Double(line[range.upperBound...].split(separator: " ").first ?? "") {
            time = value
        } else if let range = line.range(of: "lavfi.astats.Overall.RMS_level="), let value = Double(line[range.upperBound...]) {
            levels.append(AudioLevel(time: time, decibels: value.isFinite ? value : -120))
        }
    }
    var result: AudioOverview { lock.lock(); defer { lock.unlock() }; return AudioOverview(levels: levels) }
}

enum AudioAnalyzer {
    static func analyze(_ url: URL) async throws -> AudioOverview {
        guard let executable = FFmpeg.ffmpegPath else { throw FFmpegError(message: "Locate ffmpeg to analyze audio.") }
        let collector = AudioLevelCollector()
        let result = try await Shell.run(executable, ["-v", "error", "-nostdin", "-i", url.path, "-map", "0:a:0",
            "-af", "aresample=8000:async=1:first_pts=0,asetnsamples=n=400:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=RMS_level,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-",
            "-vn", "-f", "null", "-"], onStdoutLine: { collector.consume($0) })
        try Task.checkCancellation()
        guard result.status == 0 else { throw FFmpegError(message: "Audio analysis failed: \(result.stderrText.suffix(400))") }
        let overview = collector.result
        guard !overview.levels.isEmpty else { throw FFmpegError(message: "No audio levels could be read from this recording.") }
        return overview
    }
}

extension ClipTimeline {
    func removing(_ cuts: [SilenceCut]) -> ClipTimeline {
        var retained: [TimelineSegment] = []
        for segment in segments {
            var cursor = segment.start
            var first = true
            func append(_ end: Double) {
                guard end - cursor > 0.000001 else { return }
                retained.append(TimelineSegment(id: first ? segment.id : UUID(), start: cursor, end: end, speed: segment.speed))
                first = false
            }
            for cut in cuts.filter({ $0.included && $0.segmentID == segment.id }).sorted(by: { $0.start < $1.start }) {
                let lower = max(cursor, min(segment.end, cut.start))
                append(lower)
                cursor = max(cursor, min(segment.end, cut.end))
            }
            append(segment.end)
        }
        return ClipTimeline(segments: retained)
    }
}

struct WaveformView: View {
    let overview: AudioOverview
    let timeline: ClipTimeline
    /// The slice of the edited timeline drawn across this view's width. Nil draws all
    /// of it, which is what the silence review sheet wants.
    var window: TimelineViewport?
    var body: some View {
        Canvas { context, size in
            let count = max(1, Int(size.width / 2))
            let levels = overview.levels
            guard !levels.isEmpty else { return }
            let from = window?.start ?? 0
            let span = max(0.000001, (window?.visible ?? timeline.duration))
            var bars = Path()
            for column in 0..<count {
                let a = from + span * Double(column) / Double(count)
                let b = from + span * Double(column + 1) / Double(count)
                var loudest = -120.0
                // Sample the whole pixel's time span, including both sides of edit boundaries.
                for t in [a, (a + b) / 2, max(a, b - 0.00001)] {
                    guard let source = timeline.location(at: t)?.source else { continue }
                    let index = min(levels.count - 1, max(0, Int(source / AudioOverview.interval)))
                    if abs(levels[index].time - source) <= AudioOverview.interval * 2 {
                        loudest = max(loudest, levels[index].decibels)
                    }
                }
                let height = max(1, size.height * min(1, pow(10, loudest / 40)))
                bars.addRect(CGRect(x: Double(column) * size.width / Double(count), y: (size.height - height) / 2, width: 1.2, height: height))
            }
            context.fill(bars, with: .color(.teal.opacity(0.8)))
        }
        .accessibilityLabel("Audio waveform following timeline cuts and speed")
    }
}

struct SilenceReviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let clip: VideoItem
    let overview: AudioOverview
    @State private var threshold = -40.0
    @State private var minimum = 0.8
    @State private var padding = 0.15
    @State private var cuts: [SilenceCut] = []
    @State private var error: String?
    private var listeningSettings: ExportSettings {
        var settings = model.settings
        settings.format = .mp4; settings.audio = .aac
        return settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review silence cuts").font(.title2.weight(.semibold))
            Text("Low audio levels can also be intentional pauses. Listen before applying. Your source stays intact.")
                .font(.callout).foregroundStyle(.secondary)
            PlaybackCanvas(playback: model.playback).frame(height: 190)
            HStack {
                Text("Threshold \(Int(threshold)) dB").frame(width: 120, alignment: .leading)
                Slider(value: $threshold, in: -60 ... -20, step: 2).accessibilityLabel("Silence threshold")
            }
            HStack {
                Text("Pause ≥ \(String(format: "%.1f", minimum))s").frame(width: 120, alignment: .leading)
                Slider(value: $minimum, in: 0.3...3, step: 0.1).accessibilityLabel("Minimum silence length")
            }
            HStack {
                Text("Keep \(String(format: "%.2f", padding))s edges").frame(width: 120, alignment: .leading)
                Slider(value: $padding, in: 0.05...0.4, step: 0.05).accessibilityLabel("Speech padding")
            }
            List {
                ForEach($cuts) { $cut in
                    HStack {
                        Toggle("\(timelineTime(cut.timelineStart)) · remove \(String(format: "%.2f", cut.duration))s", isOn: $cut.included)
                        Spacer()
                        Button("Listen") {
                            model.playback.prepare(clip, settings: listeningSettings, at: max(0, cut.timelineStart - 0.5), play: true)
                        }
                    }
                }
            }.frame(minHeight: 110)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                let saved = cuts.filter(\.included).reduce(0) { $0 + $1.duration }
                let count = cuts.filter(\.included).count
                Text(cuts.isEmpty ? "No pauses match these settings." : "\(count) cut\(count == 1 ? "" : "s") · save \(timelineTime(saved))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Cuts") { apply() }.buttonStyle(.borderedProminent).disabled(saved == 0)
            }
        }.padding(20).frame(width: 610, height: 625)
        .onAppear { update(); model.playback.prepare(clip, settings: listeningSettings, at: 0, play: false) }
        .onChange(of: threshold) { _, _ in update() }
        .onChange(of: minimum) { _, _ in update() }
        .onChange(of: padding) { _, _ in update() }
        .onDisappear { model.playback.clear(); model.showPlayback = false; model.refreshPreview() }
    }
    private func update() {
        error = nil
        cuts = overview.cuts(in: clip.timeline, fps: clip.info!.fps, threshold: threshold, minimum: minimum, padding: padding)
    }
    private func apply() {
        guard model.selectedItem.map(ProjectClip.init) == ProjectClip(clip) else {
            error = "The recording changed. Close this review and analyze the current edit."; return
        }
        let timeline = clip.timeline.removing(cuts)
        guard !timeline.segments.isEmpty else { error = "Keep at least one section of the recording."; return }
        guard timeline.segments.allSatisfy({ $0.duration >= 1 / clip.info!.fps - 0.000001 }) else {
            error = "These cuts leave a section shorter than one frame. Increase the edge padding or uncheck a cut."; return
        }
        model.commitTimeline(timeline, name: "Remove Silence", selection: timeline.segments.first?.id)
        dismiss()
    }
}
