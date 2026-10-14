import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let yamVideoProject = UTType(exportedAs: "com.equicomtech.yamvideo.project", conformingTo: .json)
}

struct EditHistory {
    let name: String
    let project: VideoProject
    let fileURL: URL?
    let savedProject: VideoProject?
    let segmentID: UUID?
    let shotID: UUID?
    let regionID: UUID?
    let movieMode: Bool
}

struct SessionRecovery: Codable {
    var project: VideoProject
    var fileURL: URL?
    var savedProject: VideoProject?
}

@MainActor
extension AppModel {
    var project: VideoProject {
        VideoProject(projectID: projectID, clips: items.map(ProjectClip.init), settings: settings,
                     selection: selection, movieSettings: movieSettings)
    }

    nonisolated static var recoveryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo", isDirectory: true).appendingPathComponent("Recovery.yamvideo")
    }

    func historyEntry(_ name: String) -> EditHistory {
        EditHistory(name: name, project: project, fileURL: projectURL, savedProject: savedProject,
                    segmentID: selectedSegmentID, shotID: selectedShotID, regionID: selectedRegionID, movieMode: isMovieMode)
    }

    func restoreHistory(_ entry: EditHistory) {
        restore(entry.project)
        projectURL = entry.fileURL; savedProject = entry.savedProject
        selectedSegmentID = entry.segmentID
        selectedShotID = entry.shotID; selectedRegionID = entry.regionID
        isMovieMode = entry.movieMode
    }

    /// Continuous drags form one undo step; separate commands always start a new step.
    func beginEdit(_ name: String, key: String? = nil, invalidatesExport: Bool = true) {
        let now = Date()
        let scopedKey = key.map { "\(selection?.uuidString ?? "")-\($0)" }
        if scopedKey == nil || lastEditKey != scopedKey || now.timeIntervalSince(lastEditTime) > 0.6 {
            undoEntries.append(historyEntry(name))
            if undoEntries.count > 100 { undoEntries.removeFirst() }
        }
        lastEditKey = scopedKey; lastEditTime = now
        redoEntries.removeAll()
        hasUnsavedChanges = true
        playback.pause()
        if showPlayback { showPlayback = false; refreshPreview() }
        if invalidatesExport, let index = selectedIndex, items[index].info != nil, !items[index].status.isBusy { items[index].status = .ready }
        scheduleAutosave()
    }

    func scheduleAutosave() {
        guard let destination = sessionRecoveryURL else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
                try Task.checkCancellation()
                try writeRecovery(to: destination)
            } catch is CancellationError { } catch {
                statusMessage = "Autosave failed: \(error.localizedDescription)"
            }
        }
    }

    func writeProject(_ project: VideoProject, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func flushRecovery() {
        guard let destination = sessionRecoveryURL else { return }
        autosaveTask?.cancel()
        do { try writeRecovery(to: destination) }
        catch { statusMessage = "Could not save recovery: \(error.localizedDescription)" }
    }

    private func writeRecovery(to destination: URL) throws {
        let recovery = SessionRecovery(project: project, fileURL: projectURL, savedProject: savedProject)
        let data = try JSONEncoder().encode(recovery)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    func recoverSession() {
        guard let recovery = sessionRecoveryURL, FileManager.default.fileExists(atPath: recovery.path) else { return }
        do {
            let data = try Data(contentsOf: recovery)
            let session = try? JSONDecoder().decode(SessionRecovery.self, from: data)
            let stored = try session?.project ?? JSONDecoder().decode(VideoProject.self, from: data)
            try stored.validate()
            let recovered = stored.migrated(identity: UUID(deterministicFrom: data))
            restore(recovered)
            projectURL = session?.fileURL
            // A pre-identity recovery file holds the saved copy without an identity too;
            // give it the recovered one, or the two could never compare equal again.
            savedProject = session?.savedProject.map { $0.migrated(identity: recovered.projectID ?? UUID()) }
            hasUnsavedChanges = recovered != savedProject && !items.isEmpty
            if !items.isEmpty { statusMessage = "Restored your last editing session." }
        } catch { statusMessage = "Could not restore the last session: \(error.localizedDescription)" }
    }

    func restore(_ snapshot: VideoProject) {
        playback.clear(); showPlayback = false
        projectID = snapshot.projectID ?? UUID()
        let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = snapshot.clips.map { record in
            var item = record.item()
            if let old = previous[item.id] { item.previewFraction = old.previewFraction }
            if !FileManager.default.fileExists(atPath: item.url.path) {
                item.status = .failed("Source missing. Use Locate Source to reconnect it.")
            }
            return item
        }
        settings = snapshot.settings
        movieSettings = snapshot.movieSettings ?? MovieSettings()
        movieTime = 0; movieOutput = nil
        selection = items.contains(where: { $0.id == snapshot.selection }) ? snapshot.selection : items.first?.id
        selectedSegmentID = nil; selectedShotID = nil; selectedRegionID = nil
        refreshPreview()
        for item in items where item.info == nil { retry(item.id) }
    }

    func undoEdit() {
        if let text = NSApp?.keyWindow?.firstResponder as? NSTextView, text.isEditable {
            text.undoManager?.undo(); return
        }
        guard !isConverting, let entry = undoEntries.popLast() else { return }
        redoEntries.append(historyEntry(entry.name))
        restoreHistory(entry)
        lastEditKey = nil
        hasUnsavedChanges = project != savedProject
        scheduleAutosave()
    }

    func redoEdit() {
        if let text = NSApp?.keyWindow?.firstResponder as? NSTextView, text.isEditable {
            text.undoManager?.redo(); return
        }
        guard !isConverting, let entry = redoEntries.popLast() else { return }
        undoEntries.append(historyEntry(entry.name))
        restoreHistory(entry)
        lastEditKey = nil
        hasUnsavedChanges = project != savedProject
        scheduleAutosave()
    }

    func saveProject(asCopy: Bool = false) {
        if !asCopy, let projectURL { save(to: projectURL, asCopy: false); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.yamVideoProject]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "Untitled.yamvideo"
        panel.title = "Save YamVideo Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url, asCopy: asCopy)
    }

    func save(to destination: URL, asCopy: Bool) {
        // Save As forks the document: the copy is a different project, so nothing still
        // addressing the original can edit the copy by mistake. A first save of an
        // untitled project, or saving over the same file, keeps its identity.
        let previousID = projectID
        if asCopy, let current = projectURL, current.standardizedFileURL != destination.standardizedFileURL {
            projectID = UUID()
        }
        do {
            try writeProject(project, to: destination)
            projectURL = destination; savedProject = project; hasUnsavedChanges = false
            scheduleAutosave()
            statusMessage = "Saved \(destination.lastPathComponent)."
        } catch {
            projectID = previousID
            statusMessage = "Could not save project: \(error.localizedDescription)"
        }
    }

    func newProject() {
        guard !isConverting else { return }
        beginEdit("New Project", invalidatesExport: false)
        playback.clear(); showPlayback = false
        projectID = UUID()
        items.removeAll(); selection = nil; selectedSegmentID = nil
        projectURL = nil; savedProject = nil
        isMovieMode = false; movieSettings = MovieSettings()
        refreshPreview()
        statusMessage = "New project. Previous work is available with Undo."
    }

    func promptForProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yamVideoProject]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openProject(at: url) }
    }

    func openProject(at url: URL) {
        guard !isConverting else { statusMessage = "Finish or stop the export before opening a project."; return }
        do {
            let opened = try VideoProject.decodeMigrating(from: Data(contentsOf: url))
            beginEdit("Open Project", invalidatesExport: false)
            restore(opened)
            projectURL = url; savedProject = opened; hasUnsavedChanges = false
            scheduleAutosave()
            statusMessage = "Opened \(url.lastPathComponent). Previous work is available with Undo."
        } catch { statusMessage = "Could not open project: \(error.localizedDescription)" }
    }

    func locateSource() {
        guard let id = selection, let old = selectedItem else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.acceptedTypes
        panel.message = "Locate the original source for \(old.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let info = try await FFmpeg.probe(url: url)
                if let original = old.info {
                    guard info.width == original.width, info.height == original.height,
                          abs(info.duration - original.duration) < 0.1, abs(info.fps - original.fps) < 0.01 else {
                        throw FFmpegError(message: "Choose the original video with matching dimensions and duration.")
                    }
                }
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                beginEdit("Locate Source")
                items[index].url = url; items[index].info = info
                items[index].crop = old.crop ?? info.fullFrame; items[index].status = .ready
                refreshPreview()
            } catch { statusMessage = error.localizedDescription }
        }
    }

    func updateSettings(_ value: ExportSettings) {
        guard value != settings else { return }
        beginEdit("Export Settings", key: "settings")
        settings = value
        for index in items.indices where items[index].info != nil && !items[index].status.isBusy {
            items[index].status = .ready
        }
        refreshPreview()
    }

    func togglePlayback() {
        if isMovieMode { toggleMoviePlayback(); return }
        if playback.isPlaying { playback.pause(); return }
        guard let item = selectedItem else { return }
        showPlayback = true
        let time = previewTime >= item.editedDuration - 0.02 ? 0 : previewTime
        playback.prepare(item, settings: settings, at: time, play: true)
    }

    func setPlaybackVisible(_ visible: Bool) {
        showPlayback = visible
        if visible, let item = selectedItem {
            playback.prepare(item, settings: settings, at: previewTime, play: false)
        } else { playback.pause(); refreshPreview() }
    }

    func stepFrame(_ direction: Double) {
        if isMovieMode, let plan = try? moviePlan() {
            playback.pause()
            seekMovie(to: movieTime + direction / max(1, plan.fps)); return
        }
        guard let item = selectedItem, let info = item.info, item.editedDuration > 0 else { return }
        playback.pause()
        setPreviewFraction((previewTime + direction / max(1, info.fps)) / item.editedDuration)
    }

    var selectedSegment: TimelineSegment? {
        guard let item = selectedItem else { return nil }
        return item.timeline.segments.first { $0.id == selectedSegmentID }
    }

    func selectSegment(_ id: UUID) {
        selectedSegmentID = id
        guard let item = selectedItem else { return }
        playback.pause()
        setPreviewFraction(item.timeline.offset(of: id) / max(0.001, item.editedDuration))
    }

    func commitTimeline(_ timeline: ClipTimeline, name: String, selection newSelection: UUID?) {
        guard let index = selectedIndex, !timeline.segments.isEmpty,
              timeline != items[index].timeline else { return }
        let old = items[index].timeline
        let oldTime = previewTime
        let sourceTime = old.location(at: oldTime)?.source ?? 0
        beginEdit(name)
        let oldCount = items[index].zoomShots.count
        items[index].zoomShots = timeline.remap(items[index].zoomShots, from: old)
        items[index].segments = timeline.segments
        items[index].previewFraction = (timeline.time(forSource: sourceTime) ?? min(oldTime, timeline.duration)) / max(0.001, timeline.duration)
        selectedSegmentID = newSelection
        let removed = oldCount - items[index].zoomShots.count
        statusMessage = removed > 0 ? "\(name). Removed \(removed) zoom(s) whose footage or space was removed; Undo restores them." : name
        refreshPreview()
    }

    func splitAtPlayhead() {
        guard let item = selectedItem, let info = item.info else { return }
        var timeline = item.timeline
        guard let id = timeline.split(at: previewTime, fps: info.fps) else {
            statusMessage = "Move the playhead inside a section to split it."; return
        }
        commitTimeline(timeline, name: "Split Section", selection: id)
    }

    func deleteSegment() {
        guard let item = selectedItem, let id = selectedSegmentID else { return }
        var timeline = item.timeline
        guard timeline.segments.count > 1 else {
            statusMessage = "Keep at least one section. Remove the video from the sidebar to discard it."; return
        }
        guard let index = timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        timeline.segments.remove(at: index)
        commitTimeline(timeline, name: "Delete Section", selection: timeline.segments[min(index, timeline.segments.count - 1)].id)
    }

    func moveSegment(_ id: UUID, to index: Int) {
        guard let item = selectedItem else { return }
        var timeline = item.timeline
        guard let old = timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(0, index), timeline.segments.count - 1)
        guard old != destination else { return }
        let segment = timeline.segments.remove(at: old)
        timeline.segments.insert(segment, at: destination)
        commitTimeline(timeline, name: "Move Section", selection: id)
    }

    func trimSegment(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let item = selectedItem, let info = item.info else { return }
        var timeline = item.timeline
        guard let index = timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        let rate = max(1, info.fps)
        var segment = timeline.segments[index]
        // Restore hidden footage only as far as the nearest other retained source range.
        let others = timeline.segments.filter { $0.id != id }
        let lower = others.filter { $0.end <= segment.start + 0.000001 }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= segment.end - 0.000001 }.map(\.start).min() ?? info.duration
        let minimum = ceil(max(1, segment.speed)) / rate
        if let start, start.isFinite { segment.start = min(segment.end - minimum, max(lower, (start * rate).rounded() / rate)) }
        if let end, end.isFinite { segment.end = max(segment.start + minimum, min(upper, (end * rate).rounded() / rate)) }
        timeline.segments[index] = segment
        commitTimeline(timeline, name: "Trim Section", selection: id)
    }

    func trimToPlayhead(start: Bool) {
        guard let item = selectedItem, let location = item.timeline.location(at: previewTime) else { return }
        let segment = item.timeline.segments[location.index]
        trimSegment(segment.id, start: start ? location.source : nil, end: start ? nil : location.source)
    }

    func setSegmentSpeed(_ id: UUID, speed: Double) {
        guard speed.isFinite, (0.25...4).contains(speed), let item = selectedItem else { return }
        var timeline = item.timeline
        guard let index = timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        guard item.timeline.segments[index].sourceDuration / speed >= 1 / max(1, item.info?.fps ?? 30) - 0.000001 else {
            statusMessage = "This section is too short for that speed. Keep at least one output frame."; return
        }
        timeline.segments[index].speed = speed
        commitTimeline(timeline, name: "Change Section Speed", selection: id)
    }
}

// MARK: - Timeline viewport

extension AppModel {
    /// Keeps the viewport's length matching whatever the timeline is now, and starts a
    /// newly selected clip zoomed out. Called whenever the timeline is rebuilt.
    func syncViewport() {
        let total = selectedItem?.editedDuration ?? 0
        if abs(viewport.total - total) > 0.0005 { viewport.resize(total: total) }
    }

    /// Zoom out to the whole recording.
    func zoomTimelineToFit() {
        viewport.fit()
    }

    /// One step in or out, holding the playhead still when it is on screen and the
    /// middle of the view when it is not.
    func zoomTimeline(in zoomIn: Bool) {
        viewport.zoom(by: zoomIn ? TimelineViewport.step : 1 / TimelineViewport.step, keeping: viewportAnchor)
    }

    /// What a zoom should hold still: the playhead if you can see it, otherwise the
    /// centre of what you are looking at. Zooming away from the playhead when it is off
    /// screen would drag the view somewhere you did not ask to go.
    var viewportAnchor: Double {
        let time = previewTime
        return viewport.contains(time) ? time : viewport.start + viewport.visible / 2
    }

    /// Scroll the timeline so the playhead stays in view while it is moving.
    func followPlayhead() {
        viewport.reveal(previewTime)
    }
}
