// Renders YamVideo's real views offscreen to PNGs, for checking layout without a person
// at the screen and for screenshots in reviews. Nothing is captured from the display:
// each view draws itself into a bitmap.
//
//   Tools/Snapshot/snapshot.sh RECORDING OUTPUT_DIR
//
// Built from every app source except App.swift (the app's entry point) plus this file.

import AppKit
import AVKit
import SwiftUI

/// The player whose frame is drawn into its views: AVKit composites video outside the
/// layer tree, so a render of the layers alone leaves the picture black.
@MainActor var snapshotPlayer: PlaybackController?

/// The player views in a view tree, however deep.
@MainActor
func playerViews(in view: NSView) -> [AVPlayerView] {
    (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap(playerViews)
}

/// Waits by suspending, so the app's own main-actor work — a preview frame arriving
/// from ffmpeg — runs meanwhile, and the main run loop at the bottom of this file keeps
/// drawing. Spinning the run loop from inside this task would hold the main actor and
/// the frame would never land.
@MainActor
func pump(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// A real window, so SwiftUI lays out and draws its layers exactly as it would for a
/// person. Not constrained, so it can be any size.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The SwiftUI hosting views nested inside `view` — one per split-view pane — without
/// descending into them.
@MainActor
func hostingViews(in view: NSView) -> [NSView] {
    view.subviews.flatMap { child -> [NSView] in
        String(describing: type(of: child)).hasPrefix("NSHostingView") ? [child] : hostingViews(in: child)
    }
}

/// The thumbnail maker: the first render cuts the speaker out, the second shows it with
/// the phone check, then the same On a phone. Its live preview is a web view, which this
/// tool cannot capture in a sheet of its own; the phone views are pictures, so they show.
/// YAMVIDEO_SNAPSHOT_ONLY=thumbnail renders only these.
@MainActor
func thumbnailMaker(_ model: AppModel, output: URL) async {
    var made = model.items[0]
    var publish = made.publish ?? PublishInfo()
    if publish.title.isEmpty { publish.title = "How I edit talking-head videos on a Mac" }
    var design = ThumbnailDesign(time: min(1, made.editedDuration / 2), title: "Edit for the *viewer*")
    design.tag = "3 rules"
    publish.design = design
    made.publish = publish
    let size = CGSize(width: 1200, height: 720)
    UserDefaults.standard.set(false, forKey: "thumbnailOnPhone")
    await render(ThumbnailMakerSheet(item: made, playhead: 1).environmentObject(model), size: size,
           to: output.appendingPathComponent("5h-thumbnail-maker.png"))
    await pump(1)
    await render(ThumbnailMakerSheet(item: made, playhead: 1).environmentObject(model), size: size,
           to: output.appendingPathComponent("5h-thumbnail-maker.png"), settle: 12)
    UserDefaults.standard.set(true, forKey: "thumbnailOnPhone")
    await render(ThumbnailMakerSheet(item: made, playhead: 1).environmentObject(model), size: size,
           to: output.appendingPathComponent("5h-thumbnail-on-phone.png"), settle: 12)
    UserDefaults.standard.removeObject(forKey: "thumbnailOnPhone")
}

@MainActor
func render<V: View>(_ view: V, size: CGSize, to url: URL, settle: TimeInterval = 1.5) async {
    let host = NSHostingView(rootView: view)
    let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = host
    // On screen, so AppKit treats it as visible and SwiftUI draws it, but almost fully
    // transparent and click-through: it cannot be seen or get in the way.
    window.alphaValue = 0.01
    window.ignoresMouseEvents = true
    window.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero)
    window.orderFrontRegardless()
    await pump(settle)
    CATransaction.flush()
    let frame = window.contentView!.superview ?? host
    frame.layoutSubtreeIfNeeded()
    guard let layer = frame.layer else { print("no layer for \(url.lastPathComponent)"); return }
    let scale = window.backingScaleFactor
    let pixels = CGSize(width: frame.bounds.width * scale, height: frame.bounds.height * scale)
    guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    context.scaleBy(x: scale, y: scale)
    // The window server composites the translucent window background and the panes of a
    // split view, so the frame's own layer tree comes out blank there. Draw the frame
    // (title bar and toolbar), then each SwiftUI pane in its place on top.
    layer.render(in: context)
    let panes = hostingViews(in: host)
    if !panes.isEmpty {
        let content = host.convert(host.bounds, to: frame)
        context.setFillColor(window.effectiveAppearance.name == .darkAqua
                             ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.96, alpha: 1))
        context.fill(content)
        // Content outside the panes (the timeline, the status bar) belongs to the root view.
        if let rootLayer = host.layer {
            context.saveGState()
            context.translateBy(x: content.minX, y: host.isFlipped ? content.maxY : content.minY)
            if host.isFlipped { context.scaleBy(x: 1, y: -1) }
            rootLayer.render(in: context)
            context.restoreGState()
        }
        for pane in panes {
            guard let paneLayer = pane.layer, !pane.isHiddenOrHasHiddenAncestor else { continue }
            let rect = pane.convert(pane.bounds, to: frame)
            context.saveGState()
            // SwiftUI panes are flipped views: their layers draw top-down.
            if pane.isFlipped {
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
            } else {
                context.translateBy(x: rect.minX, y: rect.minY)
            }
            paneLayer.render(in: context)
            context.restoreGState()
        }
    }
    // The picture the player shows: the same composed frame, drawn where its view shows it.
    if let player = snapshotPlayer, player.player.currentItem != nil, let content = window.contentView {
        let views = playerViews(in: content).filter { !$0.isHiddenOrHasHiddenAncestor && $0.videoBounds.width > 1 }
        if !views.isEmpty, let picture = try? await player.composedFrame() {
            for view in views {
                context.draw(picture, in: view.convert(view.videoBounds, to: frame))
            }
        }
    }
    window.orderOut(nil)
    guard let image = context.makeImage() else { return }
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path)")
}

