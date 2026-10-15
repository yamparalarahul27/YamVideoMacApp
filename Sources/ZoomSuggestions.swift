import Foundation
import SwiftUI

struct ZoomSuggestion: Identifiable {
    var id: UUID { shot.id }
    var shot: ZoomShot
    var score: Double
    var included = true
}

enum ZoomAnalyzer {
    static let width = 160
    static let height = 90

    /// Proposes framing around concentrated visual changes. It deliberately ignores
    /// whole-screen changes: this is a motion heuristic, not cursor/click recognition.
    static func activity(previous: [UInt8], current: [UInt8]) -> (point: CGPoint, score: Double)? {
        guard previous.count == width * height, current.count == previous.count else { return nil }
        var weights = [Double](repeating: 0, count: 16 * 9)
        var changed = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let delta = abs(Int(current[index]) - Int(previous[index]))
                if delta > 18 { changed += 1; weights[(y / 10) * 16 + x / 10] += Double(delta - 18) }
            }
        }
        let fraction = Double(changed) / Double(previous.count)
        guard fraction > 0.0008, fraction < 0.35, let maximum = weights.max(), maximum > 60 else { return nil }
        let threshold = max(60, maximum * 0.18)
        var seen = Set<Int>()
        var best: (CGPoint, Double)?
        for index in weights.indices where weights[index] >= threshold && !seen.contains(index) {
            var pending = [index], component: [Int] = []
            seen.insert(index)
            while let tile = pending.popLast() {
                component.append(tile)
                let x = tile % 16, y = tile / 16
                for neighbor in [x > 0 ? tile - 1 : -1, x < 15 ? tile + 1 : -1, y > 0 ? tile - 16 : -1, y < 8 ? tile + 16 : -1] {
                    if neighbor >= 0, weights[neighbor] >= threshold, seen.insert(neighbor).inserted { pending.append(neighbor) }
                }
            }
            guard component.count <= 45 else { continue }
            let mass = component.reduce(0.0) { $0 + weights[$1] }
            let x = component.reduce(0.0) { $0 + Double(($1 % 16) * 10 + 5) * weights[$1] } / mass
            let y = component.reduce(0.0) { $0 + Double(($1 / 16) * 10 + 5) * weights[$1] } / mass
            let score = mass / sqrt(Double(component.count))
            if best == nil || score > best!.1 { best = (CGPoint(x: x / Double(width), y: y / Double(height)), score) }
        }
        return best.map { ($0.0, $0.1) }
    }

    static func proposals(frames: Data, rate: Double, clip: VideoItem) -> [ZoomSuggestion] {
        guard let info = clip.info, rate > 0 else { return [] }
        let crop = clip.crop ?? info.fullFrame
        return proposals(frames: frames, duration: clip.editedDuration, level: 1.5, existing: clip.zoomShots) { index, spot in
            guard let time = clip.timeline.time(forSource: Double(index) / rate) else { return nil }
            let point = CGPoint(x: spot.x * Double(info.width), y: spot.y * Double(info.height))
            return crop.contains(point) ? (time, point) : nil
        }
    }

    /// Zooms on a recording's screen, from frames of the screen recording taken `rate` times
    /// a second from `start` seconds into it: each at the edited time its footage plays,
    /// aimed in the screen recording's pixels. 2×, as screen text needs more than a face.
    static func screenProposals(frames: Data, rate: Double, start: Double, clip: VideoItem) -> [ZoomSuggestion] {
        guard let screen = clip.screen, rate > 0 else { return [] }
        let picture = screen.picture
        return proposals(frames: frames, duration: clip.editedDuration, level: 2, existing: screen.zooms) { index, spot in
            let moment = start + Double(index) / rate
            guard let time = clip.timeline.time(forSource: moment - screen.offset) else { return nil }
            let point = CGPoint(x: spot.x * Double(screen.info.width), y: spot.y * Double(screen.info.height))
            return picture.contains(point) ? (time, point) : nil
        }
    }

    /// The best moments of local activity in `frames`, at most one in six seconds and one
    /// for each eight seconds of video, clear of `existing`. `place` gives a frame's edited
    /// time and the point to aim at, or nil when that footage or point is not shown.
    static func proposals(frames: Data, duration: Double, level: Double, existing: [ZoomShot],
                          place: (_ index: Int, _ spot: CGPoint) -> (time: Double, target: CGPoint)?) -> [ZoomSuggestion] {
        guard duration >= 1.5 else { return [] }
        let stride = width * height
        let count = frames.count / stride
        guard count >= 2 else { return [] }
        var candidates: [ZoomSuggestion] = []
        var previous = Array(frames[0..<stride])
        for index in 1..<count {
            let current = Array(frames[index * stride..<(index + 1) * stride])
            defer { previous = current }
            guard let activity = activity(previous: previous, current: current),
                  let placed = place(index, activity.point) else { continue }
            let start = max(0, placed.time - 0.35)
            let hold = min(2.0, duration - start - 2 * ZoomShot.ease)
            guard hold >= 0.5 else { continue }
            let shot = ZoomShot(start: start, hold: hold, level: level, target: placed.target)
            guard !existing.contains(where: { $0.overlaps(shot) }) else { continue }
            candidates.append(ZoomSuggestion(shot: shot, score: activity.score))
        }
        var selected: [ZoomSuggestion] = []
        let maximum = min(20, max(1, Int(duration / 8)))
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            if selected.allSatisfy({ abs($0.shot.start - candidate.shot.start) >= 6 && !$0.shot.overlaps(candidate.shot) }) {
                selected.append(candidate)
                if selected.count == maximum { break }
            }
        }
        return selected.sorted { $0.shot.start < $1.shot.start }
    }

    static func analyze(_ clip: VideoItem) async throws -> [ZoomSuggestion] {
        guard let info = clip.info, let executable = FFmpeg.ffmpegPath else { throw FFmpegError(message: "Load a recording and locate ffmpeg first.") }
        let rate = min(2, 1200 / max(1, info.duration))
        let result = try await Shell.run(executable, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", clip.url.path,
            "-vf", "fps=\(String(format: "%.8f", rate)),scale=\(width):\(height):flags=area,format=gray",
            "-frames:v", "1200", "-an", "-f", "rawvideo", "-pix_fmt", "gray", "-"])
        try Task.checkCancellation()
        guard result.status == 0 else { throw FFmpegError(message: "Could not analyze the recording: \(result.stderrText.suffix(500))") }
        return proposals(frames: result.stdout, rate: rate, clip: clip)
    }

    /// Suggest Zooms on the screen recording: only the part of it the edit shows is read.
    static func analyzeScreen(_ clip: VideoItem) async throws -> [ZoomSuggestion] {
        guard let screen = clip.screen, let executable = FFmpeg.ffmpegPath else { throw FFmpegError(message: "Add a screen recording and locate ffmpeg first.") }
        let segments = clip.timeline.segments
        let from = max(0, (segments.map(\.start).min() ?? 0) + screen.offset)
        let to = min(screen.info.duration, (segments.map(\.end).max() ?? 0) + screen.offset)
        guard to - from >= 1.5 else { return [] }
        let rate = min(2, 1200 / (to - from))
        let result = try await Shell.run(executable, ["-hide_banner", "-loglevel", "error", "-nostdin",
            "-ss", String(format: "%.3f", from), "-t", String(format: "%.3f", to - from), "-i", screen.url.path,
            "-vf", "fps=\(String(format: "%.8f", rate)),scale=\(width):\(height):flags=area,format=gray",
            "-frames:v", "1200", "-an", "-f", "rawvideo", "-pix_fmt", "gray", "-"])
        try Task.checkCancellation()
        guard result.status == 0 else { throw FFmpegError(message: "Could not analyze the screen recording: \(result.stderrText.suffix(500))") }
        return screenProposals(frames: result.stdout, rate: rate, start: from, clip: clip)
    }
}

