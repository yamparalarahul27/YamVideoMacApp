import AppKit
import Foundation

/// The result of a transaction, or of a dry run of one.
struct EditReceipt: Equatable {
    /// The document revision after the transaction (unchanged for a dry run or no-op).
    var revision: Int
    /// Identifies the undo step this transaction created; nil when nothing changed.
    var transactionID: UUID?
    var changed: Bool
    var createdIDs: [UUID]
    var removedZooms: [UUID]
    /// Blur effects and markers dropped because their footage was cut away.
    var removedEffects: [UUID] = []
    var removedMarkers: [UUID] = []
    var affectedClips: [UUID]
}

/// One entry in the change feed agents poll. Job progress shares the feed, which is why
/// its sequence is separate from the document revision.
struct EditEvent: Equatable, Codable {
    enum Kind: String, Codable { case edit, undo, redo, document, media, session, job }
    var sequence: Int
    var revision: Int
    var kind: Kind
    var origin: EditOrigin
    var label: String
    var transactionID: UUID?
    var clips: [UUID]
    var date = Date()
}

/// What a local agent just changed, so the timeline can point at it for a moment
/// without moving the owner's selection.
struct AgentHighlight: Equatable {
    let id = UUID()
    var origin: String
    var label: String
    var clips: Set<UUID>
    /// Sections, zooms and blur areas that are new or different.
    var elements: Set<UUID>
}

/// A local client the app has heard from, for the Local agents panel.
struct AgentClient: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var lastSeen: Date
    var lastAction: String
}

/// A continuous human interaction — a drag, a slider, typing a field — that becomes one
/// transaction when it ends. Until then the published state shows it live while the
/// committed document, which agents and history see, stays where it was.
struct OpenGesture {
    let key: String
    var base: VideoProject
    /// The undo step, captured with the selection as it was when the gesture began.
    let history: EditHistory
    var lastUpdate: Date
}

/// A finished agent request, kept for the whole session so a retry with the same
/// request ID returns the original answer instead of applying the edit twice.
struct AgentRequestRecord {
    let payloadHash: Data
    let response: Data
}

/// Identity and history of the open document's editing session.
struct EditSessionState {
    /// Fresh for every open, new project, recovery and identity change; requests
    /// addressed to an old session are refused rather than applied to the wrong document.
    var sessionID = UUID()
    /// The project this session was opened for.
    var projectID: UUID?
    /// Increments once per committed transaction, undo or redo, never per drag update.
    var revision = 0
    var events: [EditEvent] = []
    var nextSequence = 1
    var gesture: OpenGesture?

    static let eventLimit = 1000
}

@MainActor
extension AppModel {
    /// The document as last committed: during a gesture, the state before it began.
    var committedProject: VideoProject { editSession.gesture?.base ?? project }

    var revision: Int { editSession.revision }

    // MARK: Transactions

