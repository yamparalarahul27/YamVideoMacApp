import AppKit
import Foundation

/// The timeline's rows (step 1 of the Studio redesign): their order, folding, the eye,
/// the lock and the preview's sound, the badges on a section and its filmstrip tiles.
@MainActor func tracksTests() async throws {
    print("\nTimeline rows")
    var clip = VideoItem(url: landscape)
    clip.info = info
    clip.crop = info.fullFrame
    equal(TimelineTrack.tracks(for: clip), [.shorts, .graphics, .effects, .zoom, .video, .audio, .music, .captions],
          "a recording with no screen recording has no screen rows")
    let order = TimelineTrack.allCases
    check(order.firstIndex(of: .graphics)! < order.firstIndex(of: .video)!, "what draws over the picture sits above it")
    check(order.firstIndex(of: .audio)! > order.firstIndex(of: .video)!, "and its sound sits below it")
    equal(TimelineTrack.tracks(for: clip).filter { $0.isEmpty(in: clip) }, [.shorts, .graphics, .effects, .zoom, .music, .captions],
          "a new recording folds each row it has nothing on")
    clip.zoomShots = [ZoomShot(start: 1, target: CGPoint(x: 100, y: 100))]
    check(!TimelineTrack.zoom.isEmpty(in: clip), "a zoom opens the Zoom row")
    clip.blurRegions = [BlurRegion(rect: CGRect(x: 0, y: 0, width: 64, height: 64))]
    check(!TimelineTrack.effects.isEmpty(in: clip), "a blur area opens the Effects row, with no timed effect")
    check(TimelineTrack.zoom.hides && TimelineTrack.graphics.hides && !TimelineTrack.video.hides,
          "overlays have an eye; the video has none")
    check(TimelineTrack.video.locks && !TimelineTrack.audio.locks, "the video locks; its sound follows it")

    print("\nHide in the preview")
    clip.blurEffects = [VideoBlurEffect(start: 1, end: 2)]
    equal(clip.previewing(hiding: []).zoomShots.count, 1, "with nothing hidden the preview has everything")
    let noZoom = clip.previewing(hiding: [.zoom])
    check(noZoom.zoomShots.isEmpty && noZoom.blurEffects.count == 1, "hiding Zoom leaves out the zooms only")
    let noEffects = clip.previewing(hiding: [.effects])
    check(noEffects.blurEffects.isEmpty && noEffects.blurRegions.isEmpty && noEffects.zoomShots.count == 1,
          "hiding Effects leaves out the blur effects and the blur areas")
    equal(clip.zoomShots.count, 1, "and the recording itself keeps them")

    let model = freshEditor()
    model.timelineTracks.hidden.insert(.zoom)
    equal(model.playback.hiddenTracks, [.zoom], "the player learns what is hidden")
    model.toggleTrackHidden(.zoom)
    check(model.playback.hiddenTracks.isEmpty, "and shows it again")
    model.toggleTrackHidden(.video)
    check(model.timelineTracks.hidden.isEmpty, "the video cannot be hidden")
    model.toggleTrackMuted()
    check(model.playback.player.isMuted, "muting the Audio row mutes the preview")
    model.toggleTrackMuted()
    check(!model.playback.player.isMuted, "and the sound comes back")

    print("\nLocked rows")
    if let first = model.selectedItem?.timeline.segments.first, (model.selectedItem?.timeline.segments.count ?? 0) > 1 {
        let before = model.selectedItem?.timeline.segments.count
        model.selectSegment(first.id)
        equal(model.inspectorFocus, .section, "a section selected on the timeline")
        model.toggleTrackLocked(.video)
        model.deleteSelection()
        equal(model.selectedItem?.timeline.segments.count, before, "Delete leaves a section on a locked row")
        check(model.statusMessage?.contains("locked") == true, "and says why")
        model.toggleTrackLocked(.video)
        model.deleteSelection()
        equal(model.selectedItem?.timeline.segments.count, before.map { $0 - 1 }, "unlocked, the tool bar's Delete removes it")
        model.undoEdit()
        equal(model.selectedItem?.timeline.segments.count, before, "and Undo brings it back")
    } else {
        check(false, "the round-trip project has more than one section to delete")
    }
    let tallModel = AppModel(recoveryURL: nil)
    let savedTall = tallModel.timelineTallTracks
    tallModel.timelineTallTracks = false
    equal(AppModel(recoveryURL: nil).timelineTallTracks, false, "short rows are remembered for the next window")
    tallModel.timelineTallTracks = savedTall

    print("\nSection badges")
    var plain = VideoItem(url: landscape)
    plain.info = info
    plain.crop = info.fullFrame
    let section = TimelineSegment(start: 0, end: 1)
    equal(plain.badges(for: section, settings: ExportSettings()), [], "a section with nothing applied has no badges")
    equal(plain.badges(for: TimelineSegment(start: 0, end: 1, speed: 1.5), settings: ExportSettings()).first, .speed(1.5),
          "a faster section shows its speed first")
    plain.crop = CGRect(x: 0, y: 0, width: CGFloat(info.width / 2), height: CGFloat(info.height / 2))
    check(plain.badges(for: section, settings: ExportSettings()).contains(.crop), "a crop shows on the section")
    plain.blurRegions = [BlurRegion(rect: CGRect(x: 0, y: 0, width: 32, height: 32))]
    check(plain.badges(for: section, settings: ExportSettings()).contains(.blur), "and so does a blur area")

    print("\nFilmstrip")
    var viewport = TimelineViewport(total: 100)
    let footage = TimelineSegment(start: 10, end: 60)
    // 1000 points for 100 s: 10 points a second, so a 100-point tile covers 10 s.
    let tiles = Filmstrip.tiles(for: footage, offset: 0, viewport: viewport, width: 1000, tileWidth: 100)
    equal(tiles.count, 5, "one tile for each tile width of the section")
    equal(tiles.first?.x, 0, "the first tile starts at the section's edge")
    check(tiles.allSatisfy { $0.source >= 10 && $0.source <= 60 }, "each tile shows the section's own footage")
    check(zip(tiles, tiles.dropFirst()).allSatisfy { $1.source > $0.source }, "and the frames move forward through it")
    equal(Filmstrip.step(pixelsPerSecond: 10, speed: 1, tileWidth: 100), 10, "frames come at the finest step one tile covers")
    equal(Filmstrip.step(pixelsPerSecond: 10, speed: 2, tileWidth: 100), 30, "a faster section covers more footage in a tile")
    viewport.zoom(to: 10, keeping: 30)
    let zoomed = Filmstrip.tiles(for: footage, offset: 0, viewport: viewport, width: 1000, tileWidth: 100)
    check(!zoomed.isEmpty && zoomed.count <= 12, "zoomed in, only the tiles on screen are made", "\(zoomed.count) tiles")
    check(Filmstrip.tiles(for: footage, offset: 200, viewport: viewport, width: 1000, tileWidth: 100).isEmpty,
          "a section off screen makes no tiles")
}