@MainActor
extension AppModel {
    /// `screen` looks at the recording's screen recording, for zooms on the screen.
    func suggestZooms(screen: Bool = false) {
        guard !isAnalyzingZooms, let clip = selectedItem, clip.info != nil, !screen || clip.screen != nil else { return }
        playback.pause()
        isAnalyzingZooms = true
        suggestingScreenZooms = screen
        let snapshot = ProjectClip(clip)
        zoomAnalysisTask = Task {
            defer { isAnalyzingZooms = false; zoomAnalysisTask = nil }
            do {
                let suggestions = screen ? try await ZoomAnalyzer.analyzeScreen(clip) : try await ZoomAnalyzer.analyze(clip)
                try Task.checkCancellation()
                guard let current = selectedItem, ProjectClip(current) == snapshot else {
                    statusMessage = "The recording changed during analysis. Run Suggest Zooms again."; return
                }
                zoomSuggestions = suggestions
                zoomSuggestionTimeline = current.timeline
                if suggestions.isEmpty {
                    statusMessage = screen ? "No clear local activity found on the screen. Add screen zooms at the moments you want to show."
                        : "No clear local activity found. Add manual zooms at the moments you want to emphasize."
                }
                else { showingZoomSuggestions = true }
            } catch is CancellationError { statusMessage = "Zoom analysis cancelled." }
            catch { statusMessage = error.localizedDescription }
        }
    }

