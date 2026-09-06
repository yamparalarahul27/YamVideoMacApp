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
        guard let info = clip.info, clip.editedDuration >= 1.5, rate > 0 else { return [] }
        let stride = width * height
        let count = frames.count / stride
        guard count >= 2 else { return [] }
        let crop = clip.crop ?? info.fullFrame
        var candidates: [ZoomSuggestion] = []
        var previous = Array(frames[0..<stride])
        for index in 1..<count {
            let current = Array(frames[index * stride..<(index + 1) * stride])
            defer { previous = current }
            guard let activity = activity(previous: previous, current: current),
                  let time = clip.timeline.time(forSource: Double(index) / rate) else { continue }
            let point = CGPoint(x: activity.point.x * Double(info.width), y: activity.point.y * Double(info.height))
            guard crop.contains(point) else { continue }
            let start = max(0, time - 0.35)
            let hold = min(2.0, clip.editedDuration - start - 2 * ZoomShot.ease)
            guard hold >= 0.5 else { continue }
            let shot = ZoomShot(start: start, hold: hold, level: 1.5, target: point)
            guard !clip.zoomShots.contains(where: { $0.overlaps(shot) }) else { continue }
            candidates.append(ZoomSuggestion(shot: shot, score: activity.score))
        }
        var selected: [ZoomSuggestion] = []
        let maximum = min(20, max(1, Int(clip.editedDuration / 8)))
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
}

@MainActor
extension AppModel {
    func suggestZooms() {
        guard !isAnalyzingZooms, let clip = selectedItem, clip.info != nil else { return }
        playback.pause()
        isAnalyzingZooms = true
        let snapshot = ProjectClip(clip)
        zoomAnalysisTask = Task {
            defer { isAnalyzingZooms = false; zoomAnalysisTask = nil }
            do {
                let suggestions = try await ZoomAnalyzer.analyze(clip)
                try Task.checkCancellation()
                guard let current = selectedItem, ProjectClip(current) == snapshot else {
                    statusMessage = "The recording changed during analysis. Run Suggest Zooms again."; return
                }
                zoomSuggestions = suggestions
                if suggestions.isEmpty { statusMessage = "No clear local activity found. Add manual zooms at the moments you want to emphasize." }
                else { showingZoomSuggestions = true }
            } catch is CancellationError { statusMessage = "Zoom analysis cancelled." }
            catch { statusMessage = error.localizedDescription }
        }
    }

    func cancelZoomAnalysis() { zoomAnalysisTask?.cancel() }

    func previewZoomSuggestion(_ suggestion: ZoomSuggestion) {
        guard var clip = selectedItem else { return }
        clip.zoomShots.append(suggestion.shot)
        playback.prepare(clip, settings: settings, at: max(0, suggestion.shot.start - 0.3), play: true)
    }

    func applyZoomSuggestions() {
        guard let index = selectedIndex else { return }
        let selected = zoomSuggestions.filter(\.included).map(\.shot)
        guard !selected.isEmpty else { return }
        beginEdit("Apply Zoom Suggestions")
        var added: [ZoomShot] = []
        for shot in selected where shot.end <= items[index].editedDuration + 0.001 {
            if !items[index].zoomShots.contains(where: { $0.overlaps(shot) }) {
                items[index].zoomShots.append(shot); added.append(shot)
            }
        }
        items[index].zoomShots.sort { $0.start < $1.start }
        selectedShotID = added.first?.id
        showingZoomSuggestions = false
        playback.clear(); showPlayback = false
        statusMessage = "Added \(added.count) editable zoom suggestions."
        refreshPreview()
    }
}

struct ZoomSuggestionsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested zooms").font(.title2.weight(.semibold))
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
