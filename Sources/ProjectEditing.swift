import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let yamVideoProject = UTType(exportedAs: "com.equicomtech.yamvideo.project", conformingTo: .json)
}

/// One undo step: the document as it was before a transaction, plus where the person
/// was looking, so undo returns both.
struct EditHistory {
    let name: String
    /// The transaction this step undoes. Redo keeps the same ID, so an agent can name
    /// exactly which step it means.
    let transactionID: UUID
    let origin: EditOrigin
    /// Mutable only so a finished probe can be written into history; see `resolveMedia`.
    var project: VideoProject
    let fileURL: URL?
    let savedProject: VideoProject?
    let sections: SectionSelection
    let shotID: UUID?
    let regionID: UUID?
    var effectID: UUID? = nil
    var markerID: UUID? = nil
    let movieMode: Bool
}

struct SessionRecovery: Codable {
    var project: VideoProject
    var fileURL: URL?
    var savedProject: VideoProject?
    /// SHA-256 of the named file as last opened or saved; see `diskConflict(at:)`.
    var savedFingerprint: Data?
}

@MainActor
extension AppModel {
    var project: VideoProject {
        VideoProject(projectID: projectID, clips: items.map(ProjectClip.init), settings: settings,
                     selection: selection, movieSettings: movieSettings)
    }

    nonisolated static var recoveryURL: URL {
        // A separate instance (a test, an acceptance run) keeps its own session.
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_RECOVERY_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo", isDirectory: true).appendingPathComponent("Recovery.yamvideo")
    }

    func historyEntry(_ name: String, transaction: UUID = UUID(), origin: EditOrigin = .human) -> EditHistory {
        EditHistory(name: name, transactionID: transaction, origin: origin, project: project,
                    fileURL: projectURL, savedProject: savedProject, sections: sectionSelection,
                    shotID: selectedShotID, regionID: selectedRegionID, effectID: selectedEffectID,
                    markerID: selectedMarkerID, movieMode: isMovieMode)
    }