    func cancelZoomAnalysis() { zoomAnalysisTask?.cancel() }

    func previewZoomSuggestion(_ suggestion: ZoomSuggestion) {
        guard var clip = selectedItem else { return }
        if suggestingScreenZooms { clip.screen?.zooms.append(suggestion.shot) } else { clip.zoomShots.append(suggestion.shot) }
        playback.prepare(clip, settings: settings, at: max(0, suggestion.shot.start - 0.3), play: true)
    }

    func applyZoomSuggestions() {
        guard let index = selectedIndex else { return }
        let selected = zoomSuggestions.filter(\.included).map(\.shot)
        guard !selected.isEmpty else { return }
        // Suggestions are timed against the sections they were analysed on. If anyone —
        // the owner or a local agent — has recut the recording since, they no longer fit.
        guard items[index].timeline == zoomSuggestionTimeline else {
            showingZoomSuggestions = false
            statusMessage = "The recording changed since these suggestions were made. Run Suggest Zooms again."; return
        }
        let screen = suggestingScreenZooms
        let existing = screen ? items[index].screen?.zooms ?? [] : items[index].zoomShots
        var added: [ZoomShot] = []
        for shot in selected where shot.end <= items[index].editedDuration + 0.001 {
            if !(existing + added).contains(where: { $0.overlaps(shot) }) { added.append(shot) }
        }
        showingZoomSuggestions = false
        playback.clear(); showPlayback = false
        guard !added.isEmpty else { statusMessage = "Every selected suggestion overlaps an existing zoom."; return }
        let clip = items[index].id
        let commands: [EditCommand] = added.map { screen ? .addScreenZoom(clip: clip, zoom: $0) : .addZoom(clip: clip, zoom: $0) }
        switch perform(commands, label: screen ? "Apply Screen Zoom Suggestions" : "Apply Zoom Suggestions") {
        case .success:
            if screen { selectedScreenZoomID = added.first?.id } else { selectedShotID = added.first?.id }
            statusMessage = "Added \(added.count) editable \(screen ? "screen " : "")zoom suggestions."
        case .failure(let error):
            statusMessage = error.message
        }
    }
}

struct ZoomSuggestionsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.suggestingScreenZooms ? "Suggested screen zooms" : "Suggested zooms").font(.title2.weight(.semibold))
            Text("Based on local visual activity. Preview the framing and choose what to keep. These suggestions do not recognize clicks or understand the content.")
                .font(.callout).foregroundStyle(.secondary)
            PlaybackCanvas(playback: model.playback).frame(height: 240)
            List {
                ForEach($model.zoomSuggestions) { $suggestion in
                    HStack {
                        Toggle(isOn: $suggestion.included) {
                            Text("\(timelineTime(suggestion.shot.start)) · \(suggestion.shot.levelLabel) zoom")
                        }
                        Spacer()
                        Button("Preview") { model.previewZoomSuggestion(suggestion) }
                    }.padding(.vertical, 4)
                }
            }.frame(minHeight: 110)
            HStack {
                Text("All processing stays on this Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.showingZoomSuggestions = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add Selected") { model.applyZoomSuggestions() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.zoomSuggestions.contains(where: \.included))
            }
        }.padding(20).frame(width: 580, height: 565)
        .onAppear {
            if let first = model.zoomSuggestions.first { model.previewZoomSuggestion(first) }
        }
        .onDisappear { model.playback.clear(); model.showPlayback = false; model.refreshPreview() }
    }
}
