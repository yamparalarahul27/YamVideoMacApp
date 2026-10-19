import AppKit
import UniformTypeIdentifiers

@MainActor
extension AppModel {
    func moviePlan() throws -> MoviePlan {
        try MoviePlan(items: items.map(\.effective), movieSettings: movieSettings, settings: settings)
    }

    func setMovieMode(_ enabled: Bool) {
        playback.clear(); showPlayback = false
        isMovieMode = enabled
        if enabled { prepareMovie(play: false) } else { refreshPreview() }
    }

    func prepareMovie(play: Bool) {
        do {
            let plan = try moviePlan()
            movieTime = min(movieTime, max(0, plan.duration - 1 / max(1, plan.fps)))
            playback.prepareMovie(plan, settings: settings, at: movieTime, play: play)
        } catch { statusMessage = error.localizedDescription }
    }

    func toggleMoviePlayback() {
        if playback.isPlaying { playback.pause(); return }
        if let plan = try? moviePlan(), movieTime >= plan.duration - 0.05 { movieTime = 0 }
        prepareMovie(play: true)
    }

    func seekMovie(to seconds: Double) {
        guard let plan = try? moviePlan() else { return }
        movieTime = min(max(0, seconds), max(0, plan.duration - 1 / max(1, plan.fps)))
        playback.seek(to: movieTime)
    }

    func changeMovieCanvas(_ canvas: MovieCanvas) {
        guard canvas != movieSettings.canvas else { return }
        perform([.setMovieCanvas(canvas)])
    }

    func includeInMovie(_ id: UUID, included: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].includedInMovie != included else { return }
        playback.clear()
        perform([.setIncludedInMovie(clip: id, included: included)])
    }

    func moveMovieClip(_ id: UUID, by distance: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + distance), items.count - 1)
        guard target != index else { return }
        var order = items.map(\.id)
        order.insert(order.remove(at: index), at: target)
        movieTime = 0
        perform([.setMovieOrder(order)])
    }

    func editMovieClip(_ id: UUID) {
        selection = id
        setMovieMode(false)
    }

    func promptForMovieExport() {
        guard !isConverting else { return }
        do {
            let plan = try moviePlan()
            let panel = NSSavePanel()
            panel.allowedContentTypes = settings.format == .mp4 ? [.mpeg4Movie] : settings.format == .gif ? [.gif] : [.webP]
            panel.nameFieldStringValue = (projectURL?.deletingPathExtension().lastPathComponent ?? "YamVideo-Movie") + "." + settings.format.fileExtension
            panel.title = "Export Movie"
            if let directory = settings.outputFolder { panel.directoryURL = directory }
            guard panel.runModal() == .OK, let output = panel.url else { return }
            // Export to a unique sibling, then atomically publish it. A cancelled export
            // cannot destroy the previous file even after confirming Replace in the panel.
            startMovieExport(plan: plan, output: output)
        } catch { statusMessage = error.localizedDescription }
    }

    func startMovieExport(plan: MoviePlan, output: URL) {
        guard !isConverting else { return }
        let destination = output.resolvingSymlinksInPath().standardizedFileURL
        guard !items.contains(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL == destination }) else {
            statusMessage = "Choose a destination other than a source recording."; return
        }
        playback.pause()
        let exportSettings = settings
        isConverting = true; movieProgress = 0
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".yamvideo-\(UUID().uuidString).\(settings.format.fileExtension)")
        movieExportTask = Task {
            defer {
                try? FileManager.default.removeItem(at: temporary)
                isConverting = false; movieProgress = nil; movieExportTask = nil
            }
            do {
                try await FFmpeg.exportMovie(plan: plan, settings: exportSettings, output: temporary) { [weak self] value in
                    Task { @MainActor in self?.movieProgress = value }
                }
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: output.path) {
                    _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: output) }
                movieOutput = output
                statusMessage = "Exported movie with \(plan.clips.count) recordings."
            } catch is CancellationError { statusMessage = "Movie export cancelled." }
            catch { statusMessage = "Movie export failed: \(error.localizedDescription)" }
        }
    }
}