@MainActor
func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { print("usage: snapshot RECORDING OUTPUT_DIR"); exit(2) }
    let recording = URL(fileURLWithPath: arguments[1])
    let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    NSApplication.shared.setActivationPolicy(.accessory)
    let model = AppModel(recoveryURL: nil)
    snapshotPlayer = model.playback
    let info = try await FFmpeg.probe(url: recording)
    var clip = ProjectClip(VideoItem(url: recording))
    clip.info = info; clip.crop = info.fullFrame
    model.restore(VideoProject(clips: [clip], settings: ExportSettings(), selection: clip.id))
    let id = model.items[0].id
    model.setPreviewFraction(0.75)
    model.splitAtPlayhead()
    model.setPreviewFraction(0.3)
    model.splitAtPlayhead()
    model.addZoom(at: CGPoint(x: info.width / 2, y: info.height / 2))
    model.addRegion(CGRect(x: 40, y: 40, width: info.width / 5, height: info.height / 6))
    // An agent's step, so the activity list and the highlight have something to show.
    _ = model.perform([.setSectionSpeed(clip: id, section: model.items[0].timeline.segments[1].id, speed: 1.5)],
                      label: "Speed up the ending", origin: .agent("Claude"), expectedRevision: model.revision)
    model.agentClients = [AgentClient(name: "Claude", lastSeen: Date(), lastAction: "Speed up the ending"),
                          AgentClient(name: "Codex", lastSeen: Date().addingTimeInterval(-600), lastAction: "state")]
    await pump(1.5)

    let size = CGSize(width: 1360, height: 880)
    let window = { ContentView().environmentObject(model).frame(width: size.width, height: size.height) }
    // YAMVIDEO_SNAPSHOT_ONLY=ideas renders only the Library pages; =studio only the Studio
    // pictures up to 4-recording.png, which the redesign tracker uses; =thumbnail only the
    // thumbnail maker.
    let only = ProcessInfo.processInfo.environment["YAMVIDEO_SNAPSHOT_ONLY"]
    // For the tracker's Studio pictures, captions on the Captions track: an SRT's words
    // spread over its captions' times, as sample words for the recording.
    if only == "studio", let path = ProcessInfo.processInfo.environment["YAMVIDEO_SNAPSHOT_CAPTIONS"],
       let text = try? String(contentsOfFile: path, encoding: .utf8), let parsed = try? Captions.parse(text) {
        let sample = parsed.flatMap { caption -> [TranscriptWord] in
            let parts = caption.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let step = (caption.end - caption.start) / Double(max(1, parts.count))
            return parts.enumerated().map { TranscriptWord(text: $1, start: caption.start + Double($0) * step, end: caption.start + Double($0 + 1) * step) }
        }.filter { $0.end <= info.duration }
        _ = model.perform([.setTranscript(clip: model.items[0].id, transcript: Transcript(model: "sample", language: "en", words: sample))])
    }
    if only == "ideas" {
        try await ideas(model, output: output, size: size, minimum: CGSize(width: 1140, height: 800))
        return
    }
    if only == "thumbnail" {
        await thumbnailMaker(model, output: output)
        return
    }

    model.selectedShotID = nil; model.selectedRegionID = nil
    model.selectedSegmentID = model.items[0].timeline.segments[0].id
    await render(window(), size: size, to: output.appendingPathComponent("1-section.png"))

    // Two of three sections, at different speeds.
    let sections = model.items[0].timeline.segments
    model.clickSegment(sections[1].id, at: model.items[0].timeline.offset(of: sections[1].id), extend: true)
    await render(window(), size: size, to: output.appendingPathComponent("1b-sections.png"))

    model.agentHighlight = nil
    // The picture's edits: aiming a zoom, the blur areas and the crop, each on the frame.
    model.selectedShotID = model.items[0].zoomShots.first?.id
    model.beginZoomAim()
    await render(window(), size: size, to: output.appendingPathComponent("2-zoom.png"))

    model.beginBlurAreas()
    await render(window(), size: size, to: output.appendingPathComponent("3-blur-area.png"))

    model.beginCrop()
    if let square = AspectPreset.all.first(where: { $0.label == "4:5" }) { model.setCropDraftAspect(square) }
    await render(window(), size: size, to: output.appendingPathComponent("3c-crop.png"))
    model.cancelCropDraft()

    model.selectedSegmentID = nil; model.selectedShotID = nil; model.selectedRegionID = nil
    model.endPictureEdit()
    await render(window(), size: size, to: output.appendingPathComponent("4-recording.png"))
    // A change switched off: the zooms stay in the project, out of the video.
    model.setChange(.zooms, on: false)
    model.inspectorFocus = .recording
    await render(window(), size: size, to: output.appendingPathComponent("4b-change-off.png"))
    model.undo()
    if only == "studio" {
        // The Media panel's Graphics tab, and a caption selected on the Captions track.
        UserDefaults.standard.set("graphics", forKey: "mediaPanelTab")
        await render(window(), size: size, to: output.appendingPathComponent("4c-media-graphics.png"))
        UserDefaults.standard.set("media", forKey: "mediaPanelTab")
        if model.selectedItem?.transcript != nil {
            model.selectedCaptionIndex = 3
            if let cue = model.selectedCaption { model.setPreviewFraction(cue.start / max(1, model.items[0].editedDuration)) }
            await render(window(), size: size, to: output.appendingPathComponent("4d-caption.png"))
        }
        return
    }

    await render(ExportSheet(scope: .selected).environmentObject(model), size: CGSize(width: 520, height: 640),
           to: output.appendingPathComponent("5-export-sheet.png"))
    // The Graphics section, taller so it is in view: HyperFrames ready, then not downloaded.
    let clipLength = model.items[0].editedDuration
    _ = model.perform([.replaceGraphics(clip: model.items[0].id, graphics: [
        Graphic(kind: .namePlate, start: 0, end: min(1, clipLength / 2),
                props: ["kicker": .string("Yamparala Media"), "title": .string("Yamparala Rahul"), "detail": .string("UX Design Engineer")]),
        Graphic(kind: .rule, start: min(1, clipLength / 2), end: clipLength)], style: nil)])
    await render(ExportSheet(scope: .selected).environmentObject(model), size: CGSize(width: 520, height: 900),
           to: output.appendingPathComponent("5b-export-graphics.png"))
    // A graphic selected on the Preview picture, moved and scaled, and its inspector.
    model.selectedGraphicID = model.items[0].graphics?.items.first?.id
    if let id = model.selectedGraphicID { model.placeGraphic(id, GraphicTransform(x: -700, y: 400, scale: 1.3)) }
    model.setPlaybackVisible(true)
    model.setPreviewFraction(min(0.6, clipLength / 4) / clipLength)
    // The first render builds the Preview, whose engine measures the graphics; the second
    // shows the selection box from those measurements.
    await render(window(), size: size, to: output.appendingPathComponent("5d-graphic-on-picture.png"))
    await pump(2)
    await render(window(), size: size, to: output.appendingPathComponent("5d-graphic-on-picture.png"))
    await render(InspectorPane().environmentObject(model).frame(width: 340, height: 900), size: CGSize(width: 340, height: 900),
           to: output.appendingPathComponent("5e-graphic-inspector.png"))
    model.setPlaybackVisible(false)
    model.undo()
    setenv("YAMVIDEO_HYPERFRAMES_DIR", NSTemporaryDirectory() + "yamvideo-no-hyperframes", 1)
    await render(ExportSheet(scope: .selected).environmentObject(model), size: CGSize(width: 520, height: 900),
           to: output.appendingPathComponent("5c-export-graphics-download.png"))
    unsetenv("YAMVIDEO_HYPERFRAMES_DIR")
    model.undo()
    // Publish: details with one chapter too short, a frame as the thumbnail, both previews.
    var details = PublishInfo()
    details.title = "How I edit talking-head videos on a Mac"
    details.description = "My whole edit, start to finish: cuts, colour, graphics and the export.\n\nGear and links below."
    details.tags = ["video editing", "macOS", "YamVideo"]
    details.channel = "Yamparala Media"
    let length = model.items[0].editedDuration
    details.chapters = [Chapter(time: 0, title: "Intro"), Chapter(time: min(2, length / 2), title: "Cutting")]
    let frameFile = output.appendingPathComponent("publish-thumbnail.png")
    if let preview = model.previewImage, let tiff = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: frameFile)
        details.thumbnail = frameFile
    }
    _ = model.perform([.setPublishInfo(clip: model.items[0].id, info: details)])
    await render(PublishSheet().environmentObject(model), size: CGSize(width: 1080, height: 760),
           to: output.appendingPathComponent("5f-publish-watch-page.png"))
    await render(PublishSheet(initialPreview: 1).environmentObject(model), size: CGSize(width: 1080, height: 760),
           to: output.appendingPathComponent("5g-publish-search-result.png"))
    await thumbnailMaker(model, output: output)
    // The end screen: the speaker in a frame beside YouTube's boxes, on the timeline and in
    // the inspector, and the choice of element for each box (from Publish).
    if length >= EndScreen.lengths.lowerBound {
        model.addEndScreen()
        var choices = EndScreenElements()
        choices.videos[0] = EndScreenElements.Video(kind: .video, link: "https://youtu.be/abc123", title: "Part 2")
        model.setPublish(label: "End Screen") { $0.endScreen = choices }
        model.setPlaybackVisible(true)
        model.setPreviewFraction(max(0, length - 0.5) / length)
        await render(window(), size: size, to: output.appendingPathComponent("5i-end-screen.png"))
        await pump(2)
        await render(window(), size: size, to: output.appendingPathComponent("5i-end-screen.png"))
        await render(InspectorPane().environmentObject(model).frame(width: 340, height: 900), size: CGSize(width: 340, height: 900),
               to: output.appendingPathComponent("5j-end-screen-inspector.png"))
        model.setPlaybackVisible(false)
        await render(PublishEndScreenSection(item: model.items[0], publish: model.items[0].publish ?? PublishInfo())
                        .environmentObject(model).padding(18).frame(width: 430), size: CGSize(width: 430, height: 520),
               to: output.appendingPathComponent("5k-publish-end-screen.png"))
        model.undo(); model.undo()
    }
    // A Short: the viewer at 9:16 with a bottom-sheet panel, YouTube's buttons and captions
    // stepping up above it; the inspector's Short section; and Publish for the Short.
    let shortWords = (0..<24).map { index in
        TranscriptWord(text: ["Here", "is", "the", "first", "rule,", "and", "why", "it", "matters", "for", "every", "video."][index % 12],
                       start: Double(index) / 24 * length * 0.95, end: Double(index + 1) / 24 * length * 0.95)
    }
    _ = model.perform([.setTranscript(clip: model.items[0].id, transcript: Transcript(model: "base.en", language: "en", words: shortWords)),
                       .replaceGraphics(clip: model.items[0].id, graphics: [
                           Graphic(kind: .namePlate, start: 0, end: length * 0.3,
                                   props: ["kicker": .string("Yamparala Media"), "title": .string("Yamparala Rahul"), "detail": .string("UX Design Engineer")]),
                           Graphic(kind: .rule, start: length * 0.35, end: length * 0.9,
                                   props: ["kicker": .string("Rule"), "number": .string("01"), "title": .string("Cut every pause"),
                                           "points": .array([.object(["text": .string("Viewers leave in the gaps"), "at": .number(0.8)]),
                                                             .object(["text": .string("Tight, not rushed"), "at": .number(1.4)])])])], style: nil)])
    var shortSettings = model.settings; shortSettings.captions = .burnIn
    model.updateSettings(shortSettings)
    model.setPreviewFraction(0.5)
    model.addShortAtPlayhead()
    if let short = model.selectedShort {
        model.updateShort(short.id, label: "Short Title") { $0.title = "Cut every pause"; $0.tags = ["editing", "shorts"]; $0.cover = length * 0.6 }
        model.setPreviewFraction(0.62)
        model.setViewer(.short)
        await render(window(), size: size, to: output.appendingPathComponent("5o-short-viewer.png"))
        await pump(2.5)
        await render(window(), size: size, to: output.appendingPathComponent("5o-short-viewer.png"))
        await render(InspectorPane().environmentObject(model).frame(width: 340, height: 1300), size: CGSize(width: 340, height: 1300),
               to: output.appendingPathComponent("5p-short-inspector.png"))
        await render(PublishSheet().environmentObject(model), size: CGSize(width: 1080, height: 760),
               to: output.appendingPathComponent("5q-publish-short.png"))
        await pump(2)
        await render(PublishSheet().environmentObject(model), size: CGSize(width: 1080, height: 760),
               to: output.appendingPathComponent("5q-publish-short.png"))
        model.updateShort(short.id, label: "Short Panels") { $0.panels = .split }
        await pump(2.5)
        await render(window(), size: size, to: output.appendingPathComponent("5r-short-split.png"))
        // Zoomed out: the picture at the top over a blurred copy, the cards and captions lower.
        model.updateShort(short.id, label: "Short Zoom") { $0.panels = .sheet; $0.zoom = 0.75 }
        model.setPreviewFraction(0.2)
        await pump(2.5)
        await render(window(), size: size, to: output.appendingPathComponent("5s-short-zoom.png"))
        await render(InspectorPane().environmentObject(model).frame(width: 340, height: 1300), size: CGSize(width: 340, height: 1300),
               to: output.appendingPathComponent("5t-short-zoom-inspector.png"))
        model.setViewer(.preview)
        model.undo()
    }
    model.undo(); model.undo(); model.undo(); model.undo(); model.undo()
    model.undo()
    // Auto Edit: the answers with the recording transcribed, the review list with stumbles,
    // and the inspector's captions from the transcript.
    let spoken = ["Hello", "and", "welcome.", "Um,", "today", "I", "want", "to", "to", "show", "you", "how", "I", "edit", "my", "videos."]
    let words = (0..<spoken.count).map { index in
        TranscriptWord(text: spoken[index], start: Double(index) / Double(spoken.count) * length * 0.9,
                       end: Double(index + 1) / Double(spoken.count) * length * 0.9)
    }
    _ = model.perform([.setTranscript(clip: model.items[0].id, transcript: Transcript(model: "base.en", language: "en", words: words))])
    model.setAutoEditOptions { $0.cutStyle = .review; $0.captions = .burnIn }
    model.autoEditMessage = "Cut 12 pauses and 3 stumbles, 0:41 shorter. Captions: Burn in and SRT. Loudness: -14 LUFS, -1 dBTP."
    await render(AutoEditSheet().environmentObject(model), size: CGSize(width: 540, height: 680),
           to: output.appendingPathComponent("5l-auto-edit.png"))
    model.autoEditMessage = nil
    if let plan = try? await model.planAutoEdit(model.items[0].id, options: model.autoEditOptions), let overview = plan.overview {
        await render(SilenceReviewView(clip: model.items[0], overview: overview, stumbles: plan.stumbles, initialRule: plan.style.pauses,
                                       includeStumbles: true, plan: plan).environmentObject(model),
               size: CGSize(width: 610, height: 625), to: output.appendingPathComponent("5m-auto-edit-review.png"))
    }
    model.selectedSegmentID = nil; model.selectedShotID = nil; model.selectedRegionID = nil
    await render(InspectorPane().environmentObject(model).frame(width: 340, height: 1100), size: CGSize(width: 340, height: 1100),
           to: output.appendingPathComponent("5n-captions-inspector.png"))
    model.undo(); model.undo()
    await render(AgentActivityView().environmentObject(model).frame(width: 400), size: CGSize(width: 400, height: 520),
           to: output.appendingPathComponent("6-local-agents.png"))

    model.setMovieMode(true)
    await pump(1)
    await render(window(), size: size, to: output.appendingPathComponent("7-movie.png"))

    let minimum = CGSize(width: 1140, height: 800)
    model.setMovieMode(false)
    await render(ContentView().environmentObject(model).frame(width: minimum.width, height: minimum.height), size: minimum,
           to: output.appendingPathComponent("8-minimum-size.png"))

    // Colour: D-Log M chosen before any conversion is imported, then Natural colour
    // with adjustments, then the comparison. DJI's table when YAMVIDEO_DJI_LUT names
    // it; otherwise a stand-in, which is all a layout check needs.
    let inspector = CGSize(width: 340, height: 1500)
    model.selectedSegmentID = nil; model.selectedShotID = nil; model.selectedRegionID = nil
    model.setInputProfile(.pocket3DLogM)
    await pump(0.5)
    await render(InspectorPane().environmentObject(model).frame(width: inspector.width, height: inspector.height), size: inspector,
           to: output.appendingPathComponent("9-colour-setup.png"))
    let table: URL
    if let dji = ProcessInfo.processInfo.environment["YAMVIDEO_DJI_LUT"], !dji.isEmpty {
        table = URL(fileURLWithPath: dji)
    } else {
        table = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-conversion.cube")
        let lifted = ColorCube.build(size: 17) { p in p * p * (3 - 2 * p) * 0.9 + 0.05 }
        try Data(lifted.cubeText(title: "snapshot").utf8).write(to: table)
    }
    model.applyNaturalColor(try LUTStore.importTable(at: table, role: .pocket3DLogMToRec709))
    model.setColorAdjustments(ColorAdjustments(exposureEV: 0.3, warmth: 0.2, contrast: 1.1, saturation: 1.15))
    await pump(2)
    await render(InspectorPane().environmentObject(model).frame(width: inspector.width, height: inspector.height), size: inspector,
           to: output.appendingPathComponent("10-colour.png"))
    model.beginPictureEdit(.colourCompare)
    await pump(3)
    await render(window(), size: size, to: output.appendingPathComponent("11-compare.png"))
    await render(ContentView().environmentObject(model).frame(width: minimum.width, height: minimum.height), size: minimum,
           to: output.appendingPathComponent("12-compare-minimum.png"))

    // Effects mode: a blur selected at its hold, with two named markers in the ruler.
    model.endPictureEdit()
    model.setPreviewFraction(1.0 / max(1, model.items[0].editedDuration))
    model.addMarkerAtPlayhead()
    if let marker = model.selectedMarkerID { model.updateMarker(marker) { $0.label = "Intro ends"; $0.color = .green } }
    model.setPreviewFraction(6.0 / max(1, model.items[0].editedDuration))
    model.addMarkerAtPlayhead()
    model.setPreviewFraction(4.0 / max(1, model.items[0].editedDuration))
    model.addBlurEffect()
    if let effect = model.selectedEffect { model.jumpToEffect(effect) }
    await pump(3)
    await render(window(), size: size, to: output.appendingPathComponent("13-effects.png"))
    await render(ContentView().environmentObject(model).frame(width: minimum.width, height: minimum.height), size: minimum,
           to: output.appendingPathComponent("14-effects-minimum.png"))
    if let marker = model.selectedItem?.markers.first { model.selectMarker(marker) }
    await pump(1)
    await render(InspectorPane().environmentObject(model).frame(width: inspector.width, height: inspector.height), size: inspector,
           to: output.appendingPathComponent("15-marker.png"))
    try await ideas(model, output: output, size: size, minimum: minimum)
}

