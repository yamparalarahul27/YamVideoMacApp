// Checks for editing. Run with ./test.sh editing
import AppKit
import AVFoundation
import Foundation

@MainActor func editingTests() async throws {
    // MARK: - Non-destructive editing and project round trips

    print("\nTimeline ruler")

    // The ladder must stay sorted, or `interval` cannot pick the finest fit by scanning it.
    let ladder = TimelineRuler.intervals(fps: 30)
    check(zip(ladder, ladder.dropFirst()).allSatisfy { $0 < $1 }, "the interval ladder is sorted finest first")

    // The defect this replaces: a fixed tick count spreads labels further apart the further
    // you zoom, so most of the timeline carried no time reference. Across four decades of
    // magnification every chosen interval must stay legible and must come from the ladder.
    let coarsest = ladder[ladder.count - 1]
    let scales = stride(from: -1.0, through: 3.0, by: 0.1).map { pow(10, $0) }
    var spacings: [Double] = []
    var offLadder: Double?
    for pixelsPerSecond in scales {
        let interval = TimelineRuler.interval(pixelsPerSecond: pixelsPerSecond, fps: 30)
        if !ladder.contains(interval) { offLadder = pixelsPerSecond }
        // The coarsest interval is a floor: past it there is nothing wider to choose.
        if interval != coarsest { spacings.append(interval * pixelsPerSecond) }
    }
    check(offLadder == nil, "every chosen interval comes from the ladder",
          offLadder.map { "off-ladder at \(Int($0))px/s" } ?? "\(scales.count) scales")
    check(spacings.allSatisfy { $0 >= TimelineRuler.minimumSpacing }, "labels never fall closer than the minimum",
          "tightest \(spacings.min().map { String(format: "%.1f", $0) } ?? "none")")
    check(spacings.allSatisfy { $0 < 210 }, "and never spread further than the ladder's largest step allows",
          "widest \(spacings.max().map { String(format: "%.1f", $0) } ?? "none")")

    // Zooming in must never coarsen the ruler.
    var previous = coarsest
    var coarsened: Double?
    for pixelsPerSecond in scales {
        let interval = TimelineRuler.interval(pixelsPerSecond: pixelsPerSecond, fps: 30)
        if interval > previous { coarsened = pixelsPerSecond }
        previous = interval
    }
    check(coarsened == nil, "the ruler only ever gets finer as it is zoomed in",
          coarsened.map { "coarsened at \(Int($0))px/s" } ?? "monotonic")

    equal(TimelineRuler.interval(pixelsPerSecond: 0, fps: 30), coarsest, "a degenerate scale falls back to the coarsest interval")
    equal(TimelineRuler.interval(pixelsPerSecond: .nan, fps: 30), coarsest, "and so does a non-finite one")

    // Minor ticks are dropped rather than drawn as a smear.
    check(TimelineRuler.minorInterval(1, pixelsPerSecond: 100) != nil, "minor ticks appear when there is room")
    check(TimelineRuler.minorInterval(1, pixelsPerSecond: 20) == nil, "and are dropped when there is not")

    equal(TimelineRuler.ticks(every: 5, in: 0...20), [0, 5, 10, 15, 20], "ticks include both ends")
    equal(TimelineRuler.ticks(every: 5, in: 6...19), [10, 15], "and only whole multiples inside the range")
    check(TimelineRuler.ticks(every: 0, in: 0...10).isEmpty, "a zero step yields no ticks")
    check(TimelineRuler.ticks(every: 0.0001, in: 0...100).isEmpty, "an absurd tick count is refused rather than drawn")

    // Labels carry frames only when ticks are closer together than a second.
    equal(TimelineRuler.label(75, interval: 5, fps: 30), "1:15", "a coarse label drops the fraction")
    equal(TimelineRuler.label(75.5, interval: 0.2, fps: 30), "1:15.15", "a fine label counts frames instead")
    equal(TimelineRuler.label(0, interval: 1, fps: 30), "0:00", "zero formats cleanly")
    equal(TimelineRuler.label(-4, interval: 1, fps: 30), "0:00", "and so does a negative time")
    equal(TimelineRuler.label(1, interval: 0.5, fps: 0), "0:01.00", "a missing frame rate falls back instead of dividing by zero")


    print("\nTimeline viewport")

    // The defect this replaces: zoom used to scale a canvas inside a scroll view, so the
    // moment you were looking at slid away as you magnified. Whatever the anchor, it must
    // stay at the same point across the width.
    let anchorWidth = 900.0
    var anchorDrift = 0.0
    for anchorFraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
        for factor in [1.5, 4.0, 0.5, 1 / 3.0] {
            var port = TimelineViewport(total: 600)
            port.zoom(to: 6, keeping: 300)          // start part-way in, away from either end
            let anchor = port.start + port.visible * anchorFraction
            let before = port.x(of: anchor, across: anchorWidth)
            port.zoom(by: factor, keeping: anchor)
            anchorDrift = max(anchorDrift, abs(port.x(of: anchor, across: anchorWidth) - before))
        }
    }
    check(anchorDrift < 0.001, "zooming holds the anchored moment still",
          String(format: "worst drift %.4fpt", anchorDrift))

    // x and time must be exact inverses, or scrubbing lands somewhere other than the click.
    var port = TimelineViewport(total: 600)
    port.zoom(to: 12, keeping: 200)
    var roundTrip = 0.0
    for x in [0.0, 1.0, 450.0, 899.0, 900.0] {
        roundTrip = max(roundTrip, abs(port.x(of: port.time(atX: x, across: anchorWidth), across: anchorWidth) - x))
    }
    check(roundTrip < 0.000001, "a point converts to a time and back unchanged",
          String(format: "worst %.8f", roundTrip))

    // The window may never leave the recording, however hard it is pushed.
    var edge = TimelineViewport(total: 600)
    edge.zoom(to: 10, keeping: 0)
    edge.pan(by: -10_000)
    equal(edge.start, 0, "panning stops at the beginning")
    edge.pan(by: 10_000)
    check(abs(edge.end - 600) < 0.000001, "and at the end", "\(edge.end)")
    check(edge.start >= 0 && edge.end <= 600.000001, "the window stays inside the recording")

    // Zoom limits.
    var limit = TimelineViewport(total: 600)
    limit.zoom(to: 1000, keeping: 300)
    equal(limit.scale, TimelineViewport.maximumScale, "zoom stops at the finest scale")
    limit.zoom(to: 0.01, keeping: 300)
    equal(limit.scale, 1, "and zooming out stops at the whole recording")
    equal(limit.visible, 600, "which is the whole timeline across the width")
    equal(limit.start, 0, "anchored back at the beginning")

    var degenerate = TimelineViewport(total: 600)
    degenerate.zoom(to: .nan, keeping: .nan)
    check(degenerate.visible.isFinite && degenerate.start.isFinite, "a non-finite zoom cannot corrupt the viewport")
    degenerate.pan(by: .infinity)
    check(degenerate.start.isFinite && degenerate.start >= 0, "nor can a non-finite pan")

    // Following the playhead: only when it leaves the margin, and never past the ends.
    var follow = TimelineViewport(total: 600)
    follow.zoom(to: 10, keeping: 300)   // 60s visible around 300
    let settled = follow.start
    follow.reveal(follow.start + follow.visible / 2)
    equal(follow.start, settled, "a playhead in clear view does not move the timeline")
    follow.reveal(follow.end + 5)
    check(follow.contains(follow.end - follow.visible * 0.12 + 0.001), "a playhead that runs off the end pulls the view along")
    check(follow.start >= 0 && follow.end <= 600.000001, "and following still cannot leave the recording")
    follow.reveal(0)
    equal(follow.start, 0, "revealing the very start sits flush against it")

    // An edit that changes the timeline's length must not strand the window past the end.
    var resized = TimelineViewport(total: 600)
    resized.zoom(to: 20, keeping: 590)
    resized.resize(total: 100)
    check(resized.end <= 100.000001, "shortening the timeline pulls the window back inside", "\(resized.end)")
    check(resized.visible <= 100.000001, "and never shows more than there is")
    resized.resize(total: 0)
    check(resized.visible > 0 && resized.scale >= 1, "an empty timeline still leaves a usable viewport")

    // Culling: only what is on screen is worth building.
    var culling = TimelineViewport(total: 600)
    culling.zoom(to: 60, keeping: 300)
    check(culling.intersects(culling.start - 1, culling.start + 1), "a section straddling the left edge is drawn")
    check(culling.intersects(culling.end - 1, culling.end + 1), "and one straddling the right edge")
    check(!culling.intersects(0, culling.start - 0.001), "but one entirely before the window is not")
    check(!culling.intersects(culling.end + 0.001, 600), "nor one entirely after it")
    check(culling.visible < 600 / 59, "sixty times is genuinely sixty times")

    // The ruler ladder is frame-derived below half a second, so fine labels land on whole
    // frames rather than rounding two ticks onto the same one.
    for fps in [24.0, 25.0, 30.0, 60.0] {
        let fine = TimelineRuler.intervals(fps: fps).filter { $0 < 0.5 }
        let whole = fine.allSatisfy { abs(($0 * fps).rounded() - $0 * fps) < 0.000001 }
        check(whole, "every sub-second rung is a whole number of frames at \(Int(fps))fps")
    }

    print("\nTimeline snapping")

    // Sections of 4s, 3s (6s of source at 2×) and 5s: boundaries at 4 and 7, 12 in all.
    // One zoom spans 8–10, and the playhead is parked at 5.5.
    let snapTimeline = ClipTimeline(segments: [
        TimelineSegment(start: 0, end: 4),
        TimelineSegment(start: 10, end: 16, speed: 2),
        TimelineSegment(start: 20, end: 25),
    ])
    let snapZoom = ZoomShot(start: 8, hold: 1, target: .zero)
    let snaps = TimelineSnapping(timeline: snapTimeline, zooms: [snapZoom], playhead: 5.5)
    let snapPPS = 100.0     // the 8pt reach is 0.08s
    func landing(_ time: Double, _ snapping: TimelineSnapping = snaps, pps: Double = snapPPS,
                 within range: ClosedRange<Double>? = nil) -> TimelineSnapping.Target? {
        snapping.target(for: time, pixelsPerSecond: pps, within: range)
    }

    equal(landing(4.07), .init(time: 4, kind: .sectionBoundary), "a time just inside the reach snaps to the section boundary")
    check(landing(4.09) == nil, "and one just outside it does not")
    equal(landing(5.44)?.time, 5.5, "the playhead is a target")
    equal(landing(9.95), .init(time: 10, kind: .zoomEdge), "so are zoom edges")
    equal(landing(0.03), .init(time: 0, kind: .timelineEnd), "and both ends of the timeline")
    equal(landing(11.99)?.time, 12, "including the end, which is the edited length rather than the source's")
    check(landing(2) == nil, "open timeline away from everything stays where it is")

    // The reach is fixed on screen, so it shrinks in seconds as the view zooms in.
    check(TimelineSnapping.reach(pixelsPerSecond: 800) < TimelineSnapping.reach(pixelsPerSecond: 100),
          "the reach in seconds shrinks as pixels per second rise")
    equal(TimelineSnapping.reach(pixelsPerSecond: 100), 0.08, "8 points at 100 points a second is 0.08s")
    check(landing(4.02, pps: 100) != nil && landing(4.02, pps: 800) == nil,
          "so a time that snaps across the whole view is placed freely zoomed in")
    check(landing(4, pps: 0) == nil && landing(4, pps: .nan) == nil && landing(.nan) == nil,
          "a degenerate scale or time never snaps")

    // Nearest wins; a draw goes to the playhead.
    let crowded = TimelineSnapping(timeline: snapTimeline, zooms: [], playhead: 7.06)
    equal(landing(7.02, crowded), .init(time: 7, kind: .sectionBoundary), "the nearer of two targets in reach wins")
    equal(landing(7.04, crowded), .init(time: 7.06, kind: .playhead), "whichever it is")
    equal(landing(7.03, crowded), .init(time: 7.06, kind: .playhead), "and an even draw goes to the playhead")
    equal(landing(7.0302, crowded)?.kind, .playhead, "as does a gap too small to see")

    // What a gesture leaves out.
    let scrubbing = TimelineSnapping(timeline: snapTimeline, zooms: [snapZoom], playhead: nil)
    check(!scrubbing.targets.contains { $0.kind == .playhead }, "dragging the playhead does not snap it to itself")
    let movingZoom = TimelineSnapping(timeline: snapTimeline, zooms: [snapZoom], playhead: 5.5, excluding: snapZoom.id)
    check(!movingZoom.targets.contains { $0.kind == .zoomEdge }, "a zoom being dragged does not snap to its own edges")
    check(landing(5.45, within: 4...7) != nil, "a trim snaps to targets over its own section")
    equal(landing(4.05, within: 4...7)?.time, 4, "including its own edges, which leave it as it was")
    check(landing(7.05, within: 0...4) == nil, "but not to those beyond it")

    // A zoom moved whole snaps by whichever edge is nearer a target, keeping its length.
    let leading = movingZoom.snapSpan(start: 6.96, duration: 2, pixelsPerSecond: snapPPS)
    check(leading.start == 7 && leading.target?.time == 7, "a moved zoom's start lines up with a boundary", "\(leading)")
    let trailing = movingZoom.snapSpan(start: 9.95, duration: 2, pixelsPerSecond: snapPPS)
    check(trailing.start == 10 && trailing.target?.time == 12, "and its end lines up with the end of the timeline", "\(trailing)")
    let both = movingZoom.snapSpan(start: 3.94, duration: 3.1, pixelsPerSecond: snapPPS)
    check(abs(both.start - 3.9) < 0.000001 && both.target?.time == 7,
          "when both edges are in reach the nearer one wins", "\(both)")
    let free = movingZoom.snapSpan(start: 1, duration: 2, pixelsPerSecond: snapPPS)
    check(free.start == 1 && free.target == nil, "a zoom nowhere near a target moves freely")

    // ⌥ suspends snapping for the drag, and the switch itself is remembered.
    let snappingModel = AppModel(recoveryURL: nil)
    let savedSnapping = snappingModel.timelineSnapping
    snappingModel.timelineSnapping = true
    check(snappingModel.dragSnaps(modifiers: []), "a drag snaps while snapping is on")
    check(!snappingModel.dragSnaps(modifiers: [.option]), "holding ⌥ suspends it")
    check(snappingModel.dragSnaps(modifiers: [.shift, .command]), "other modifiers do not")
    snappingModel.timelineSnapping = false
    check(!snappingModel.dragSnaps(modifiers: []), "switching snapping off stops every drag snapping")
    equal(UserDefaults.standard.object(forKey: AppModel.snappingKey) as? Bool, false, "and the choice is remembered")
    equal(AppModel(recoveryURL: nil).timelineSnapping, false, "by the next window too")
    snappingModel.timelineSnapping = savedSnapping

    print("\nTimeline and projects")
    let wholeTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 10)])
    var splitTimeline = wholeTimeline
    check(splitTimeline.split(at: 0, fps: 30) == nil, "cannot split at the start boundary")
    check(splitTimeline.split(at: 10, fps: 30) == nil, "cannot split at the end boundary")
    let rightID = splitTimeline.split(at: 4.01, fps: 30)
    check(rightID != nil, "splits inside a section")
    equal(splitTimeline.segments[0].end, 4, "split snaps to a source frame")
    equal(splitTimeline.duration, 10, "splitting preserves duration")
    equal(splitTimeline.location(at: 4)?.index, 1, "cut boundary belongs to the next section")
    let reordered = ClipTimeline(segments: [splitTimeline.segments[1], splitTimeline.segments[0]])
    equal(reordered.location(at: 0)?.source, 4, "reordered timeline starts at the moved source range")
    equal(reordered.location(at: 7)?.source, 1, "source lookup follows reordered sections")
    let anchored = ZoomShot(start: 5, hold: 1, level: 2, target: CGPoint(x: 200, y: 100))
    equal(reordered.remap([anchored], from: wholeTimeline).first?.start, 1, "zoom follows retained footage when reordered")
    let removedTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 4)])
    check(removedTimeline.remap([anchored], from: wholeTimeline).isEmpty, "deleting a zoom's source removes that zoom")

    var projectItem = VideoItem(url: landscape)
    projectItem.info = info; projectItem.crop = info.fullFrame
    projectItem.segments = [TimelineSegment(start: 1.5, end: 3), TimelineSegment(start: 0, end: 1)]
    projectItem.zoomShots = [ZoomShot(start: 0.2, hold: 0.5, level: 2, target: CGPoint(x: 640, y: 360))]
    roundTripProject = VideoProject(clips: [ProjectClip(projectItem)], settings: ExportSettings(), selection: projectItem.id)
    let decodedProject = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(roundTripProject))
    try decodedProject.validate()
    equal(decodedProject, roundTripProject, "project round trip retains cuts, zooms, geometry and settings")
    var invalidProject = decodedProject
    invalidProject.clips[0].segments?[0].end = 999
    check((try? invalidProject.validate()) == nil, "rejects out-of-bounds source ranges")
    invalidProject = decodedProject
    invalidProject.version = 200
    check((try? invalidProject.validate()) == nil, "rejects unsupported project versions")

    let editor = AppModel(recoveryURL: nil)
    editor.restore(roundTripProject)
    editor.setPreviewFraction(0.25)
    let originalSections = editor.selectedItem!.timeline.segments
    editor.splitAtPlayhead()
    equal(editor.selectedItem!.timeline.segments.count, 3, "editor splits a section")
    editor.undoEdit()
    equal(editor.selectedItem!.timeline.segments, originalSections, "undo restores the exact source ranges")
    editor.redoEdit()
    equal(editor.selectedItem!.timeline.segments.count, 3, "redo restores the split")
    editor.deleteSegment()
    equal(editor.selectedItem!.timeline.segments.count, 2, "deleting a section closes its gap")
    editor.undoEdit()
    equal(editor.selectedItem!.timeline.segments.count, 3, "undo restores the deleted section")
    let namedProject = scratch.appendingPathComponent("round-trip.yamvideo")
    try editor.writeProject(roundTripProject, to: namedProject)
    editor.openProject(at: namedProject)
    equal(editor.project.clips, roundTripProject.clips, "opening a saved project restores edit data")

    // MARK: - Project identity and the version 3 schema

    print("\nProject identity")
    var legacy = roundTripProject
    legacy.version = 2; legacy.projectID = nil
    let legacyData = try JSONEncoder().encode(legacy)
    let migrated = try VideoProject.decodeMigrating(from: legacyData)
    equal(migrated.version, VideoProject.currentVersion, "a version 2 file is upgraded on open")
    check(migrated.projectID != nil, "an upgraded file gains an identity")
    equal(try VideoProject.decodeMigrating(from: legacyData).projectID, migrated.projectID,
          "the same legacy bytes always get the same identity")
    var otherLegacy = legacy; otherLegacy.settings.quality = 10
    check(try VideoProject.decodeMigrating(from: JSONEncoder().encode(otherLegacy)).projectID != migrated.projectID,
          "different legacy files get different identities")
    equal(migrated.clips, legacy.clips, "upgrading changes no edit data")

    var newerFields = legacy; newerFields.clips[0].subtitles = srt
    check((try? newerFields.validate()) == nil, "an older version carrying subtitles is rejected")
    newerFields = legacy; newerFields.projectID = UUID()
    check((try? newerFields.validate()) == nil, "an older version carrying an identity is rejected")
    var anonymous = roundTripProject; anonymous.projectID = nil
    check((try? anonymous.validate()) == nil, "a version 3 file without an identity is rejected")
    var future = roundTripProject; future.version = VideoProject.currentVersion + 1
    do {
        try future.validate()
        check(false, "a newer version is rejected")
    } catch {
        check(error.localizedDescription.contains("newer version"), "a newer version is rejected with a clear reason",
              error.localizedDescription)
    }

    let identityEditor = AppModel(recoveryURL: nil)
    let legacyFile = scratch.appendingPathComponent("legacy.yamvideo")
    try legacyData.write(to: legacyFile)
    identityEditor.openProject(at: legacyFile)
    equal(identityEditor.projectID, migrated.projectID, "opening a legacy file adopts its derived identity")
    check(!identityEditor.hasUnsavedChanges, "upgrading on open is not an unsaved edit")
    identityEditor.saveProject()
    let resaved = try JSONDecoder().decode(VideoProject.self, from: Data(contentsOf: legacyFile))
    equal(resaved.version, VideoProject.currentVersion, "saving writes the current version")
    equal(resaved.projectID, migrated.projectID, "saving persists the identity")
    identityEditor.openProject(at: legacyFile)
    equal(identityEditor.projectID, migrated.projectID, "the identity survives save and reopen")

    // The subtitle file is project data now: undoable, saved, recovered.
    identityEditor.setSubtitles(srt, for: identityEditor.selectedItem!.id)
    equal(identityEditor.project.clips[0].subtitles, srt, "the chosen subtitle file is part of the project")
    check(identityEditor.hasUnsavedChanges, "choosing subtitles marks the project changed")
    identityEditor.undoEdit()
    equal(identityEditor.selectedItem!.subtitles, nil, "undo removes the subtitle choice")
    identityEditor.redoEdit()
    identityEditor.saveProject()
    identityEditor.openProject(at: legacyFile)
    equal(identityEditor.selectedItem!.subtitles, srt, "the subtitle choice survives save and reopen")

    // Save As forks the document; saving in place does not.
    let originalID = identityEditor.projectID
    let copyFile = scratch.appendingPathComponent("copy.yamvideo")
    identityEditor.save(to: copyFile, asCopy: true)
    check(identityEditor.projectID != originalID, "Save As gives the copy its own identity")
    equal(identityEditor.projectURL, copyFile, "Save As continues editing the copy")
    check(!identityEditor.hasUnsavedChanges, "the forked copy is saved")
    equal(try JSONDecoder().decode(VideoProject.self, from: Data(contentsOf: legacyFile)).projectID, originalID,
          "the original file keeps its identity")
    let copyID = identityEditor.projectID
    identityEditor.saveProject()
    equal(identityEditor.projectID, copyID, "saving in place keeps the identity")
    identityEditor.newProject()
    check(identityEditor.projectID != copyID, "a new project has its own identity")
    identityEditor.undoEdit()
    equal(identityEditor.projectID, copyID, "undoing New Project restores the previous identity")

    let identityRecovery = scratch.appendingPathComponent("identity-recovery.yamvideo")
    let recoveringIdentity = AppModel(recoveryURL: identityRecovery)
    recoveringIdentity.restore(identityEditor.project)
    recoveringIdentity.flushRecovery()
    let resumedIdentity = AppModel(recoveryURL: identityRecovery)
    equal(resumedIdentity.projectID, identityEditor.projectID, "recovery keeps the project identity")
    equal(resumedIdentity.selectedItem?.subtitles, srt, "recovery keeps the subtitle choice")

    let legacyRecovery = scratch.appendingPathComponent("legacy-recovery.yamvideo")
    try JSONEncoder().encode(SessionRecovery(project: legacy, fileURL: legacyFile, savedProject: legacy))
        .write(to: legacyRecovery)
    let legacyResumed = AppModel(recoveryURL: legacyRecovery)
    check(legacyResumed.savedProject?.projectID == legacyResumed.projectID,
          "a legacy recovery file upgrades its saved copy to the same identity")
    check(!legacyResumed.hasUnsavedChanges, "an upgraded recovery file is not mistaken for unsaved edits")

    // MARK: - Shared edit commands

    print("\nShared edit commands")
    let commandClip = roundTripProject.clips[0]
    let sectionA = commandClip.timeline.segments[0], sectionB = commandClip.timeline.segments[1]
    let anchoredZoom = commandClip.zoomShots[0]

    // The reducer: pure, strict, all or nothing.
    equal(reducerRefusal([
        .setSectionSpeed(clip: commandClip.id, section: sectionA.id, speed: 2),
        .setCrop(clip: commandClip.id, rect: CGRect(x: 0, y: 0, width: 640, height: 360)),
        .setSectionSpeed(clip: commandClip.id, section: sectionB.id, speed: 9),
    ]), .invalidCommand, "a batch with one invalid command is refused as a whole")
    equal(reducerRefusal([.trimSection(clip: commandClip.id, section: UUID(), start: 0, end: nil)]), .notFound,
          "an unknown section is reported as not found")
    equal(reducerRefusal([.trimSection(clip: commandClip.id, section: sectionA.id, start: nil, end: 99)]), .invalidCommand,
          "a trim past the source is refused, not clamped")
    equal(reducerRefusal([.trimSection(clip: commandClip.id, section: sectionB.id, start: nil, end: 1.6)]), .invalidCommand,
          "a trim into a neighbouring section's footage is refused")
    let snapped = try ProjectReducer.apply([.trimSection(clip: commandClip.id, section: sectionA.id, start: 1.517, end: nil)],
                                           to: roundTripProject)
    check(abs(snapped.project.clips[0].segments![0].start - 46.0 / 30) < 0.000001, "trim bounds snap to a source frame")
    let splitOutcome = try ProjectReducer.apply([.splitSection(clip: commandClip.id, at: 0.5)], to: roundTripProject)
    check(splitOutcome.createdIDs.count == 1 && splitOutcome.project.clips[0].segments!.count == 3,
          "a split reports the new section's ID")
    equal(reducerRefusal([.splitSection(clip: commandClip.id, at: 0)]), .invalidCommand, "splitting on a boundary is refused")
    let cutZoom = try ProjectReducer.apply([.deleteSection(clip: commandClip.id, section: sectionA.id)], to: roundTripProject)
    equal(cutZoom.removedZooms, [anchoredZoom.id], "deleting a zoom's footage reports the zoom it removed")
    var edgeZoom = anchoredZoom; edgeZoom.target = CGPoint(x: 1280, y: 720)
    equal(reducerRefusal([.updateZoom(clip: commandClip.id, zoom: edgeZoom)]), nil, "a zoom may aim at the frame's far edge")
    equal(reducerRefusal([.addZoom(clip: commandClip.id, zoom: ZoomShot(start: 0.3, hold: 0.5, target: .zero))]),
          .invalidCommand, "an overlapping zoom is refused")
    equal(reducerRefusal([.setMovieOrder([])]), .invalidCommand, "a movie order must list every recording")
    var badSettings = ExportSettings(); badSettings.quality = 150
    equal(reducerRefusal([.setExportSettings(badSettings)]), .invalidCommand, "out-of-range export settings are refused")
    equal(reducerRefusal([.setAspect(clip: commandClip.id, preset: "7:3")]), .invalidCommand, "an unknown aspect is refused")

    // Revisions: one per transaction, none for a no-op.
    let revisions = freshEditor()
    let clipID = revisions.items[0].id
    let firstRevision = revisions.revision
    revisions.perform([.setSectionSpeed(clip: clipID, section: sectionA.id, speed: 1.5)])
    equal(revisions.revision, firstRevision + 1, "a transaction advances the revision once")
    let historyDepth = revisions.undoEntries.count
    revisions.perform([.setSectionSpeed(clip: clipID, section: sectionA.id, speed: 1.5)])
    check(revisions.revision == firstRevision + 1 && revisions.undoEntries.count == historyDepth,
          "a no-op changes neither the revision nor history")

    // Two agents planning against the same revision: one wins, one is told to reread.
    let atRevision = revisions.revision
    let wide = CGRect(x: 0, y: 0, width: 640, height: 360)
    let codexCrop = revisions.perform([.setCrop(clip: clipID, rect: wide)], origin: .agent("Codex"), expectedRevision: atRevision)
    let claudeCrop = revisions.perform([.setCrop(clip: clipID, rect: CGRect(x: 100, y: 100, width: 320, height: 180))],
                                       origin: .agent("Claude"), expectedRevision: atRevision)
    check(receipt(codexCrop) != nil, "the first agent's edit at a revision commits")
    equal(refusal(claudeCrop), .revisionConflict, "the second agent's edit at the same revision conflicts")
    equal(revisions.items[0].crop, wide, "the conflicting edit did not overwrite the first")
    check(receipt(revisions.perform([.setAspect(clip: clipID, preset: "16:9")], origin: .agent("Claude"),
                                    expectedRevision: revisions.revision)) != nil, "after rereading, the second agent succeeds")

    // Dry run: the same validation and remap report, nothing committed or reserved.
    let dryEditor = freshEditor()
    let dryBefore = dryEditor.project, dryRevision = dryEditor.revision, dryHistory = dryEditor.undoEntries.count
    let dry = receipt(dryEditor.perform([.deleteSection(clip: clipID, section: sectionA.id)], origin: .agent("Codex"),
                                        expectedRevision: dryRevision, dryRun: true))
    check(dryEditor.project == dryBefore && dryEditor.revision == dryRevision && dryEditor.undoEntries.count == dryHistory,
          "a dry run commits nothing")
    let wet = receipt(dryEditor.perform([.deleteSection(clip: clipID, section: sectionA.id)], origin: .agent("Codex"),
                                        expectedRevision: dryRevision))
    check(dry?.removedZooms == [anchoredZoom.id] && wet?.removedZooms == dry?.removedZooms,
          "a dry run reports the same zoom losses as the real edit")

    // A drag is one gesture: live while held, one transaction when released.
    let dragging = freshEditor()
    let dragStart = dragging.revision, dragHistory = dragging.undoEntries.count
    let heldCrop = CGRect(x: 10, y: 10, width: 900, height: 500)
    dragging.updateCrop(CGRect(x: 0, y: 0, width: 1000, height: 600), live: true)
    dragging.updateCrop(heldCrop, live: true)
    equal(dragging.items[0].crop, heldCrop, "a drag is visible while it lasts")
    equal(dragging.revision, dragStart, "live drag updates commit nothing")
    equal(dragging.committedProject.clips[0].crop, commandClip.crop, "agents see the committed crop during a drag")
    dragging.editSession.gesture?.lastUpdate = Date().addingTimeInterval(-0.9)
    equal(refusal(dragging.perform([.setAspect(clip: clipID, preset: "1:1")], origin: .agent("Claude"),
                                   expectedRevision: dragging.revision)),
          .interactionInProgress, "an agent edit during a held drag is refused clearly")
    dragging.updateCrop(CGRect(x: 20, y: 20, width: 800, height: 400), live: true)
    dragging.updateCrop(.null, live: false)
    check(dragging.revision == dragStart + 1 && dragging.undoEntries.count == dragHistory + 1,
          "a drag held past 0.6 s is still one revision and one undo step")
    check(receipt(dragging.perform([.setAspect(clip: clipID, preset: "1:1")], origin: .agent("Claude"),
                                   expectedRevision: dragging.revision)) != nil,
          "after the drag ends, the agent's edit succeeds on rereading")
    dragging.undoEdit(); dragging.undoEdit()
    equal(dragging.items[0].crop, commandClip.crop, "undo restores the crop from before the whole drag")
    let cancelStart = dragging.revision, cancelHistory = dragging.undoEntries.count
    dragging.updateCrop(heldCrop, live: true)
    dragging.cancelGesture()
    check(dragging.revision == cancelStart && dragging.undoEntries.count == cancelHistory
              && dragging.items[0].crop == commandClip.crop, "a cancelled drag leaves no history or revision")
    dragging.updateCrop(heldCrop, live: true)
    dragging.editSession.gesture?.lastUpdate = .distantPast
    check(receipt(dragging.perform([.setAspect(clip: clipID, preset: "4:3")], origin: .agent("Claude"),
                                   expectedRevision: dragging.revision)) == nil,
          "an abandoned drag is committed first, so the agent's old revision no longer matches")
    equal(dragging.items[0].crop, heldCrop, "an abandoned drag is kept rather than lost")
    let gestureHistory = dragging.undoEntries.count
    dragging.setPreviewFraction(0.3)
    dragging.updateCrop(wide, live: true)
    dragging.splitAtPlayhead()
    equal(dragging.undoEntries.count, gestureHistory + 2, "a separate command closes an open drag as its own step")
    let sliderHistory = dragging.undoEntries.count
    var sliding = dragging.settings
    for quality in [40.0, 45, 50] { sliding.quality = quality; dragging.updateSettings(sliding, live: true) }
    dragging.endGesture()
    check(dragging.undoEntries.count == sliderHistory + 1 && dragging.settings.quality == 50,
          "a slider drag is one undo step with its final value")

    // Human and agent edits interleave in one history.
    let mixed = freshEditor()
    mixed.perform([.setCrop(clip: clipID, rect: wide)])
    let afterCrop = mixed.project.clips
    let blur = BlurRegion(rect: CGRect(x: 40, y: 40, width: 100, height: 60))
    let agentBlur = receipt(mixed.perform([.addBlurArea(clip: clipID, area: blur)], origin: .agent("Claude"),
                                          expectedRevision: mixed.revision))!
    let afterBlur = mixed.project.clips
    mixed.perform([.setAspect(clip: clipID, preset: "1:1")])
    equal(mixed.undoTitle, "Undo Crop Aspect", "the menu names the owner's own step plainly")
    mixed.undoEdit()
    equal(mixed.project.clips, afterBlur, "Cmd-Z restores the exact previous document")
    equal(mixed.undoTitle, "Undo Add Blur (Claude)", "the menu names an agent's step and who made it")
    check(receipt(mixed.undo(origin: .agent("Claude"), expectedTransaction: agentBlur.transactionID,
                             expectedRevision: mixed.revision)) != nil, "an agent can undo its own step when it is on top")
    equal(mixed.project.clips, afterCrop, "the agent's undo restores the document before its edit")
    mixed.redoEdit()
    equal(mixed.project.clips, afterBlur, "redo restores the agent's edit")
    mixed.perform([.setAspect(clip: clipID, preset: "4:3")])
    check(mixed.redoEntries.isEmpty, "a new edit clears redo")
    equal(refusal(mixed.undo(origin: .agent("Claude"), expectedTransaction: agentBlur.transactionID,
                             expectedRevision: mixed.revision)),
          .historyConflict, "an agent cannot undo across somebody else's later edit")
    let ownStep = receipt(mixed.perform([.setAspect(clip: clipID, preset: "1:1")], origin: .agent("Codex"),
                                        expectedRevision: mixed.revision))!
    mixed.setPreviewFraction(0.7)
    mixed.selectedSegmentID = sectionB.id
    mixed.undo(origin: .agent("Codex"), expectedTransaction: ownStep.transactionID, expectedRevision: mixed.revision)
    check(abs(mixed.items[0].previewFraction - 0.7) < 0.000001 && mixed.selectedSegmentID == sectionB.id,
          "an agent's undo leaves the owner's playhead and selection alone")
    check(mixed.editSession.events.contains { $0.kind == .undo && $0.origin == .agent("Codex") },
          "the change feed records an agent's undo and who asked")

    mixed.agentsPaused = true
    equal(refusal(mixed.perform([.setAspect(clip: clipID, preset: "Free")], origin: .agent("Codex"),
                                expectedRevision: mixed.revision)), .agentsPaused, "paused agents cannot edit")
    mixed.agentsPaused = false
    mixed.isConverting = true
    equal(refusal(mixed.perform([.setAspect(clip: clipID, preset: "Free")], origin: .agent("Codex"),
                                expectedRevision: mixed.revision)), .exportInProgress, "agents cannot edit during an export")
    mixed.isConverting = false

    // Sessions: a different document, or the same file opened afresh, is a new session.
    let firstSession = mixed.editSession.sessionID
    mixed.newProject()
    check(mixed.editSession.sessionID != firstSession, "a new project starts a new session")
    let emptySession = mixed.editSession.sessionID
    mixed.undoEdit()
    check(mixed.editSession.sessionID != emptySession, "undoing back to the previous project starts another session")
    mixed.openProject(at: namedProject)
    let openedSession = mixed.editSession.sessionID
    mixed.openProject(at: namedProject)
    check(mixed.editSession.sessionID != openedSession, "reopening the same file is a new session")
    for _ in 0..<1100 { mixed.appendEvent(.edit, origin: .human, label: "filler") }
    equal(mixed.editSession.events.count, EditSessionState.eventLimit, "the change feed keeps a bounded history")

    // A probe that finishes after Add is a fact about the file, not an undo step.
    let probing = AppModel(recoveryURL: nil)
    probing.perform([.addMedia([ProjectClip(VideoItem(url: landscape))])])
    let probedID = probing.items[0].id
    let probeHistory = probing.undoEntries.count
    probing.resolveMedia(probedID, info: info, subtitles: nil)
    equal(probing.undoEntries.count, probeHistory, "a finished probe adds no undo step")
    probing.undoEdit(); probing.redoEdit()
    equal(probing.items.first?.info, info, "undo and redo do not forget a probe that finished after Add")

    // The inspector follows what was selected last, and falls back to the recording.
    let focusing = freshEditor()
    equal(focusing.inspectorFocus, .recording, "with nothing selected the inspector shows the recording")
    focusing.selectedSegmentID = sectionA.id
    equal(focusing.inspectorFocus, .section, "selecting a section shows it in the inspector")
    focusing.selectedShotID = anchoredZoom.id
    equal(focusing.inspectorFocus, .zoom, "selecting a zoom afterwards shows the zoom instead")
    focusing.selectedSegmentID = nil
    equal(focusing.inspectorFocus, .zoom, "clearing something not shown leaves the inspector alone")
    focusing.selectedShotID = nil
    equal(focusing.inspectorFocus, .recording, "clearing what is shown falls back to the recording")
    focusing.selectedRegionID = UUID()
    focusing.perform([.setAspect(clip: focusing.items[0].id, preset: "1:1")])
    equal(focusing.inspectorFocus, .recording, "a selection that no longer exists after an edit is cleared from the inspector")

    // MARK: - Selecting several sections

    print("\nSelecting sections")
    // Four sections played in an order unlike their source order, so anything that orders
    // by source time, insertion or a Set's whim shows up as wrong.
    let pickA = TimelineSegment(start: 2, end: 3), pickB = TimelineSegment(start: 0, end: 0.5)
    let pickC = TimelineSegment(start: 1, end: 2), pickD = TimelineSegment(start: 0.5, end: 1)
    let pickTimeline = ClipTimeline(segments: [pickA, pickB, pickC, pickD])
    let shuffled = ClipTimeline(segments: [pickC, pickA, pickD, pickB])

    let ranged = SectionSelection.single(pickA.id).clicking(pickB.id, extend: true, toggle: false, in: shuffled)
    equal(ranged.ordered(in: shuffled).map(\.id), [pickA.id, pickD.id, pickB.id],
          "⇧-click selects the range by timeline order, not by source or insertion order")
    equal(ranged.anchor, pickA.id, "and the anchor stays where the range began")
    let backwards = SectionSelection.single(pickD.id).clicking(pickC.id, extend: true, toggle: false, in: shuffled)
    equal(backwards.ordered(in: shuffled).map(\.id), [pickC.id, pickA.id, pickD.id], "a range can run backwards")
    equal(SectionSelection().clicking(pickC.id, extend: true, toggle: false, in: shuffled), .single(pickC.id),
          "⇧-click with nothing selected selects just that section")
    equal(ranged.clicking(pickC.id, extend: false, toggle: false, in: shuffled), .single(pickC.id),
          "a plain click selects one section again")

    let toggled = SectionSelection.single(pickA.id).clicking(pickC.id, extend: false, toggle: true, in: pickTimeline)
    check(toggled.ids == [pickA.id, pickC.id] && toggled.anchor == pickC.id, "⌘-click adds a section and anchors on it")
    let untoggled = toggled.clicking(pickC.id, extend: false, toggle: true, in: pickTimeline)
    check(untoggled.ids == [pickA.id] && untoggled.anchor == pickA.id,
          "⌘-clicking it again removes it, handing the anchor to a section still selected")
    let emptied = untoggled.clicking(pickA.id, extend: false, toggle: true, in: pickTimeline)
    check(emptied.isEmpty && emptied.anchor == nil, "removing the last one leaves nothing selected")

    let everything = SectionSelection.all(in: pickTimeline, anchor: pickC.id)
    check(everything.count == 4 && everything.anchor == pickC.id, "select all keeps the anchor")
    let pruned = everything.keeping(ClipTimeline(segments: [pickA, pickB, pickD]))
    check(pruned.ids == [pickA.id, pickB.id, pickD.id] && pruned.anchor == pickA.id,
          "sections an edit removed leave the selection, and so does the anchor")
    check(SectionSelection(.init(), anchor: pickA.id).anchor == nil, "an anchor is always one of the selected sections")

    // The editor: clicks, keys, and edits on the whole selection as one step.
    var pickItem = VideoItem(url: landscape)
    pickItem.info = info; pickItem.crop = info.fullFrame
    pickItem.segments = pickTimeline.segments
    let picking = AppModel(recoveryURL: nil)
    picking.restore(VideoProject(clips: [ProjectClip(pickItem)], settings: ExportSettings(), selection: pickItem.id))
    let pickTotal = picking.items[0].editedDuration
    picking.clickSegment(pickB.id, at: 1.2)
    check(picking.selectedSegmentID == pickB.id && abs(picking.previewTime - 1.2) < 0.0001,
          "a plain click selects the section and moves the playhead")
    picking.clickSegment(pickD.id, at: 2.8, extend: true)
    equal(picking.sectionSelection.ordered(in: picking.items[0].timeline).map(\.id), [pickB.id, pickC.id, pickD.id],
          "⇧-click in the editor extends the range")
    check(abs(picking.previewTime - 1.2) < 0.0001, "without moving the playhead")
    equal(picking.inspectorFocus, .section, "several sections show in the inspector")
    equal(picking.agentState().selection.sections, [pickB.id, pickC.id, pickD.id], "agents see every selected section, in order")
    equal(picking.agentState().selection.section, pickB.id, "and which one is the anchor")

    let speedSteps = picking.undoEntries.count
    picking.setSelectedSectionsSpeed(2)
    equal(picking.items[0].timeline.segments.map(\.speed), [1, 2, 2, 2], "a speed applies to every selected section")
    equal(picking.undoEntries.count, speedSteps + 1, "as one undo step")
    equal(picking.undoTitle, "Undo Change Speed of 3 Sections", "named for what it did")
    equal(picking.sectionSelection.count, 3, "and the sections stay selected")
    picking.undoEdit()
    equal(picking.items[0].timeline.segments.map(\.speed), [1, 1, 1, 1], "one undo restores every speed")
    equal(picking.sectionSelection.count, 3, "and the selection as it was")

    let deleteSteps = picking.undoEntries.count
    picking.deleteSegment()
    equal(picking.items[0].timeline.segments.map(\.id), [pickA.id], "delete removes every selected section")
    equal(picking.undoEntries.count, deleteSteps + 1, "as one undo step")
    equal(picking.undoTitle, "Undo Delete 3 Sections", "named for how many it removed")
    equal(picking.selectedSegmentID, pickA.id, "and selects what is left in their place")
    picking.undoEdit()
    equal(picking.items[0].timeline.segments.map(\.id), pickTimeline.segments.map(\.id), "one undo brings them all back")
    equal(picking.sectionSelection.count, 3, "selected as they were")

    picking.selectAllSegments()
    equal(picking.sectionSelection.count, 4, "⌘A selects every section")
    let refusedSteps = picking.undoEntries.count
    picking.deleteSegment()
    check(picking.items[0].timeline.segments.count == 4 && picking.undoEntries.count == refusedSteps,
          "deleting every section is refused rather than leaving an empty recording")
    check(picking.statusMessage?.contains("Keep at least one section") == true, "and says why", picking.statusMessage ?? "")

    picking.selectedSegmentID = pickB.id
    picking.selectAdjacentSegment(1)
    equal(picking.selectedSegmentID, pickC.id, "⌘→ selects the next section")
    check(abs(picking.previewTime - picking.items[0].timeline.offset(of: pickC.id)) < 0.0001, "and moves the playhead to it")
    picking.selectAdjacentSegment(-1); picking.selectAdjacentSegment(-1); picking.selectAdjacentSegment(-1)
    equal(picking.selectedSegmentID, pickA.id, "⌘← stops at the first section rather than wrapping")
    picking.selectedSegmentID = nil
    picking.setPreviewFraction(2.7 / pickTotal)     // inside D, which plays from 2.5
    picking.selectAdjacentSegment(1)
    equal(picking.selectedSegmentID, pickD.id, "with nothing selected it picks the section under the playhead")

    picking.clickSegment(pickB.id, at: 1.1)
    picking.clickSegment(pickC.id, at: 1.6, extend: true)
    picking.movePlayheadToSelection(start: true)
    check(abs(picking.previewTime - 1) < 0.0001, "⇧Home moves the playhead to where the selection starts", "\(picking.previewTime)")
    picking.movePlayheadToSelection(start: false)
    check(abs(picking.previewTime - (2.5 - 1 / info.fps)) < 0.0001,
          "⇧End to its last frame, inside the selection", "\(picking.previewTime)")

}
