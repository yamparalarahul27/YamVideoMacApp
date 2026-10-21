import AppKit
import Foundation

/// Gaps on the timeline: Delete and the trim handles leave space so nothing else moves,
/// ⇧⌘⌫ closes at once, a section slides into space or takes a place in the order, and
/// Close Gaps joins them. Only the timeline has gaps: edited time, playback and exports
/// do not.
@MainActor func gapsTests() async throws {
    func close(_ a: Double?, _ b: Double, _ tolerance: Double = 0.0005) -> Bool { a.map { abs($0 - b) < tolerance } ?? false }

    let gapA = TimelineSegment(start: 0, end: 0.6), gapB = TimelineSegment(start: 0.6, end: 1.2)
    let gapC = TimelineSegment(start: 1.2, end: 1.8), gapD = TimelineSegment(start: 1.8, end: 3)
    let gapTimeline = ClipTimeline(segments: [gapA, gapB, gapC, gapD])

    print("\nThe row with gaps")
    let layout = TimelineGapLayout(timeline: gapTimeline, gaps: [gapC.id: 0.6])
    equal(layout.total, 0.6, "a gap adds its space to the row")
    check(close(layout.display(1.2), 1.8), "a time where a gap opens is the next section's first frame, after the gap")
    check(close(layout.display(1.2, end: true), 1.2), "and something ending there ends before it")
    check(close(layout.display(0.9), 0.9) && close(layout.display(2), 2.6), "times before a gap stay; times after it move along")
    check(close(layout.edited(1.5), 1.2) && layout.inGap(1.5), "anywhere in the gap is where the two sections meet")
    check(close(layout.edited(2.6), 2) && !layout.inGap(2.6), "after the gap, the row gives the edited time back")
    check([0, 0.3, 1.2, 2.2, 3].allSatisfy { close(layout.edited(layout.display($0)), $0) }, "edited time survives a trip along the row")
    equal(TimelineGapLayout(timeline: gapTimeline, gaps: [:]).total, 0, "with no gaps the row is the edit")

    var row = TimelineViewport(total: 3, gaps: layout)
    equal(row.total, 3.6, "the viewport spans the row, gaps and all")
    check(close(row.x(of: 1.2, across: 360), 180) && close(row.x(ofEnd: 1.2, across: 360), 120),
          "a section after a gap starts after it; the one before ends before it")
    check(close(row.width(from: 1, to: 1.4, across: 360), 100), "a block across a gap is as wide as its place on the row")
    check(close(row.time(atX: 150, across: 360), 1.2) && row.inGap(atX: 150, across: 360), "a click in the gap is the cut between the sections")
    check(close(row.time(atX: 300, across: 360), 2.4), "a click after the gap is the time under it")
    row.zoom(to: 4, keeping: 2)
    check(close(row.x(of: 2, across: 360), 260), "a zoom holds an edited time still where it is on the row")
    check(row.contains(2) && close(row.editedStart, row.editedStart) && row.editedEnd > row.editedStart,
          "and the edited times at its edges still read")
    var plain = TimelineViewport(total: 3)
    plain.zoom(to: 2, keeping: 1.5)
    check(close(plain.time(atX: plain.x(of: 1, across: 300), across: 300), 1) && close(plain.width(from: 1, to: 2, across: 300), 200),
          "with no gaps the viewport is the edit, as before")

    print("\nEverything else stays in place")
    var delete = gapTimeline; delete.segments.remove(at: 1)
    let deleted = SectionPlaces.gaps(after: gapTimeline, [:], new: delete)
    check(deleted.count == 1 && close(deleted[gapC.id], 0.6), "deleting a section leaves its space in front of the next")
    var deleteTwo = gapTimeline; deleteTwo.segments.removeSubrange(1...2)
    let deletedTwo = SectionPlaces.gaps(after: gapTimeline, [:], new: deleteTwo)
    check(deletedTwo.count == 1 && close(deletedTwo[gapD.id], 1.2), "deleting two leaves both their spaces")
    var deleteLast = gapTimeline; deleteLast.segments.removeLast()
    equal(SectionPlaces.gaps(after: gapTimeline, [:], new: deleteLast), [:], "deleting the last leaves nothing to hold apart")
    var trimEnd = gapTimeline; trimEnd.segments[0].end = 0.4
    equal(SectionPlaces.gaps(after: gapTimeline, [:], new: trimEnd).mapValues { ($0 * 1000).rounded() / 1000 }, [gapB.id: 0.2],
          "trimming an end leaves the space it gave up")
    var trimStart = gapTimeline; trimStart.segments[1].start = 0.8
    let startGaps = SectionPlaces.gaps(after: gapTimeline, [:], new: trimStart)
    check(close(startGaps[gapB.id], 0.2) && startGaps[gapC.id] == nil, "trimming a start keeps the section's end in place")
    var grow = trimEnd; grow.segments[0].end = 0.5
    let grown = SectionPlaces.gaps(after: trimEnd, [gapB.id: 0.2], new: grow)
    check(close(grown[gapB.id], 0.1), "a section that grows takes the space in front of the next one first")
    let spaced = ClipTimeline(segments: [TimelineSegment(start: 0, end: 0.4), TimelineSegment(start: 1, end: 1.6),
                                         TimelineSegment(start: 2, end: 2.5)])
    var pushed = spaced; pushed.segments[0].end = 0.9
    let pushes = SectionPlaces.gaps(after: spaced, [spaced.segments[1].id: 0.2, spaced.segments[2].id: 0.5], new: pushed)
    check(pushes[spaced.segments[1].id] == nil && close(pushes[spaced.segments[2].id], 0.2),
          "one that grows past the space pushes the next only as far as it must, which uses up space after it")
    check(close(SectionPlaces.gaps(after: gapTimeline, [:], new: gapTimeline, pinned: [gapD.id: 2.5])[gapD.id], 0.7),
          "a section placed by hand gets the space in front of it")

    print("\nThe editor")
    var gapItem = VideoItem(url: landscape)
    gapItem.info = info; gapItem.crop = info.fullFrame
    gapItem.segments = gapTimeline.segments
    let editor = AppModel(recoveryURL: nil)
    editor.restore(VideoProject(clips: [ProjectClip(gapItem)], settings: ExportSettings(), selection: gapItem.id))
    func gaps() -> [UUID: Double] { editor.items[0].gaps }
    editor.clickSegment(gapB.id, at: 0.7)
    editor.deleteSegment()
    equal(editor.items[0].timeline.segments.map(\.id), [gapA.id, gapC.id, gapD.id], "Delete removes the section")
    check(close(gaps()[gapC.id], 0.6), "and leaves its space, so nothing after it moves")
    check(close(editor.items[0].editedDuration, 2.4), "playback and exports join the sections: the edit is shorter")
    check(editor.statusMessage?.contains("Close Gaps") == true, "the status line says how to join them", editor.statusMessage ?? "")
    equal(editor.undoTitle, "Undo Delete Section", "one undo step, named as before")
    editor.undoEdit()
    check(gaps().isEmpty && editor.items[0].timeline.segments.count == 4, "undo brings the section back and the space with it")
    editor.redoEdit()
    check(close(gaps()[gapC.id], 0.6), "redo leaves the space again")
    editor.syncViewport()
    check(close(editor.viewport.total, 3), "the row stays as long as before, so nothing on screen jumps")

    editor.clickSegment(gapC.id, at: 0.7)
    editor.deleteSegment()
    check(close(gaps()[gapD.id], 1.2) && gaps()[gapC.id] == nil, "deleting the next one too adds its space to the gap")
    editor.undoEdit()

    editor.shiftSegment(gapC.id, by: -0.25)
    check(close(gaps()[gapC.id], 0.35) && close(gaps()[gapD.id], 0.25), "a section slides into the space in front of it; the next stays")
    equal(editor.undoTitle, "Undo Move Section", "as a move")
    editor.shiftSegment(gapC.id, by: -5)
    check(gaps()[gapC.id] == nil && close(gaps()[gapD.id], 0.6), "it stops against the section before it")
    editor.shiftSegment(gapC.id, by: 5)
    check(close(gaps()[gapC.id], 0.6) && gaps()[gapD.id] == nil, "and against the one after it")

    editor.closeGap(before: gapC.id)
    check(gaps().isEmpty, "Close Gap joins the sections either side of one gap")
    equal(editor.undoTitle, "Undo Close Gap", "named for it")
    editor.undoEdit()
    editor.toggleTrackLocked(.video)
    editor.closeGaps()
    check(!gaps().isEmpty && editor.statusMessage?.contains("locked") == true, "a locked Video row keeps its gaps")
    editor.toggleTrackLocked(.video)
    editor.closeGaps()
    check(gaps().isEmpty, "Close Gaps joins them all")
    equal(editor.undoTitle, "Undo Close Gaps", "as one step")
    check(close(editor.items[0].editedDuration, 2.4), "and the edit is the same as with them open")
    editor.undoEdit()

    let trimmed = editor.items[0].timeline.segments[0]
    editor.trimSegment(trimmed.id, end: 0.4)
    check(close(gaps()[gapC.id], 0.8), "trimming a section's end leaves its space in front of the next")
    editor.undoEdit()
    editor.trimSegment(gapA.id, end: 1.2)
    check(close(editor.items[0].timeline.segments[0].end, 1.2) && gaps()[gapC.id] == nil,
          "a trim can bring back the deleted footage, filling the space")
    editor.undoEdit()

    editor.setSegmentSpeed(gapD.id, speed: 2)
    check(close(gaps()[gapC.id], 0.6), "a speed change keeps the other sections in place")
    editor.undoEdit()

    editor.moveSegment(gapD.id, to: 0)
    equal(editor.items[0].timeline.segments.map(\.id), [gapD.id, gapA.id, gapC.id], "dragging a section earlier reorders it")
    check(gaps()[gapD.id] == nil, "and it takes the place of the section it goes in front of")
    editor.undoEdit()
    editor.moveSegment(gapA.id, to: 1, place: 1.5)
    equal(editor.items[0].timeline.segments.map(\.id), [gapC.id, gapA.id, gapD.id], "dropped into far space, it goes there in the order")
    check(close(gaps()[gapC.id], 1.2) && gaps()[gapA.id] == nil,
          "the section it passes keeps its place, and it follows on where it fits")
    editor.undoEdit()

    editor.clickSegment(gapC.id, at: 0.7)
    editor.deleteSegment(closeGap: true)
    check(gaps()[gapD.id].map { close($0, 0.6) } == true, "⇧⌘⌫ closes the deleted section's own space, keeping the gap before it")
    editor.undoEdit()

    print("\nSaved with the project")
    let gapFile = scratch.appendingPathComponent("gaps.yamvideo")
    try editor.writeProject(editor.project, to: gapFile)
    let saved = try VideoProject.decodeMigrating(from: Data(contentsOf: gapFile))
    equal(saved.version, VideoProject.currentVersion, "a project with gaps is saved as the current version (21 or later)")
    check(saved.clips[0].gaps?.count == 1 && saved.clips[0].gaps?.first?.section == gapC.id && close(saved.clips[0].gaps?.first?.length, 0.6),
          "the gaps are saved, in section order")
    editor.openProject(at: gapFile)
    check(close(editor.items[0].gaps[gapC.id], 0.6), "and come back when it opens")
    var older = saved
    older.version = 20
    check((try? older.validate()) == nil, "an older version with gaps is refused")
    var stray = saved
    stray.clips[0].gaps = [SectionGap(section: UUID(), length: 1)]
    check((try? stray.validate()) == nil, "a gap in front of no section is refused")
    var negative = saved
    negative.clips[0].gaps = [SectionGap(section: gapC.id, length: -1)]
    check((try? negative.validate()) == nil, "so is a negative gap")
    check(ProjectClip.withoutGaps(editor.items[0]).gaps == nil, "the player and exports see the recording without them")

    print("\nThe reducer")
    let base = editor.project
    let rippled = try ProjectReducer.apply([.deleteSection(clip: gapItem.id, section: gapC.id)], to: base).project
    check(rippled.clips[0].gaps?.count == 1 && rippled.clips[0].gaps?.first?.section == gapD.id && close(rippled.clips[0].gaps?.first?.length, 0.6),
          "a section deleted with a gap in front gives that space to the next")
    check(throwsEditError { try ProjectReducer.apply([.setGaps(clip: gapItem.id, gaps: [SectionGap(section: UUID(), length: 1)])], to: base) },
          "setGaps refuses a section that is not there")
    check(throwsEditError { try ProjectReducer.apply([.setGaps(clip: gapItem.id, gaps: [SectionGap(section: gapA.id, length: .infinity)])], to: base) },
          "and a length that is not a number of seconds")
    let zeroed = try ProjectReducer.apply([.setGaps(clip: gapItem.id, gaps: [SectionGap(section: gapA.id, length: 0)])], to: base).project
    check(zeroed.clips[0].gaps == nil, "a gap of 0 is no gap")

    print("\nAgents")
    let address0 = address(editor)
    let state = agentResult(await agentCall(editor, ["method": "state"]))
    let sections = ((state["clips"] as? [[String: Any]])?.first?["sections"] as? [[String: Any]]) ?? []
    check(sections.count == 3 && close(sections[1]["gapBefore"] as? Double, 0.6) && sections[0]["gapBefore"] == nil,
          "state gives each section's gapBefore, and none where there is no space")
    var setGap = address0
    setGap["method"] = "apply"; setGap["requestID"] = "gap-1"; setGap["client"] = "Codex"
    setGap["commands"] = [["type": "setGap", "clipID": gapItem.id.uuidString, "sectionID": gapD.id.uuidString, "duration": 1.5]]
    check(agentResult(await agentCall(editor, setGap)).isEmpty == false && close(gaps()[gapD.id], 1.5) && close(gaps()[gapC.id], 0.6),
          "an agent leaves space with setGap")
    var closeOne = address(editor)
    closeOne["method"] = "apply"; closeOne["requestID"] = "gap-2"; closeOne["client"] = "Codex"
    closeOne["commands"] = [["type": "closeGaps", "clipID": gapItem.id.uuidString, "sectionID": gapD.id.uuidString]]
    _ = await agentCall(editor, closeOne)
    check(gaps()[gapD.id] == nil && close(gaps()[gapC.id], 0.6), "closeGaps with a section closes only its gap")
    var missing = address(editor)
    missing["method"] = "apply"; missing["requestID"] = "gap-3"; missing["client"] = "Codex"
    missing["commands"] = [["type": "closeGaps", "clipID": gapItem.id.uuidString, "sectionID": gapD.id.uuidString]]
    equal(agentError(await agentCall(editor, missing)), "not_found", "and says when there is no gap there")
    var closeAll = address(editor)
    closeAll["method"] = "apply"; closeAll["requestID"] = "gap-4"; closeAll["client"] = "Codex"
    closeAll["commands"] = [["type": "closeGaps", "clipID": gapItem.id.uuidString]]
    _ = await agentCall(editor, closeAll)
    check(gaps().isEmpty, "closeGaps with only the recording joins every section")
    let catalog = AgentCatalog.current.commands.map(\.type)
    check(catalog.contains("setGap") && catalog.contains("closeGaps"), "the catalog lists setGap and closeGaps")
    let manual = (try? String(contentsOfFile: repository + "/Resources/AgentsManual.md", encoding: .utf8)) ?? ""
    check(manual.contains("### 4.18 Gaps on the timeline") && manual.contains("gapBefore"), "the Agents Manual explains gaps")
}

private func throwsEditError(_ body: () throws -> Any) -> Bool {
    do { _ = try body(); return false } catch { return error is EditError }
}