    /// Applies `commands` as one transaction: all of them, validated together, as one
    /// undo step and one revision — or none of them. Agents pass `expectedRevision`; a
    /// stale one is refused instead of being merged over somebody else's edit.
    @discardableResult
    func perform(_ commands: [EditCommand], label: String? = nil, origin: EditOrigin = .human,
                 expectedRevision: Int? = nil, dryRun: Bool = false) -> Result<EditReceipt, EditError> {
        let label = label ?? commands.first?.defaultLabel ?? "Edit"
        if let refusal = admit(origin, expectedRevision: expectedRevision) { return .failure(refusal) }
        let base = project
        let outcome: EditOutcome
        do { outcome = try ProjectReducer.apply(commands, to: base) }
        catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid(error.localizedDescription)) }

        var receipt = EditReceipt(revision: revision, transactionID: nil, changed: outcome.project != base,
                                  createdIDs: outcome.createdIDs, removedZooms: outcome.removedZooms,
                                  removedEffects: outcome.removedEffects, removedMarkers: outcome.removedMarkers,
                                  affectedClips: Self.changedClips(from: base, to: outcome.project))
        guard !dryRun, receipt.changed else { return .success(receipt) }

        let transaction = UUID()
        record(historyEntry(label, transaction: transaction, origin: origin))
        adopt(outcome.project)
        receipt.transactionID = transaction
        receipt.revision = finishCommit(.edit, origin: origin, label: label, transaction: transaction,
                                        clips: receipt.affectedClips)
        if !origin.isHuman { announceAgentChange(origin, label: label, from: base, to: project) }
        return .success(receipt)
    }

    /// Whether `origin` may change the document right now. A human command first closes
    /// any open gesture — a separate action always starts a new undo step.
    func admit(_ origin: EditOrigin, expectedRevision: Int?) -> EditError? {
        guard !origin.isHuman else { endGesture(); return nil }
        if agentsPaused {
            return EditError(code: .agentsPaused, message: "Agent edits are paused in YamVideo. Ask the owner to resume them.")
        }
        if isConverting {
            return EditError(code: .exportInProgress, message: "An export is running. Edits resume when it finishes or is stopped.")
        }
        if let gesture = editSession.gesture {
            // A drag whose end event never arrived (the window lost focus mid-drag) must
            // not lock agents out indefinitely.
            if NSEvent.pressedMouseButtons == 0, Date().timeIntervalSince(gesture.lastUpdate) > 1 {
                endGesture()
            } else {
                return EditError(code: .interactionInProgress,
                                 message: "The owner is in the middle of an edit. Read state again once it ends.")
            }
        }
        if let expectedRevision, expectedRevision != revision {
            return EditError(code: .revisionConflict,
                             message: "The project is at revision \(revision), not \(expectedRevision). Read state and plan again.")
        }
        return nil
    }

    private func record(_ entry: EditHistory) {
        undoEntries.append(entry)
        if undoEntries.count > 100 { undoEntries.removeFirst() }
        redoEntries.removeAll()
    }

    /// Bookkeeping shared by every committed change. Returns the new revision.
    private func finishCommit(_ kind: EditEvent.Kind, origin: EditOrigin, label: String,
                              transaction: UUID?, clips: [UUID]) -> Int {
        hasUnsavedChanges = project != savedProject
        playback.pause()
        if showPlayback { showPlayback = false; refreshPreview() }
        if isMovieMode { prepareMovie(play: false) }
        scheduleAutosave()
        let revision = advance(kind, origin: origin, label: label, transaction: transaction, clips: clips)
        if projectID != editSession.projectID { rotateSession() }
        return revision
    }

    @discardableResult
    private func advance(_ kind: EditEvent.Kind, origin: EditOrigin, label: String,
                         transaction: UUID?, clips: [UUID]) -> Int {
        editSession.revision += 1
        appendEvent(kind, origin: origin, label: label, transaction: transaction, clips: clips)
        return editSession.revision
    }

    func appendEvent(_ kind: EditEvent.Kind, origin: EditOrigin, label: String,
                     transaction: UUID? = nil, clips: [UUID] = []) {
        editSession.events.append(EditEvent(sequence: editSession.nextSequence, revision: revision, kind: kind,
                                            origin: origin, label: label, transactionID: transaction, clips: clips))
        editSession.nextSequence += 1
        if editSession.events.count > EditSessionState.eventLimit {
            editSession.events.removeFirst(editSession.events.count - EditSessionState.eventLimit)
        }
        if [.edit, .undo, .redo, .document, .job].contains(kind), let event = editSession.events.last {
            recentActivity.insert(event, at: 0)
            if recentActivity.count > 40 { recentActivity.removeLast(recentActivity.count - 40) }
        }
    }

    /// Points at an agent's change for a moment and says who made it. Selection,
    /// playhead and focus stay exactly where the owner left them.
    func announceAgentChange(_ origin: EditOrigin, label: String, from old: VideoProject, to new: VideoProject) {
        let clips = Set(Self.changedClips(from: old, to: new))
        let before = Dictionary(uniqueKeysWithValues: old.clips.map { ($0.id, $0) })
        var elements: Set<UUID> = []
        for clip in new.clips where clips.contains(clip.id) {
            let previous = before[clip.id]
            let oldSections = Dictionary(uniqueKeysWithValues: (previous?.timeline.segments ?? []).map { ($0.id, $0) })
            elements.formUnion(clip.timeline.segments.filter { oldSections[$0.id] != $0 }.map(\.id))
            let oldZooms = Dictionary(uniqueKeysWithValues: (previous?.zoomShots ?? []).map { ($0.id, $0) })
            elements.formUnion(clip.zoomShots.filter { oldZooms[$0.id] != $0 }.map(\.id))
            let oldAreas = Dictionary(uniqueKeysWithValues: (previous?.blurRegions ?? []).map { ($0.id, $0) })
            elements.formUnion(clip.blurRegions.filter { oldAreas[$0.id] != $0 }.map(\.id))
        }
        let highlight = AgentHighlight(origin: origin.label, label: label, clips: clips, elements: elements)
        agentHighlight = highlight
        statusMessage = "\(origin.label): \(label)"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.agentHighlight?.id == highlight.id { self?.agentHighlight = nil }
        }
    }

    /// A different document, or the same file opened afresh: nothing addressed to the old
    /// session may apply. The revision keeps counting so it never repeats.
    func rotateSession() {
        editSession.sessionID = UUID()
        editSession.projectID = projectID
        agentRequests.removeAll()
        appendEvent(.session, origin: .human, label: "Session started")
    }

    static func changedClips(from old: VideoProject, to new: VideoProject) -> [UUID] {
        let before = Dictionary(uniqueKeysWithValues: old.clips.map { ($0.id, $0) })
        let after = Set(new.clips.map(\.id))
        return new.clips.filter { before[$0.id] != $0 }.map(\.id) + old.clips.map(\.id).filter { !after.contains($0) }
    }

    // MARK: Gestures

    /// Shows a drag's latest value live. The first update opens the gesture against the
    /// committed document; later ones replace the live value rather than accumulating,
    /// so `commands` always carry absolute values. An invalid intermediate value (a zoom
    /// dragged onto another) is skipped and the last good one stays on screen.
    @discardableResult
    func updateGesture(_ key: String, label: String, _ commands: [EditCommand]) -> EditError? {
        if let open = editSession.gesture, open.key != key { endGesture() }
        if editSession.gesture == nil {
            editSession.gesture = OpenGesture(key: key, base: project, history: historyEntry(label), lastUpdate: Date())
            playback.pause()
            if showPlayback { showPlayback = false }
        }
        guard let base = editSession.gesture?.base else { return nil }
        do {
            adopt(try ProjectReducer.apply(commands, to: base).project, refreshPreview: false)
            editSession.gesture?.lastUpdate = Date()
            return nil
        } catch {
            return error as? EditError ?? .invalid(error.localizedDescription)
        }
    }

    func isGestureOpen(_ key: String) -> Bool { editSession.gesture?.key == key }

    /// Commits an open gesture as one transaction, or nothing if it ended where it began.
    func endGesture() {
        guard let gesture = editSession.gesture else { return }
        editSession.gesture = nil
        guard project != gesture.base else { refreshPreview(); return }
        record(gesture.history)
        refreshPreview()
        _ = finishCommit(.edit, origin: .human, label: gesture.history.name, transaction: gesture.history.transactionID,
                         clips: Self.changedClips(from: gesture.base, to: project))
    }

    /// Abandons an open gesture, restoring the committed document. No history, no revision.
    func cancelGesture() {
        guard let gesture = editSession.gesture else { return }
        editSession.gesture = nil
        adopt(gesture.base)
    }

    // MARK: Undo and redo

    /// Undo and redo share the human's history. An agent names the step it means to
    /// undo; if anyone has edited since, the step on top is somebody else's and the
    /// request is refused rather than silently undoing their work.
    @discardableResult
    func undo(origin: EditOrigin = .human, expectedTransaction: UUID? = nil,
              expectedRevision: Int? = nil) -> Result<EditReceipt, EditError> {
        stepHistory(redo: false, origin: origin, expectedTransaction: expectedTransaction, expectedRevision: expectedRevision)
    }

    @discardableResult
    func redo(origin: EditOrigin = .human, expectedTransaction: UUID? = nil,
              expectedRevision: Int? = nil) -> Result<EditReceipt, EditError> {
        stepHistory(redo: true, origin: origin, expectedTransaction: expectedTransaction, expectedRevision: expectedRevision)
    }

    private func stepHistory(redo: Bool, origin: EditOrigin, expectedTransaction: UUID?,
                             expectedRevision: Int?) -> Result<EditReceipt, EditError> {
        if let refusal = admit(origin, expectedRevision: expectedRevision) { return .failure(refusal) }
        guard !isConverting else {
            return .failure(EditError(code: .exportInProgress, message: "Undo is unavailable while an export runs."))
        }
        guard let entry = redo ? redoEntries.last : undoEntries.last else {
            return .failure(EditError(code: .nothingToUndo, message: redo ? "There is nothing to redo." : "There is nothing to undo."))
        }
        if !origin.isHuman, entry.transactionID != expectedTransaction {
            return .failure(EditError(code: .historyConflict,
                message: "The most recent step is now \"\(entry.name)\" by \(entry.origin.label). Read state and decide again."))
        }
        let before = project
        let opposite = historyEntry(entry.name, transaction: entry.transactionID, origin: entry.origin)
        defer {
            if !origin.isHuman {
                announceAgentChange(origin, label: "\(redo ? "Redid" : "Undid") \(entry.name)", from: before, to: project)
            }
        }
        if redo { redoEntries.removeLast(); undoEntries.append(opposite) }
        else { undoEntries.removeLast(); redoEntries.append(opposite) }
        restoreHistory(entry, navigation: origin.isHuman)
        let clips = Self.changedClips(from: before, to: project)
        let revision = finishCommit(redo ? .redo : .undo, origin: origin, label: entry.name,
                                    transaction: entry.transactionID, clips: clips)
        return .success(EditReceipt(revision: revision, transactionID: entry.transactionID, changed: true,
                                    createdIDs: [], removedZooms: [], affectedClips: clips))
    }

    var undoTitle: String { historyTitle("Undo", undoEntries.last) }
    var redoTitle: String { historyTitle("Redo", redoEntries.last) }

    private func historyTitle(_ verb: String, _ entry: EditHistory?) -> String {
        guard let entry else { return verb }
        return entry.origin.isHuman ? "\(verb) \(entry.name)" : "\(verb) \(entry.name) (\(entry.origin.label))"
    }

    // MARK: Whole-document changes

    /// New Project and Open Project: one undoable step that swaps the whole document, and
    /// always a new session — even reopening the same file.
    func replaceDocument(_ document: VideoProject, label: String, fileURL: URL?, saved: VideoProject?) {
        endGesture()
        let before = project
        let session = editSession.sessionID
        record(historyEntry(label))
        restore(document)
        projectURL = fileURL; savedProject = saved
        _ = finishCommit(.document, origin: .human, label: label, transaction: undoEntries.last?.transactionID,
                         clips: Self.changedClips(from: before, to: project))
        // Reopening the same file keeps its identity, but is still a new session.
        if editSession.sessionID == session { rotateSession() }
    }

    /// Facts learned about a file — its probe — rather than an edit to it. Applied
    /// without an undo step, and written into the history too, so undoing past the
    /// moment a probe finished never forgets what the file is.
    func resolveMedia(_ id: VideoItem.ID, info: MediaInfo, subtitles: URL?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].info == nil else { return }
        func fill(_ clip: inout ProjectClip) {
            guard clip.id == id, clip.info == nil else { return }
            clip.info = info
            clip.crop = clip.crop?.evenClamped(in: info.fullFrame) ?? info.fullFrame
            clip.subtitles = clip.subtitles ?? subtitles
        }
        for entry in undoEntries.indices { for clip in undoEntries[entry].project.clips.indices { fill(&undoEntries[entry].project.clips[clip]) } }
        for entry in redoEntries.indices { for clip in redoEntries[entry].project.clips.indices { fill(&redoEntries[entry].project.clips[clip]) } }
        if let clips = editSession.gesture?.base.clips.indices {
            for clip in clips { fill(&editSession.gesture!.base.clips[clip]) }
        }
        items[index].info = info
        items[index].crop = items[index].crop?.evenClamped(in: info.fullFrame) ?? info.fullFrame
        items[index].subtitles = items[index].subtitles ?? subtitles
        items[index].status = .ready
        editSession.revision += 1
        appendEvent(.media, origin: .human, label: "Loaded \(items[index].name)", clips: [id])
    }

    // MARK: Publishing a document

    /// Makes `document` the visible state, keeping what is not part of the document:
    /// each recording's export status and playhead, the selection and the viewport.
    /// A recording whose sections changed keeps the same source frame under its playhead.
    func adopt(_ document: VideoProject, refreshPreview refresh: Bool = true) {
        let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let previousOrder = items.map(\.id)
        let settingsChanged = document.settings != settings
        let movieBefore = (items.filter(\.includedInMovie).map(ProjectClip.init), movieSettings, settings)
        projectID = document.projectID ?? projectID

        var unprobed: [VideoItem.ID] = []
        items = document.clips.map { clip in
            var item = clip.item()
            guard let old = previous[clip.id] else {
                if !FileManager.default.fileExists(atPath: item.url.path) {
                    item.status = .failed("Source missing. Use Locate Source to reconnect it.")
                } else if item.info == nil { unprobed.append(item.id) }
                return item
            }
            item.status = old.status
            item.previewFraction = old.previewFraction
            if old.timeline != item.timeline {
                let oldTime = old.editedDuration * old.previewFraction
                let source = old.timeline.location(at: oldTime)?.source ?? 0
                let time = item.timeline.time(forSource: source) ?? min(oldTime, item.editedDuration)
                item.previewFraction = min(1, max(0, time / max(0.001, item.editedDuration)))
            }
            var before = ProjectClip(old), after = clip
            before.includedInMovie = nil; after.includedInMovie = nil
            if before != after || settingsChanged, item.info != nil, !item.status.isBusy { item.status = .ready }
            return item
        }
        settings = document.settings
        movieSettings = document.movieSettings ?? MovieSettings()

        if previousOrder.contains(where: { id in !items.contains { $0.id == id } }) { playback.clear() }
        if let current = selection, !items.contains(where: { $0.id == current }) {
            let index = previousOrder.firstIndex(of: current) ?? 0
            selection = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        } else if selection == nil {
            selection = items.first?.id
        }
        let sections = sectionSelection.keeping(selectedItem?.timeline)
        if sections != sectionSelection { sectionSelection = sections }
        if let id = selectedShotID, selectedItem?.zoomShots.contains(where: { $0.id == id }) != true { selectedShotID = nil }
        if let id = selectedRegionID, selectedItem?.blurRegions.contains(where: { $0.id == id }) != true { selectedRegionID = nil }

        let movieAfter = (items.filter(\.includedInMovie).map(ProjectClip.init), movieSettings, settings)
        if movieBefore != movieAfter { movieOutput = nil }
        for id in unprobed { retry(id) }
        if refresh { refreshPreview() }
    }
}