/// The Library page (distribution plan, phase 1): empty, with ideas by stage, and Studio
/// showing the idea its project was made from. Its own Library, never the owner's.
@MainActor
func ideas(_ model: AppModel, output: URL, size: CGSize, minimum: CGSize) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yamvideo-snapshot-library-\(UUID().uuidString)")
    model.loadLibrary(from: folder)
    model.showModule(.library)
    let window = { ContentView().environmentObject(model).frame(width: size.width, height: size.height) }
    await pump(1)
    await render(window(), size: size, to: output.appendingPathComponent("16a-ideas-empty.png"))

    let claude = ContentItem(title: "How I edit with Claude", notes: "Hook: one recording, and Claude cuts it while I watch.\n\nShow the bridge, Auto Edit and the Shorts it makes. End on the Library page.",
                             topic: "AI workflow", links: ["https://www.youtube.com/watch?v=example", "https://claude.com/claude-code"])
    let items = [
        ContentItem(title: "YamDrive design system walkthrough", notes: "Screen + speaker. Tokens, components, the docs site.", topic: "Design systems"),
        ContentItem(title: "Shorts safe area explained", topic: "YouTube tips"),
        ContentItem(title: "Pocket 3 colour in five minutes", notes: "D-Log M to Rec.709 with DJI's LUT, then Natural colour.", topic: "Gear"),
        claude,
    ]
    for item in items { model.performLibrary([.addIdea(item)]) }
    // Two reference images, drawn here.
    var images: [URL] = []
    for (index, hue) in [0.62, 0.08].enumerated() {
        let url = folder.appendingPathComponent("reference-\(index).png")
        let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill(); rect.fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 120, dy: 90), xRadius: 24, yRadius: 24).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: url); images.append(url)
        }
    }
    model.addIdeaImages(images, to: claude.id)
    // The open project belongs to the design system idea.
    let projectFile = folder.appendingPathComponent("YamDrive design system walkthrough.yamvideo")
    model.save(to: projectFile, asCopy: false)
    model.performLibrary([.linkProject(id: items[0].id, link: ProjectLink(projectID: model.projectID, path: projectFile.path))])
    model.performLibrary([.updateIdea(id: items[2].id, title: nil, notes: "Before and after on the same frame.", topic: nil, links: nil)],
                         label: "Sharpen the Pocket 3 idea", origin: .agent("Claude"), expectedRevision: model.library.revision)
    model.selectedIdeaID = claude.id
    model.showModule(.library)
    await pump(1.5)
    await render(window(), size: size, to: output.appendingPathComponent("16b-ideas.png"))
    await render(ContentView().environmentObject(model).frame(width: minimum.width, height: minimum.height), size: minimum,
           to: output.appendingPathComponent("16c-ideas-minimum.png"))
    model.selectedIdeaID = items[0].id
    await pump(1)
    await render(window(), size: size, to: output.appendingPathComponent("16d-idea-in-production.png"))
    model.showModule(.studio)
    await pump(1.5)
    await render(window(), size: size, to: output.appendingPathComponent("16e-studio-with-idea.png"))

    // Past videos: a saved project with three Shorts, two exported before, one posted.
    let past = folder.appendingPathComponent("DJIFootage", isDirectory: true)
    let shortsFolder = past.appendingPathComponent("Shorts", isDirectory: true)
    try FileManager.default.createDirectory(at: shortsFolder, withIntermediateDirectories: true)
    var project = model.project
    project.projectID = UUID()
    let titles = ["App Store tip: use only assets you own", "The one thing AI won't do for your app: accessibility", "3 things to check before you publish"]
    let shorts = titles.enumerated().map { index, title -> Short in
        var short = Short(start: Double(index) * 3, end: Double(index) * 3 + 2.5); short.title = title; return short
    }
    project.clips[0].shorts = shorts
    try JSONEncoder().encode(project).write(to: past.appendingPathComponent("AppStore.yamvideo"))
    for (index, short) in shorts.prefix(2).enumerated() {
        let stem = PublishInfo.fileStem(short.title, fallback: "Short")
        let cover = NSImage(size: NSSize(width: 270, height: 480), flipped: false) { rect in
            NSColor(hue: [0.58, 0.95][index], saturation: 0.5, brightness: 0.8, alpha: 1).setFill(); rect.fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 85, y: 260, width: 100, height: 100)).fill()
            return true
        }
        if let tiff = cover.tiffRepresentation, let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]) {
            try jpeg.write(to: shortsFolder.appendingPathComponent(stem + " cover.jpg"))
        }
        try Data().write(to: shortsFolder.appendingPathComponent(stem + ".mp4"))
        let json: [String: Any] = ["short": true, "shortID": short.id.uuidString, "title": short.title, "description": "From the App Store video.",
                                   "tags": ["App Store", "iOS app"], "length": short.length,
                                   "files": ["video": stem + ".mp4", "cover": stem + " cover.jpg"]]
        try JSONSerialization.data(withJSONObject: json).write(to: shortsFolder.appendingPathComponent(stem + ".youtube.json"))
    }
    let candidates = LibraryScan.candidates(roots: [past], library: model.library)
    model.libraryScan = LibraryScanState(roots: [past], scanning: false, candidates: candidates,
                                         chosen: Set(candidates.filter { !$0.alreadyAdded }.map(\.path)))
    await render(PastVideosSheet().environmentObject(model), size: CGSize(width: 600, height: 480),
                 to: output.appendingPathComponent("16f-add-past-videos.png"))
    model.addChosenPastVideos()
    if let item = model.library.item(forProject: project.projectID!) {
        let rows = model.videoRows(item)
        if let posted = rows.first(where: { $0.id == shorts[1].id }) {
            model.addPost(item.id, posted, link: "https://youtube.com/shorts/example")
            if let again = model.videoRows(model.library.item(item.id)!).first(where: { $0.id == shorts[1].id }) {
                model.addPost(item.id, again, link: "https://www.instagram.com/reel/example/")
            }
        }
        model.selectedIdeaID = item.id
    }
    model.showModule(.library)
    await pump(1.5)
    await render(window(), size: size, to: output.appendingPathComponent("16g-past-video.png"))

    // Style.md and the project's notes.
    for (section, rule, source) in [("Every video", "Plain English: short sentences, one word for one thing.", "from the start"),
                                    ("Shorts", "Zoom out to 3:4 with the blurred bottom, so text sits under the face.", "feedback, 15 Oct"),
                                    ("Shorts", "Captions in YouTube's clear area, never over the face.", "15 Oct"),
                                    ("Graphics", "Glass look, accent yellow #F5C42C, shade panel.", "AppStore, 15 Oct")] {
        model.performLibrary([.addStyleRule(section: section, rule: rule, source: source)])
    }
    await render(StyleSheet().environmentObject(model), size: CGSize(width: 820, height: 600), to: output.appendingPathComponent("16h-style.png"))
    model.projectNotes = "- Kept the Nokia story whole: it is why the app exists. *(Claude, 15 Oct)*\n- Zoomed the Shorts out to 3:4 because the captions covered the face. *(You, 15 Oct)*"
    await render(ProjectNotesSheet().environmentObject(model), size: CGSize(width: 620, height: 460), to: output.appendingPathComponent("16i-project-notes.png"))
    try? FileManager.default.removeItem(at: folder)
}

Task { @MainActor in
    do { try await run() } catch { print("snapshot failed: \(error)") }
    exit(0)
}
RunLoop.main.run()