    /// Restores a history step. With `navigation` off — an agent's undo — the document
    /// comes back but the person's selection, workspace and playhead stay where they are.
    func restoreHistory(_ entry: EditHistory, navigation: Bool = true) {
        let kept = (selection, isMovieMode, sectionSelection, selectedShotID, selectedRegionID,
                    Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.previewFraction) }))
        restore(entry.project)
        projectURL = entry.fileURL; savedProject = entry.savedProject
        if navigation {
            sectionSelection = entry.sections
            selectedShotID = entry.shotID; selectedRegionID = entry.regionID
            selectedEffectID = entry.effectID; selectedMarkerID = entry.markerID
            isMovieMode = entry.movieMode
        } else {
            if let id = kept.0, items.contains(where: { $0.id == id }) { selection = id }
            isMovieMode = kept.1
            for index in items.indices { if let fraction = kept.5[items[index].id] { items[index].previewFraction = fraction } }
            sectionSelection = kept.2.keeping(selectedItem?.timeline)
            if let id = kept.3, selectedItem?.zoomShots.contains(where: { $0.id == id }) == true { selectedShotID = id }
            if let id = kept.4, selectedItem?.blurRegions.contains(where: { $0.id == id }) == true { selectedRegionID = id }
            refreshPreview()
        }
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

    /// Writes atomically and returns the file's fingerprint. The conversion tables the
    /// project uses are copied into `YamVideo Assets` beside it first, so the file never
    /// names a table that is not next to it when this Mac has one to copy.
    @discardableResult
    func writeProject(_ project: VideoProject, to url: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        LUTStore.export(Self.tableHashes(project), beside: url)
        try data.write(to: url, options: .atomic)
        return Self.fingerprint(data)
    }

    /// The conversion tables a project's recordings use, by hash.
    nonisolated static func tableHashes(_ project: VideoProject) -> Set<String> {
        Set(project.clips.compactMap { $0.color?.technicalLUT?.sha256 })
    }

    /// Tables the project names that this Mac has nowhere: not in the store, and not in
    /// the assets folder beside `file` (which are taken into the store).
    func adoptTables(_ project: VideoProject, beside file: URL?) -> [String] {
        Self.tableHashes(project).sorted().filter { sha in
            if let file { return !LUTStore.adopt(sha, beside: file) }
            return !LUTStore.has(sha)
        }
    }

    nonisolated static func fingerprint(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// True when the named file is no longer what this window last opened or saved —
    /// another app, a sync service or a person changed it. Saving over it would discard
    /// their change, so callers ask first (people) or refuse (agents).
    func diskConflict(at url: URL) -> Bool {
        guard let savedFingerprint, let data = try? Data(contentsOf: url) else { return false }
        return Self.fingerprint(data) != savedFingerprint
    }

    func flushRecovery() {
        guard let destination = sessionRecoveryURL else { return }
        autosaveTask?.cancel()
        do { try writeRecovery(to: destination) }
        catch { statusMessage = "Could not save recovery: \(error.localizedDescription)" }
    }

    private func writeRecovery(to destination: URL) throws {
        let recovery = SessionRecovery(project: project, fileURL: projectURL, savedProject: savedProject,
                                       savedFingerprint: savedFingerprint)
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
            _ = adoptTables(recovered, beside: session?.fileURL)
            restore(recovered)
            projectURL = session?.fileURL
            // A pre-identity recovery file holds the saved copy without an identity too;
            // give it the recovered one, or the two could never compare equal again.
            savedProject = session?.savedProject.map { $0.migrated(identity: recovered.projectID ?? UUID()) }
            savedFingerprint = session?.savedFingerprint
            hasUnsavedChanges = recovered != savedProject && !items.isEmpty
            if !items.isEmpty { statusMessage = "Restored your last editing session." }
        } catch { statusMessage = "Could not restore the last session: \(error.localizedDescription)" }
    }

    func restore(_ snapshot: VideoProject) {
        playback.clear(); showPlayback = false
        projectID = snapshot.projectID ?? UUID()
        // A different document is a different session from the moment it appears, not
        // from its next edit — otherwise that edit would end the session it was sent in.
        if projectID != editSession.projectID { rotateSession() }
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
        selectedSegmentID = nil; selectedShotID = nil; selectedRegionID = nil; selectedGraphicID = nil
        refreshPreview()
        for item in items where item.info == nil { retry(item.id) }
    }

    func undoEdit() {
        if let text = NSApp?.keyWindow?.firstResponder as? NSTextView, text.isEditable {
            text.undoManager?.undo(); return
        }
        undo()
    }

    func redoEdit() {
        if let text = NSApp?.keyWindow?.firstResponder as? NSTextView, text.isEditable {
            text.undoManager?.redo(); return
        }
        redo()
    }

    func saveProject(asCopy: Bool = false) {
        if !asCopy, let projectURL {
            if diskConflict(at: projectURL) {
                let alert = NSAlert()
                alert.messageText = "\(projectURL.lastPathComponent) changed on disk"
                alert.informativeText = "Something else saved this project since you opened it. Saving now replaces that version."
                alert.addButton(withTitle: "Save a Copy…")
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: saveProject(asCopy: true); return
                case .alertSecondButtonReturn: break
                default: return
                }
            }
            save(to: projectURL, asCopy: false); return
        }
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
            savedFingerprint = try writeProject(project, to: destination)
            projectURL = destination; savedProject = project; hasUnsavedChanges = false
            if projectID != previousID { rotateSession() }
            scheduleAutosave()
            let missing = Self.tableHashes(project).filter { !LUTStore.has($0) }
            statusMessage = missing.isEmpty ? "Saved \(destination.lastPathComponent)."
                : "Saved \(destination.lastPathComponent), but \(missing.count) colour conversion file(s) are missing from this Mac and could not be copied beside it."
        } catch {
            projectID = previousID
            statusMessage = "Could not save project: \(error.localizedDescription)"
        }
    }

    func newProject() {
        guard !isConverting else { return }
        // Export settings carry over; recordings, edits and the movie do not.
        replaceDocument(VideoProject(projectID: UUID(), clips: [], settings: settings, selection: nil, movieSettings: nil),
                        label: "New Project", fileURL: nil, saved: nil)
        isMovieMode = false
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
            let data = try Data(contentsOf: url)
            let opened = try VideoProject.decodeMigrating(from: data)
            // Tables travel beside the project; take them in before anything renders.
            let missing = adoptTables(opened, beside: url)
            replaceDocument(opened, label: "Open Project", fileURL: url, saved: opened)
            savedFingerprint = Self.fingerprint(data)
            hasUnsavedChanges = false
            statusMessage = missing.isEmpty ? "Opened \(url.lastPathComponent). Previous work is available with Undo."
                : "Opened \(url.lastPathComponent). \(missing.count) colour conversion file(s) are missing; import DJI's conversion again in the Colour inspector."
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
                if case .failure(let error) = perform([.relinkMedia(clip: id, url: url, info: info)]) {
                    statusMessage = error.message
                }
            } catch { statusMessage = error.localizedDescription }
        }
    }

    /// `live` is a slider or text field still being changed: shown at once, committed as
    /// one undo step when `endGesture` is called or the next separate edit arrives.
    func updateSettings(_ value: ExportSettings, live: Bool = false) {
        if live { updateGesture("settings", label: "Export Settings", [.setExportSettings(value)]); return }
        if isGestureOpen("settings") {
            updateGesture("settings", label: "Export Settings", [.setExportSettings(value)])
            endGesture(); return
        }
        guard value != settings else { return }
        if case .failure(let error) = perform([.setExportSettings(value)]) { statusMessage = error.message }
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

    /// A section edit on the selected recording, then the selection and status line the
    /// timeline expects. `failure` replaces the reducer's wording where the timeline has
    /// a more specific hint for a person.
    @discardableResult
    private func editSections(_ command: EditCommand, name: String? = nil, failure: String? = nil,
                              select: (EditReceipt) -> UUID?) -> Bool {
        editSections([command], name: name ?? command.defaultLabel, failure: failure) { .single(select($0)) }
    }

    /// Several section edits as one step: one undo restores them all.
    @discardableResult
    private func editSections(_ commands: [EditCommand], name: String, failure: String? = nil,
                              select: (EditReceipt) -> SectionSelection) -> Bool {
        switch perform(commands, label: name) {
        case .success(let receipt):
            guard receipt.changed else { return false }
            sectionSelection = select(receipt)
            let removed = [(receipt.removedZooms.count, "zoom"), (receipt.removedEffects.count, "blur effect"),
                           (receipt.removedMarkers.count, "marker"), (receipt.removedGraphics.count, "graphic")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            statusMessage = removed.isEmpty ? name
                : "\(name). Removed \(removed.joined(separator: ", ")) whose footage or space was cut; Undo restores them."
            return true
        case .failure(let error):
            statusMessage = failure ?? error.message
            return false
        }
    }

    /// Replaces the selected recording's sections wholesale — silence removal's path.
    func commitTimeline(_ timeline: ClipTimeline, name: String, selection newSelection: UUID?) {
        guard let item = selectedItem, !timeline.segments.isEmpty, timeline != item.timeline else { return }
        editSections(.replaceSections(clip: item.id, sections: timeline.segments), name: name) { _ in newSelection }
    }

    func splitAtPlayhead() {
        guard let item = selectedItem, item.info != nil else { return }
        editSections(.splitSection(clip: item.id, at: previewTime),
                     failure: "Move the playhead inside a section to split it.") { $0.createdIDs.first }
    }

    /// Deletes every selected section as one step, then selects the section that took
    /// the first one's place.
    func deleteSegment() {
        guard let item = selectedItem else { return }
        let doomed = sectionSelection.ordered(in: item.timeline)
        guard let first = doomed.first, let index = item.timeline.segments.firstIndex(where: { $0.id == first.id }) else { return }
        guard doomed.count < item.timeline.segments.count else {
            statusMessage = item.timeline.segments.count == 1
                ? "Keep at least one section. Remove the video from the sidebar to discard it."
                : "Keep at least one section. Leave one unselected, or remove the video from the sidebar to discard it."
            return
        }
        let name = doomed.count == 1 ? EditCommand.deleteSection(clip: item.id, section: first.id).defaultLabel
            : "Delete \(doomed.count) Sections"
        editSections(doomed.map { .deleteSection(clip: item.id, section: $0.id) }, name: name) { _ in
            guard let segments = self.selectedItem?.timeline.segments, !segments.isEmpty else { return SectionSelection() }
            return .single(segments[min(index, segments.count - 1)].id)
        }
    }

    func moveSegment(_ id: UUID, to index: Int) {
        guard let item = selectedItem, let old = item.timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(0, index), item.timeline.segments.count - 1)
        guard old != destination else { return }
        editSections(.moveSection(clip: item.id, section: id, to: destination)) { _ in id }
    }

    /// The timeline's trim: unlike an agent's, a drag past a limit stops at it.
    func trimSegment(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let item = selectedItem, let info = item.info,
              let index = item.timeline.segments.firstIndex(where: { $0.id == id }) else { return }
        let timeline = item.timeline
        let rate = max(1, info.fps)
        var segment = timeline.segments[index]
        // Restore hidden footage only as far as the nearest other retained source range.
        let others = timeline.segments.filter { $0.id != id }
        let lower = others.filter { $0.end <= segment.start + 0.000001 }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= segment.end - 0.000001 }.map(\.start).min() ?? info.duration
        let minimum = ceil(max(1, segment.speed)) / rate
        if let start, start.isFinite { segment.start = min(segment.end - minimum, max(lower, (start * rate).rounded() / rate)) }
        if let end, end.isFinite { segment.end = max(segment.start + minimum, min(upper, (end * rate).rounded() / rate)) }
        guard segment != timeline.segments[index] else { return }
        editSections(.trimSection(clip: item.id, section: id, start: segment.start, end: segment.end)) { _ in id }
    }

    func trimToPlayhead(start: Bool) {
        guard let item = selectedItem, let location = item.timeline.location(at: previewTime) else { return }
        let segment = item.timeline.segments[location.index]
        trimSegment(segment.id, start: start ? location.source : nil, end: start ? nil : location.source)
    }

    func setSegmentSpeed(_ id: UUID, speed: Double) {
        guard let item = selectedItem else { return }
        editSections(.setSectionSpeed(clip: item.id, section: id, speed: speed)) { _ in id }
    }

    /// One speed for every selected section, as one step. If any section is too short
    /// for it, none change.
    func setSelectedSectionsSpeed(_ speed: Double) {
        guard let item = selectedItem else { return }
        let sections = sectionSelection.ordered(in: item.timeline).filter { $0.speed != speed }
        guard !sections.isEmpty else { return }
        let kept = sectionSelection
        editSections(sections.map { .setSectionSpeed(clip: item.id, section: $0.id, speed: speed) },
                     name: sectionSelection.count == 1 ? "Change Section Speed" : "Change Speed of \(sectionSelection.count) Sections") { _ in kept }
    }

    // MARK: Selecting sections

    /// A click on a section. ⇧ and ⌘ change the selection without moving the playhead,
    /// so you can gather sections while keeping your place.
    func clickSegment(_ id: UUID, at time: Double, extend: Bool = false, toggle: Bool = false) {
        guard let item = selectedItem else { return }
        guard extend || toggle else {
            selectedSegmentID = id
            playback.pause()
            setPreviewFraction(time / max(0.001, item.editedDuration))
            return
        }
        sectionSelection = sectionSelection.clicking(id, extend: extend, toggle: toggle, in: item.timeline)
    }

    /// ⌘A on the timeline.
    func selectAllSegments() {
        guard let item = selectedItem, !item.timeline.segments.isEmpty else { return }
        sectionSelection = .all(in: item.timeline, anchor: sectionSelection.anchor)
    }

    /// ⌘← / ⌘→: the section before or after the anchor, or the one under the playhead
    /// when nothing is selected. Stops at either end rather than wrapping.
    func selectAdjacentSegment(_ step: Int) {
        guard let item = selectedItem, !item.timeline.segments.isEmpty else { return }
        let segments = item.timeline.segments
        let target: Int
        if let anchor = sectionSelection.anchor, let index = segments.firstIndex(where: { $0.id == anchor }) {
            target = min(max(0, index + step), segments.count - 1)
        } else {
            target = item.timeline.location(at: previewTime)?.index ?? 0
        }
        selectSegment(segments[target].id)
    }

    /// ⇧Home / ⇧End: the playhead to where the selection starts or ends. Over several
    /// sections that is the first one's start and the last one's end.
    func movePlayheadToSelection(start: Bool) {
        guard let item = selectedItem else { return }
        let sections = sectionSelection.ordered(in: item.timeline)
        guard let edge = start ? sections.first : sections.last else { return }
        let offset = item.timeline.offset(of: edge.id)
        // The end is the last frame shown, not the first frame of whatever follows.
        let frame = 1 / max(1, item.info?.fps ?? 30)
        let time = start ? offset : max(offset, offset + edge.duration - frame)
        playback.pause()
        setPreviewFraction(time / max(0.001, item.editedDuration))
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

    /// Whether a drag happening now snaps: snapping is on and ⌥ is not held. Read on
    /// every step of a drag, so pressing or releasing ⌥ mid-drag takes effect at once.
    func dragSnaps(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        timelineSnapping && !modifiers.contains(.option)
    }
}
