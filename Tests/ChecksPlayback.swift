// Checks for playback. Run with ./test.sh playback
import AppKit
import AVFoundation
import Foundation

@MainActor func playbackTests() async throws {
    let (markerClip, markerInfo) = try await markerFixture()
    // MARK: - Actual reordered video/audio exports and native playback

    print("\nEdited video and playback")
    let colorSource = scratch.appendingPathComponent("colors.mp4")
    let colors = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
        "color=c=red:s=320x180:r=30:d=1[r];color=c=green:s=320x180:r=30:d=1[g];color=c=blue:s=320x180:r=30:d=1[b];[r][g][b]concat=n=3:v=1:a=0",
        "-f", "lavfi", "-i", #"aevalsrc=sin(2*PI*t*if(lt(t\,1)\,440\,if(lt(t\,2)\,880\,1320))):s=48000:d=3"#,
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-t", "3", colorSource.path
    ])
    check(colors.status == 0, "creates distinguishable video and audio sections", colors.stderrText)
    let colorInfo = try await FFmpeg.probe(url: colorSource)
    let edits = [TimelineSegment(start: 2, end: 2.7), TimelineSegment(start: 0.2, end: 0.8)]
    var editedSettings = ExportSettings()
    editedSettings.audio = .copy
    let editedOut = scratch.appendingPathComponent("edited.mp4")
    try await FFmpeg.export(input: colorSource, output: editedOut, info: colorInfo, crop: colorInfo.fullFrame,
                            segments: edits, settings: editedSettings) { _ in }
    let editedInfo = try await FFmpeg.probe(url: editedOut)
    check(abs(editedInfo.duration - 1.3) < 0.06, "export duration equals retained sections", "\(editedInfo.duration)")
    equal(try await frameCount(editedOut), 39, "edited export has exactly 39 frames")
    equal(editedInfo.audioCodec, "aac", "cut audio is encoded even when Copy was selected")
    let firstColor = try await pixel(editedOut, x: 150, y: 80, at: 0.1)
    let secondColor = try await pixel(editedOut, x: 150, y: 80, at: 0.9)
    check(firstColor.2 > 200 && firstColor.0 < 40, "export starts with the moved blue section")
    check(secondColor.0 > 200 && secondColor.2 < 40, "export cuts directly to the retained red section")

    check(abs(try await toneFrequency(editedOut, at: 0.1) - 1320) < 15, "audio follows the moved blue section")
    check(abs(try await toneFrequency(editedOut, at: 0.85) - 440) < 15, "audio changes with the cut to red")

    var editedGIFSettings = ExportSettings()
    editedGIFSettings.format = .gif
    let editedGIF = scratch.appendingPathComponent("edited.gif")
    try await FFmpeg.export(input: colorSource, output: editedGIF, info: colorInfo, crop: colorInfo.fullFrame,
                            segments: edits, settings: editedGIFSettings) { _ in }
    check(abs(try await frameCount(editedGIF) - 20) <= 1, "GIF palette and encode both honor the timeline")
    let gifFirst = try await pixel(editedGIF, x: 100, y: 80, at: 0.1)
    check(gifFirst.2 > 200 && gifFirst.0 < 40, "edited GIF preserves section order")

    var nativeClip = VideoItem(url: colorSource)
    nativeClip.info = colorInfo; nativeClip.crop = colorInfo.fullFrame; nativeClip.segments = edits
    let nativeItem = try await PlaybackController.makeItem(nativeClip, settings: ExportSettings())
    let nativeGenerator = AVAssetImageGenerator(asset: nativeItem.asset)
    nativeGenerator.videoComposition = nativeItem.videoComposition
    nativeGenerator.requestedTimeToleranceBefore = .zero; nativeGenerator.requestedTimeToleranceAfter = .zero
    let nativeBlue = try await nativeGenerator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
    let nativeRed = try await nativeGenerator.image(at: CMTime(seconds: 0.9, preferredTimescale: 600)).image
    let previewBlue = nativePixel(nativeBlue, x: 100, y: 80)
    let previewRed = nativePixel(nativeRed, x: 100, y: 80)
    check(previewBlue.2 > 200 && previewBlue.0 < 40, "native playback uses the moved first section")
    check(previewRed.0 > 200 && previewRed.2 < 40, "native playback cuts at the same time as export")

    // Use the existing marker fixture to verify Core Image's crop/zoom coordinate system.
    var nativeMarker = VideoItem(url: markerClip)
    nativeMarker.info = markerInfo; nativeMarker.crop = CGRect(x: 100, y: 50, width: 1000, height: 600)
    nativeMarker.zoomShots = [ZoomShot(start: 0.5, hold: 1, level: 2, target: CGPoint(x: 930, y: 530))]
    let markerPlayer = try await PlaybackController.makeItem(nativeMarker, settings: ExportSettings())
    let markerGenerator = AVAssetImageGenerator(asset: markerPlayer.asset)
    markerGenerator.videoComposition = markerPlayer.videoComposition
    let markerPreview = try await markerGenerator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
    check(markerPreview.width == 1000 && markerPreview.height == 600, "native cropped preview uses export dimensions")
    let renderedPNG = scratch.appendingPathComponent("native-zoom.png")
    try NSBitmapImageRep(cgImage: markerPreview).representation(using: .png, properties: [:])!.write(to: renderedPNG)
    let nativeBox = try await markerBox(renderedPNG, at: 0, size: CGSize(width: 1000, height: 600))
    check(nativeBox != nil && nativeBox!.width > 100, "native preview applies the zoom to the marker", "\(String(describing: nativeBox))")

    // Coordinate parity, including a rotated source, is essential for usable previews.
    let parityExport = scratch.appendingPathComponent("native-parity.mp4")
    try await FFmpeg.export(input: markerClip, output: parityExport, info: markerInfo,
        crop: nativeMarker.crop!, zoomShots: nativeMarker.zoomShots, settings: ExportSettings()) { _ in }
    let parityBox = try await markerBox(parityExport, at: 1.5, size: CGSize(width: 1000, height: 600))
    check(nativeBox != nil && parityBox != nil && abs(nativeBox!.midX - parityBox!.midX) < 5 && abs(nativeBox!.midY - parityBox!.midY) < 5,
          "native crop/zoom placement agrees with exported frames", "native \(String(describing: nativeBox)); export \(String(describing: parityBox))")
    if let rotated {
        var portrait = VideoItem(url: rotated)
        portrait.info = try await FFmpeg.probe(url: rotated)
        portrait.crop = CGRect(x: 0, y: 100, width: 720, height: 900)
        portrait.blurRegions = [BlurRegion(rect: CGRect(x: 100, y: 200, width: 100, height: 100))]
        var portraitSettings = ExportSettings(); portraitSettings.blurStyle = .black
        let portraitPlayer = try await PlaybackController.makeItem(portrait, settings: portraitSettings)
        let generator = AVAssetImageGenerator(asset: portraitPlayer.asset)
        generator.videoComposition = portraitPlayer.videoComposition
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        check(frame.width == 720 && frame.height == 900, "native preview respects rotated crop dimensions")
        let black = nativePixel(frame, x: 150, y: 150)
        check(black.0 < 15 && black.1 < 15 && black.2 < 15, "native redaction respects rotated source coordinates")
    }

    let recoveryPath = scratch.appendingPathComponent("recovery.yamvideo")
    let recoveringEditor = AppModel(recoveryURL: recoveryPath)
    recoveringEditor.restore(roundTripProject)
    recoveringEditor.projectURL = namedProject
    recoveringEditor.savedProject = roundTripProject
    recoveringEditor.setPreviewFraction(0.25)
    recoveringEditor.splitAtPlayhead()
    recoveringEditor.flushRecovery()
    let resumedEditor = AppModel(recoveryURL: recoveryPath)
    equal(resumedEditor.project.clips, recoveringEditor.project.clips, "autosave recovers unsaved cuts")
    equal(resumedEditor.projectURL, namedProject, "recovery retains the named project's save destination")
    check(resumedEditor.hasUnsavedChanges, "recovered unsaved edits remain marked as changed")
    resumedEditor.newProject()
    check(resumedEditor.items.isEmpty && resumedEditor.projectURL == nil, "new project starts with an empty timeline")
    resumedEditor.undoEdit()
    equal(resumedEditor.projectURL, namedProject, "undoing New Project restores the previous save destination")

    // Editing an exported item must make it exportable again without breaking queue cleanup.
    let queueEditor = AppModel(recoveryURL: nil)
    queueEditor.restore(roundTripProject)
    queueEditor.items[0].status = .done(editedOut)
    queueEditor.clearFinished()
    check(queueEditor.items.isEmpty, "Clear Done removes the selected completed item")
    queueEditor.undoEdit()
    check(queueEditor.items.count == 1, "undo restores a cleared item")
    queueEditor.items[0].status = .done(editedOut)
    var changedSettings = queueEditor.settings; changedSettings.quality = 50
    queueEditor.updateSettings(changedSettings)
    equal(queueEditor.convertibleCount, 1, "changing export settings makes completed edits exportable again")
    let historyCount = queueEditor.undoEntries.count
    queueEditor.updateCrop(queueEditor.selectedItem!.crop!)
    equal(queueEditor.undoEntries.count, historyCount, "an unchanged crop does not create a spurious undo step")

    var combinedClip = nativeMarker
    combinedClip.segments = [TimelineSegment(start: 1, end: 3), TimelineSegment(start: 0, end: 0.5)]
    let combinedOut = scratch.appendingPathComponent("combined-edit.mp4")
    try await FFmpeg.export(input: markerClip, output: combinedOut, info: markerInfo, crop: combinedClip.crop!,
        regions: [CGRect(x: 0, y: 0, width: 100, height: 100)], zoomShots: combinedClip.zoomShots,
        segments: combinedClip.segments, settings: ExportSettings()) { _ in }
    equal(try await frameCount(combinedOut), 75, "cuts, complex blur and zoom compose without changing frame count")
    let combinedBox = try await markerBox(combinedOut, at: 1.5, size: CGSize(width: 1000, height: 600))
    check(combinedBox != nil && parityBox != nil && abs(combinedBox!.midX - parityBox!.midX) < 5,
          "zoom remains correctly positioned after timeline assembly and blur")

    var numericRateProject = roundTripProject
    numericRateProject.clips[0].info?.fpsExpression = "30"
    try numericRateProject.validate()
    check(true, "project accepts the numeric fallback frame rate")
    let zoomEditor = AppModel(recoveryURL: nil)
    zoomEditor.restore(roundTripProject)
    let resizingShot = zoomEditor.selectedItem!.zoomShots[0]
    zoomEditor.setZoomHold(resizingShot.id, 100)
    equal(zoomEditor.selectedItem!.zoomShots[0].start, resizingShot.start, "resizing a zoom keeps its start fixed")
    check(abs(zoomEditor.selectedItem!.zoomShots[0].end - zoomEditor.selectedItem!.editedDuration) < 0.001,
          "resizing a zoom clamps its end to the edited duration")

    print("\nMulti-recording movies")
    let movieItems = [nativeClip, combinedClip]
    let moviePlan = try MoviePlan(items: movieItems, movieSettings: MovieSettings(), settings: ExportSettings())
    equal(moviePlan.size, CGSize(width: 320, height: 180), "movie canvas follows its first cropped recording")
    check(abs(moviePlan.duration - 3.8) < 0.001, "movie duration includes cuts from every recording")
    let movieFile = scratch.appendingPathComponent("multi-recording.mp4")
    try await FFmpeg.exportMovie(plan: moviePlan, settings: ExportSettings(), output: movieFile) { _ in }
    let movieInfo = try await FFmpeg.probe(url: movieFile)
    equal(movieInfo.width, 320, "movie export fits differing dimensions onto one canvas")
    check(abs(movieInfo.duration - 3.8) < 0.08, "assembled movie duration matches retained footage", "\(movieInfo.duration)")
    equal(try await frameCount(movieFile), 114, "movie export retains the expected frame count")
    let movieFirst = try await pixel(movieFile, x: 100, y: 80, at: 0.1)
    check(movieFirst.2 > 200 && movieFirst.0 < 40, "movie starts with the first clip's edited section")
    check(abs(try await toneFrequency(movieFile, at: 0.1) - 1320) < 15, "movie retains reordered source audio")
    let moviePlayer = try await PlaybackController.makeMovieItem(moviePlan, settings: ExportSettings())
    let movieGenerator = AVAssetImageGenerator(asset: moviePlayer.asset)
    movieGenerator.videoComposition = moviePlayer.videoComposition
    let movieFrame = try await movieGenerator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
    let moviePreviewFirst = nativePixel(movieFrame, x: 100, y: 80)
    check(moviePreviewFirst.2 > 200 && moviePreviewFirst.0 < 40, "movie native preview starts with the same edited section")
    let secondMovieFrame = try await movieGenerator.image(at: CMTime(seconds: 2.8, preferredTimescale: 600)).image
    let movieFrameURL = scratch.appendingPathComponent("movie-native.png")
    try NSBitmapImageRep(cgImage: secondMovieFrame).representation(using: .png, properties: [:])!.write(to: movieFrameURL)
    let movieNativeBox = try await markerBox(movieFrameURL, at: 0, size: moviePlan.size)
    let movieExportBox = try await markerBox(movieFile, at: 2.8, size: moviePlan.size)
    check(movieNativeBox != nil && movieExportBox != nil && abs(movieNativeBox!.midX - movieExportBox!.midX) < 4 && abs(movieNativeBox!.midY - movieExportBox!.midY) < 4,
          "movie native preview matches scaled crop and zoom across sources", "native \(String(describing: movieNativeBox)), export \(String(describing: movieExportBox))")
    let silentData = try await Shell.run(ffmpeg, ["-v", "error", "-ss", "2", "-i", movieFile.path, "-t", "0.2", "-vn", "-f", "s16le", "-ac", "1", "-"])
    check(!silentData.stdout.isEmpty && silentData.stdout.allSatisfy { $0 == 0 }, "silent recordings receive a silent movie audio track")

    var movieGIFSettings = ExportSettings(); movieGIFSettings.format = .gif
    let movieGIF = scratch.appendingPathComponent("multi.gif")
    try await FFmpeg.exportMovie(plan: moviePlan, settings: movieGIFSettings, output: movieGIF) { _ in }
    check(abs(try await frameCount(movieGIF) - 57) <= 1, "multi-clip GIF uses a shared palette and edited duration")
    var firstSilentSettings = ExportSettings(); firstSilentSettings.audio = .copy
    let silentFirstPlan = try MoviePlan(items: [combinedClip, nativeClip], movieSettings: MovieSettings(), settings: firstSilentSettings)
    let silentFirstMovie = scratch.appendingPathComponent("silent-first.mp4")
    try await FFmpeg.exportMovie(plan: silentFirstPlan, settings: firstSilentSettings, output: silentFirstMovie) { _ in }
    equal(try await FFmpeg.probe(url: silentFirstMovie).audioCodec, "aac", "audio survives when the first recording is silent and Copy is selected")
    var movieLoudSettings = ExportSettings(); movieLoudSettings.audio = .normalised
    let movieLoudArguments = FFmpeg.movieArguments(plan: moviePlan, settings: movieLoudSettings, output: movieFile)
    check(!movieLoudArguments.contains("-af"), "a normalised movie puts loudnorm in the filter graph")
    check(movieLoudArguments.contains("[normalsound]"), "a normalised movie maps the normalised sound")
    let movieLoud = scratch.appendingPathComponent("movie-normalised.mp4")
    try await FFmpeg.exportMovie(plan: moviePlan, settings: movieLoudSettings, output: movieLoud) { _ in }
    equal(try await FFmpeg.probe(url: movieLoud).audioCodec, "aac", "a normalised movie exports with an AAC track")

    if let rotated {
        var portraitClip = VideoItem(url: rotated)
        portraitClip.info = try await FFmpeg.probe(url: rotated)
        portraitClip.crop = portraitClip.info!.fullFrame
        portraitClip.segments = [TimelineSegment(start: 0, end: 0.6)]
        let rotationPlan = try MoviePlan(items: [nativeClip, portraitClip], movieSettings: MovieSettings(), settings: ExportSettings())
        let rotationMovie = scratch.appendingPathComponent("rotation-movie.mp4")
        try await FFmpeg.exportMovie(plan: rotationPlan, settings: ExportSettings(), output: rotationMovie) { _ in }
        let rotationPlayer = try await PlaybackController.makeMovieItem(rotationPlan, settings: ExportSettings())
        let generator = AVAssetImageGenerator(asset: rotationPlayer.asset)
        generator.videoComposition = rotationPlayer.videoComposition
        let frame = try await generator.image(at: CMTime(seconds: 1.6, preferredTimescale: 600)).image
        let side = nativePixel(frame, x: 10, y: 90)
        check(side.0 < 10 && side.1 < 10 && side.2 < 10, "movie preview letterboxes a portrait recording")
        var difference = 0
        for point in [(130, 30), (155, 60), (180, 90), (140, 140)] {
            let a = nativePixel(frame, x: point.0, y: point.1)
            let b = try await pixel(rotationMovie, x: point.0, y: point.1, at: 1.6)
            difference += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        }
        check(difference < 300, "movie preview rotation matches exported portrait footage", "summed RGB difference \(difference)")
    }
    let movieEditor = AppModel(recoveryURL: nil)
    movieEditor.restore(VideoProject(clips: movieItems.map(ProjectClip.init), settings: ExportSettings(), selection: nativeClip.id))
    movieEditor.moveMovieClip(nativeClip.id, by: 1)
    equal(movieEditor.items.first!.id, combinedClip.id, "movie recording order is editable")
    movieEditor.undoEdit()
    equal(movieEditor.items.first!.id, nativeClip.id, "undo restores movie recording order")
    movieEditor.includeInMovie(nativeClip.id, included: false)
    equal(try movieEditor.moviePlan().clips.count, 1, "excluded recordings remain editable but leave the movie")
    let movieSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(movieEditor.project))
    check(movieSaved.clips[0].includedInMovie == false, "project saves movie inclusion choices")

    print("\nAssisted zooms and mixed frame rates")
    check(ZoomAnalyzer.activity(previous: still, current: still) == nil, "static frames produce no zoom suggestion")
    check(ZoomAnalyzer.activity(previous: still, current: [UInt8](repeating: 220, count: still.count)) == nil,
          "whole-screen changes are not mistaken for a zoom target")
    let activity = ZoomAnalyzer.activity(previous: still, current: active)
    check(activity != nil && abs(activity!.point.x - 0.78125) < 0.01 && abs(activity!.point.y - 0.3889) < 0.01,
          "localized activity yields the correct normalized target")
    var analysisClip = VideoItem(url: markerClip)
    analysisClip.info = markerInfo
    var analysisFrames = Data()
    for i in 0..<6 { analysisFrames.append(contentsOf: i == 2 ? active : still) }
    let proposed = ZoomAnalyzer.proposals(frames: analysisFrames, rate: 2, clip: analysisClip)
    equal(proposed.count, 1, "nearby activity events merge into one non-overlapping zoom")
    if let proposal = proposed.first {
        check(proposal.shot.end <= analysisClip.editedDuration, "suggested zoom fits the edited duration")
        analysisClip.zoomShots = [proposal.shot]
        check(ZoomAnalyzer.proposals(frames: analysisFrames, rate: 2, clip: analysisClip).isEmpty,
              "suggestions respect existing manual zooms")
    }
    analysisClip.zoomShots = []
    analysisClip.crop = CGRect(x: 0, y: 0, width: 200, height: 200)
    check(ZoomAnalyzer.proposals(frames: analysisFrames, rate: 2, clip: analysisClip).isEmpty,
          "activity outside the crop is ignored")
    analysisClip.crop = nil
    analysisClip.segments = [TimelineSegment(start: 0, end: 0.9), TimelineSegment(start: 1.6, end: 3)]
    check(ZoomAnalyzer.proposals(frames: analysisFrames, rate: 2, clip: analysisClip).isEmpty,
          "activity in removed footage is ignored")

    var (activityFile, activityClip) = try await activityFixture()
    let detected = try await ZoomAnalyzer.analyze(activityClip)
    check(!detected.isEmpty, "local FFmpeg analysis produces a reviewable zoom suggestion")
    let suggestionEditor = AppModel(recoveryURL: nil)
    suggestionEditor.restore(VideoProject(clips: [ProjectClip(activityClip)], settings: ExportSettings(), selection: activityClip.id))
    suggestionEditor.zoomSuggestions = detected
    suggestionEditor.zoomSuggestionTimeline = suggestionEditor.items[0].timeline
    suggestionEditor.applyZoomSuggestions()
    equal(suggestionEditor.items[0].zoomShots.count, detected.count, "selected suggestions become ordinary editable zooms")
    suggestionEditor.undoEdit()
    check(suggestionEditor.items[0].zoomShots.isEmpty, "one undo removes the applied suggestions")
    suggestionEditor.setPreviewFraction(0.5)
    suggestionEditor.splitAtPlayhead()
    suggestionEditor.zoomSuggestions = detected
    suggestionEditor.applyZoomSuggestions()
    check(suggestionEditor.items[0].zoomShots.isEmpty, "suggestions made before a recut are refused, not misplaced")
    activityClip.zoomShots = detected.map(\.shot)
    var mixedSettings = ExportSettings(); mixedSettings.audio = .none
    let mixedPlan = try MoviePlan(items: [nativeClip, activityClip], movieSettings: MovieSettings(), settings: mixedSettings)
    let mixedFile = scratch.appendingPathComponent("mixed-rate.mp4")
    try await FFmpeg.exportMovie(plan: mixedPlan, settings: mixedSettings, output: mixedFile) { _ in }
    equal(try await frameCount(mixedFile), 159, "24 fps footage with zoom normalizes to 30 fps without changing speed")
    let mixedInfo = try await FFmpeg.probe(url: mixedFile)
    check(abs(mixedInfo.duration - 5.3) < 0.04 && !mixedInfo.hasAudio, "mixed-rate silent movie keeps its planned duration")
    let portraitPlan = try MoviePlan(items: movieItems, movieSettings: MovieSettings(canvas: .portrait), settings: ExportSettings())
    equal(portraitPlan.size, CGSize(width: 1080, height: 1920), "portrait movie canvas is available")

    let protectedOutput = scratch.appendingPathComponent("protected-movie.mp4")
    let originalOutput = Data("existing export must survive cancellation".utf8)
    try originalOutput.write(to: protectedOutput)
    movieEditor.startMovieExport(plan: moviePlan, output: protectedOutput)
    movieEditor.cancelConversion()
    await movieEditor.movieExportTask?.value
    equal(try Data(contentsOf: protectedOutput), originalOutput, "cancelling a movie export preserves an existing destination")
    let sourceAlias = scratch.appendingPathComponent("source-alias.mp4")
    try FileManager.default.createSymbolicLink(at: sourceAlias, withDestinationURL: nativeClip.url)
    movieEditor.startMovieExport(plan: moviePlan, output: sourceAlias)
    check(!movieEditor.isConverting, "movie export refuses a symlink to a source recording")

    print("\nSpeed, waveform and silence cleanup")
    let speedSegments = [TimelineSegment(start: 2, end: 3, speed: 2), TimelineSegment(start: 0, end: 1, speed: 0.5)]
    var speedTimeline = ClipTimeline(segments: speedSegments)
    check(abs(speedTimeline.duration - 2.5) < 0.00001, "section speeds determine edited duration")
    check(abs(speedTimeline.location(at: 0.25)!.source - 2.5) < 0.00001, "fast section maps timeline time to the right source frame")
    check(abs(speedTimeline.time(forSource: 0.5)! - 1.5) < 0.00001, "slow section maps source frames back to timeline time")
    let rightSpeedID = speedTimeline.split(at: 1.5, fps: 30)
    check(rightSpeedID != nil && speedTimeline.segments.last!.speed == 0.5, "splitting a retimed section preserves speed")
    check(abs(speedTimeline.duration - 2.5) < 0.00001, "splitting retimed footage preserves duration")
    let legacySection = Data("{\"id\":\"\(UUID().uuidString)\",\"start\":0,\"end\":1}".utf8)
    equal(try JSONDecoder().decode(TimelineSegment.self, from: legacySection).speed, 1, "older projects default to normal speed")
    let speedEditor = AppModel(recoveryURL: nil)
    speedEditor.restore(VideoProject(clips: [ProjectClip(nativeClip)], settings: ExportSettings(), selection: nativeClip.id))
    speedEditor.setSegmentSpeed(speedEditor.items[0].timeline.segments[0].id, speed: 2)
    equal(speedEditor.project.version, VideoProject.currentVersion,
          "projects with speed edits are written at the current version, never downgraded")
    let speedSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(speedEditor.project))
    try speedSaved.validate()
    equal(speedSaved.clips[0].segments![0].speed, 2, "project round trip retains section speed")
    speedEditor.undoEdit()
    equal(speedEditor.items[0].timeline.segments[0].speed, 1, "undo restores the previous speed")
    var invalidSpeed = speedSaved
    invalidSpeed.clips[0].segments![0].speed = 0
    check((try? invalidSpeed.validate()) == nil, "invalid project speeds are rejected")

    var speedClip = nativeClip; speedClip.segments = speedSegments
    let speedOutput = scratch.appendingPathComponent("speed.mp4")
    try await FFmpeg.export(input: colorSource, output: speedOutput, info: colorInfo, crop: colorInfo.fullFrame,
                            segments: speedSegments, settings: ExportSettings()) { _ in }
    equal(try await frameCount(speedOutput), 75, "fast and slow sections export the expected frame count")
    check(abs(try await FFmpeg.probe(url: speedOutput).duration - 2.5) < 0.05, "speed export audio and video end together")
    let speedRed = try await pixel(speedOutput, x: 100, y: 80, at: 0.65)
    check(speedRed.0 > 200 && speedRed.2 < 40, "retimed export cuts to the next section at the new boundary")
    check(abs(try await toneFrequency(speedOutput, at: 0.1) - 1320) < 25, "speeding up audio preserves pitch")
    check(abs(try await toneFrequency(speedOutput, at: 1.3) - 440) < 20, "slowing down audio preserves pitch")
    let speedPlayer = try await PlaybackController.makeItem(speedClip, settings: ExportSettings())
    check(abs(try await speedPlayer.asset.load(.duration).seconds - 2.5) < 0.001, "native playback uses the same retimed duration")
    let speedGenerator = AVAssetImageGenerator(asset: speedPlayer.asset)
    speedGenerator.videoComposition = speedPlayer.videoComposition
    let speedNative = try await speedGenerator.image(at: CMTime(seconds: 0.65, preferredTimescale: 600)).image
    let speedNativePixel = nativePixel(speedNative, x: 100, y: 80)
    check(speedNativePixel.0 > 200 && speedNativePixel.2 < 40, "native playback cuts at the retimed export boundary")
    let audioReader = try AVAssetReader(asset: speedPlayer.asset)
    let speedAudioTracks = try await speedPlayer.asset.loadTracks(withMediaType: .audio)
    let audioReaderOutput = AVAssetReaderAudioMixOutput(audioTracks: speedAudioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    audioReaderOutput.audioMix = speedPlayer.audioMix
    audioReader.add(audioReaderOutput)
    check(audioReader.startReading(), "native retimed audio can be decoded")
    var nativeAudio = Data()
    while let sample = audioReaderOutput.copyNextSampleBuffer() {
        if let buffer = CMSampleBufferGetDataBuffer(sample) {
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(buffer))
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            nativeAudio.append(contentsOf: bytes)
        }
    }
    check(audioReader.status == .completed && abs(Double(nativeAudio.count) / 16000 - 2.5) < 0.05, "native audio matches the retimed movie length")
    let nativeSamples = nativeAudio.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let pitchRange = Array(nativeSamples.dropFirst(9600).prefix(1600))
    let crossings = zip(pitchRange, pitchRange.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
    check(abs(Double(crossings) * 8000 / Double(max(1, pitchRange.count)) - 440) < 25, "native slowed audio preserves pitch too")

    var speedMarker = nativeMarker
    speedMarker.segments = [TimelineSegment(start: 0, end: 3, speed: 2)]
    speedMarker.zoomShots = [ZoomShot(start: 0, hold: 0.5, level: 2, target: CGPoint(x: 930, y: 530))]
    let speedMoviePlan = try MoviePlan(items: [speedClip, speedMarker], movieSettings: MovieSettings(), settings: ExportSettings())
    let speedMovieFile = scratch.appendingPathComponent("speed-movie.mp4")
    try await FFmpeg.exportMovie(plan: speedMoviePlan, settings: ExportSettings(), output: speedMovieFile) { _ in }
    equal(try await frameCount(speedMovieFile), 120, "movie assembly combines speed edits and zoom without duration drift")
    var speedGIFSettings = ExportSettings(); speedGIFSettings.format = .gif
    let speedGIFFile = scratch.appendingPathComponent("speed.gif")
    try await FFmpeg.export(input: markerClip, output: speedGIFFile, info: markerInfo, crop: speedMarker.crop!,
        zoomShots: speedMarker.zoomShots, segments: speedMarker.segments, settings: speedGIFSettings) { _ in }
    check(abs(try await frameCount(speedGIFFile) - 23) <= 1, "GIF frame thinning remains correct after speed and zoom")

    let pauseFile = scratch.appendingPathComponent("pauses.mp4")
    let pauseResult = try await Shell.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=30:d=6",
        "-f", "lavfi", "-i", "aevalsrc='if(between(t,2,4),0,0.3*sin(2*PI*440*t))':s=48000:d=6",
        "-c:v", "libx264", "-c:a", "aac", "-shortest", pauseFile.path])
    equal(pauseResult.status, 0, "created speech-like audio with a known two-second pause")
    let overview = try await AudioAnalyzer.analyze(pauseFile)
    check(overview.levels.count >= 119 && overview.levels.count <= 121, "streamed waveform includes the complete audio timeline")
    check(overview.levels.filter { $0.time > 0.2 && $0.time < 1.8 }.allSatisfy { $0.decibels > -25 }, "waveform detects audible sections")
    check(overview.levels.filter { $0.time > 2.2 && $0.time < 3.8 }.allSatisfy { $0.decibels < -60 }, "waveform detects the silent middle section")
    var pauseClip = VideoItem(url: pauseFile); pauseClip.info = try await FFmpeg.probe(url: pauseFile)
    let pauseCuts = overview.cuts(in: pauseClip.timeline, fps: 30, threshold: -40, minimum: 0.8, padding: 0.15)
    equal(pauseCuts.count, 1, "silence review proposes the known pause")
    if let cut = pauseCuts.first {
        check(cut.start >= 2.1 && cut.end <= 3.9, "silence cuts retain padding on both sides of speech")
        let cleaned = pauseClip.timeline.removing(pauseCuts)
        equal(cleaned.segments.count, 2, "applying a silence cut creates two retained sections")
        check(abs(cleaned.duration + cut.duration - 6) < 0.001, "removed silence has the exact reported duration")
        let cleanupEditor = AppModel(recoveryURL: nil)
        cleanupEditor.restore(VideoProject(clips: [ProjectClip(pauseClip)], settings: ExportSettings(), selection: pauseClip.id))
        cleanupEditor.commitTimeline(cleaned, name: "Remove Silence", selection: cleaned.segments.first?.id)
        cleanupEditor.undoEdit()
        equal(cleanupEditor.items[0].timeline.duration, 6, "one undo restores all proposed silence cuts")
        var excluded = pauseCuts; excluded[0].included = false
        equal(pauseClip.timeline.removing(excluded), pauseClip.timeline, "unchecked cuts leave the timeline unchanged")
        let retimedPauses = ClipTimeline(segments: [TimelineSegment(start: 0, end: 6, speed: 2)])
        let retimedCuts = overview.cuts(in: retimedPauses, fps: 30, threshold: -40, minimum: 0.8, padding: 0.15)
        check(abs(retimedCuts[0].duration * 2 - cut.duration) < 0.001, "silence savings reflect section speed")
        equal(retimedPauses.removing(retimedCuts).segments.last!.speed, 2, "silence removal preserves retained section speeds")
        check(overview.cuts(in: cleaned, fps: 30, threshold: -40, minimum: 0.8, padding: 0.15).isEmpty,
              "removed pauses are not suggested again")
    }
    let stereoFile = scratch.appendingPathComponent("opposite-phase.wav")
    _ = try await Shell.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i",
        "aevalsrc='0.3*sin(2*PI*440*t)|-0.3*sin(2*PI*440*t)':s=48000:d=1", stereoFile.path])
    let stereoOverview = try await AudioAnalyzer.analyze(stereoFile)
    check(stereoOverview.levels.allSatisfy { $0.decibels > -25 }, "opposite-phase stereo is not incorrectly classified as silence")

    // Many fractional frame boundaries must round cumulatively instead of drifting.
    let fractionalSections = (0..<30).map { i in
        TimelineSegment(start: Double(i) / 10, end: Double(i + 1) / 10, speed: 1.25)
    }
    let fractionalOutput = scratch.appendingPathComponent("fractional-speed.mp4")
    try await FFmpeg.export(input: colorSource, output: fractionalOutput, info: colorInfo, crop: colorInfo.fullFrame,
        segments: fractionalSections, settings: ExportSettings()) { _ in }
    equal(try await frameCount(fractionalOutput), 72, "thirty fractional-frame speed sections do not accumulate duration drift")
    check(abs(try await FFmpeg.probe(url: fractionalOutput).duration - 2.4) < 0.04, "many speed edits keep the audio and video clocks aligned")
    var tinyTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 0.2, speed: 4)])
    check(tinyTimeline.split(at: 0.025, fps: 30) == nil, "splitting cannot create a section shorter than one output frame")
    for extreme in [0.25, 4.0] {
        let extremeOutput = scratch.appendingPathComponent("speed-\(extreme).mp4")
        try await FFmpeg.export(input: colorSource, output: extremeOutput, info: colorInfo, crop: colorInfo.fullFrame,
            segments: [TimelineSegment(start: 0, end: 1, speed: extreme)], settings: ExportSettings()) { _ in }
        check(abs(Double(try await frameCount(extremeOutput)) - 30 / extreme) <= 0.5, "\(extreme)× speed produces the expected duration")
    }

}
