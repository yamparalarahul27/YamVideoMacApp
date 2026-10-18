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
    /// Stumbles from the transcript this cut takes out, if any.
    var stumbles: [Stumble] = []
    /// Whether it also shortens a pause.
    var pause = true

    /// What it takes out, for the review list: "Pause", "Filler “um” and pause".
    var reason: String {
        let words = stumbles.map(\.label).joined(separator: ", ")
        if words.isEmpty { return "Pause" }
        return pause ? words + " and pause" : words
    }
    /// For agents: "pause", "filler", "repeat", "restart", "fragment".
    var kinds: [String] {
        var kinds: [String] = []
        for kind in stumbles.map(\.kind.rawValue) where !kinds.contains(kind) { kinds.append(kind) }
        return pause ? kinds + ["pause"] : kinds
    }
}

struct AudioOverview: Sendable {
    static let interval = 0.05
    let levels: [AudioLevel]

    /// The silence review's cuts: every pause of at least `minimum`, keeping `padding` of
    /// it on each side. The auto edit's planner, without stumbles.
    func cuts(in timeline: ClipTimeline, fps: Double, threshold: Double, minimum: Double, padding: Double) -> [SilenceCut] {
        CutPlanner.cuts(levels: self, timeline: timeline, fps: fps,
                        rule: PauseRule(threshold: threshold, minimum: minimum, padding: padding))
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
    /// Stumbles from the recording's transcript, offered beside the pauses.
    var stumbles: [Stumble] = []
    var initialRule = PauseRule.natural
    var includeStumbles = false
    /// The auto edit being reviewed: applying also sets its captions and loudness.
    var plan: AutoEditPlan?
    @State private var threshold = -40.0
    @State private var minimum = 0.8
    @State private var padding = 0.15
    @State private var cuttingStumbles = false
    @State private var configured = false
    @State private var cuts: [SilenceCut] = []
    @State private var error: String?
    private var listeningSettings: ExportSettings {
        var settings = model.settings
        settings.format = .mp4; settings.audio = .aac
        return settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan == nil ? "Review silence cuts" : "Review the auto edit's cuts").font(.title2.weight(.semibold))
            Text(plan == nil
                 ? "Low audio levels can also be intentional pauses. Listen before applying. Your source stays intact."
                 : "Pauses, and stumbles from the transcript. Listen, uncheck any you want to keep, then apply; captions and loudness are set in the same step.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PlaybackCanvas(playback: model.playback).frame(height: 190)
            HStack {
                Text("Threshold \(Int(threshold)) dB").frame(width: 120, alignment: .leading)
                Slider(value: $threshold, in: -60 ... -20, step: 2).accessibilityLabel("Silence threshold")
            }
            HStack {
                Text("Pause ≥ \(String(format: "%.2f", minimum))s").frame(width: 120, alignment: .leading)
                Slider(value: $minimum, in: 0.3...3, step: 0.02).accessibilityLabel("Minimum silence length")
            }
            HStack {
                Text("Keep \(String(format: "%.2f", padding))s edges").frame(width: 120, alignment: .leading)
                Slider(value: $padding, in: 0.05...0.4, step: 0.01).accessibilityLabel("Speech padding")
            }
            if !stumbles.isEmpty {
                Toggle("Stumbles from the transcript (\(stumbles.count): “um”s, repeats and restarts)", isOn: $cuttingStumbles)
            }
            List {
                ForEach($cuts) { $cut in
                    HStack {
                        Toggle("\(timelineTime(cut.timelineStart)) · remove \(String(format: "%.2f", cut.duration))s"
                               + (stumbles.isEmpty ? "" : " · \(cut.reason)"), isOn: $cut.included)
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
                Button(plan == nil ? "Apply Cuts" : "Apply") { apply() }.buttonStyle(.borderedProminent).disabled(saved == 0 && plan == nil)
            }
        }.padding(20).frame(width: 610, height: 625)
        .onAppear {
            if !configured {
                configured = true
                threshold = initialRule.threshold; minimum = initialRule.minimum; padding = initialRule.padding
                cuttingStumbles = includeStumbles
            }
            update(); model.playback.prepare(clip, settings: listeningSettings, at: 0, play: false)
        }
        .onChange(of: cuttingStumbles) { _, _ in update() }
        .onChange(of: threshold) { _, _ in update() }
        .onChange(of: minimum) { _, _ in update() }
        .onChange(of: padding) { _, _ in update() }
        .onDisappear { model.playback.clear(); model.showPlayback = false; model.refreshPreview() }
    }
    private func update() {
        error = nil
        // The sliders change the pause rule; its longer breaths after commas and sentences stay.
        var rule = initialRule
        rule.threshold = threshold; rule.minimum = minimum; rule.padding = padding
        cuts = CutPlanner.cuts(levels: overview, timeline: clip.timeline, fps: clip.info!.fps, rule: rule,
                               stumbles: cuttingStumbles ? stumbles : [], words: clip.transcript?.words ?? [])
    }
    private func apply() {
        if var plan {
            plan.cuts = cuts
            if let problem = model.applyReviewedAutoEdit(plan) { error = problem } else { dismiss() }
            return
        }
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
