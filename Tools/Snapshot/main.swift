// Renders YamVideo's real views offscreen to PNGs, for checking layout without a person
// at the screen and for screenshots in reviews. Nothing is captured from the display:
// each view draws itself into a bitmap.
//
//   Tools/Snapshot/snapshot.sh RECORDING OUTPUT_DIR
//
// Built from every app source except App.swift (the app's entry point) plus this file.

import AppKit
import SwiftUI

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

    model.selectedShotID = nil; model.selectedRegionID = nil
    model.selectedSegmentID = model.items[0].timeline.segments[0].id
    await render(window(), size: size, to: output.appendingPathComponent("1-section.png"))

    // Two of three sections, at different speeds.
    let sections = model.items[0].timeline.segments
    model.clickSegment(sections[1].id, at: model.items[0].timeline.offset(of: sections[1].id), extend: true)
    await render(window(), size: size, to: output.appendingPathComponent("1b-sections.png"))

    model.agentHighlight = nil
    model.editorMode = .zoom
    model.selectedShotID = model.items[0].zoomShots.first?.id
    await render(window(), size: size, to: output.appendingPathComponent("2-zoom.png"))

    model.editorMode = .blur
    model.selectedRegionID = model.items[0].blurRegions.first?.id
    await render(window(), size: size, to: output.appendingPathComponent("3-blur-area.png"))

    model.editorMode = .crop
    model.selectedSegmentID = nil; model.selectedShotID = nil; model.selectedRegionID = nil
    await render(window(), size: size, to: output.appendingPathComponent("4-recording.png"))

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
    // The thumbnail maker: the first render cuts the speaker out, the second shows it. Its
    // live previews are web views, which this tool cannot capture in a sheet of its own.
    var made = model.items[0]
    var makerDesign = ThumbnailDesign(time: min(1, length / 2), title: "Edit for the *viewer*")
    makerDesign.tag = "3 rules"
    made.publish?.design = makerDesign
    await render(ThumbnailMakerSheet(item: made, playhead: 1).environmentObject(model), size: CGSize(width: 1060, height: 720),
           to: output.appendingPathComponent("5h-thumbnail-maker.png"))
    await pump(1)
    await render(ThumbnailMakerSheet(item: made, playhead: 1).environmentObject(model), size: CGSize(width: 1060, height: 720),
           to: output.appendingPathComponent("5h-thumbnail-maker.png"))
    model.undo()
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
    model.colorComparison = .split
    await pump(3)
    await render(window(), size: size, to: output.appendingPathComponent("11-compare.png"))
    await render(ContentView().environmentObject(model).frame(width: minimum.width, height: minimum.height), size: minimum,
           to: output.appendingPathComponent("12-compare-minimum.png"))

    // Effects mode: a blur selected at its hold, with two named markers in the ruler.
    model.colorComparison = .corrected
    model.setPreviewFraction(1.0 / max(1, model.items[0].editedDuration))
    model.addMarkerAtPlayhead()
    if let marker = model.selectedMarkerID { model.updateMarker(marker) { $0.label = "Intro ends"; $0.color = .green } }
    model.setPreviewFraction(6.0 / max(1, model.items[0].editedDuration))
    model.addMarkerAtPlayhead()
    model.setPreviewFraction(4.0 / max(1, model.items[0].editedDuration))
    model.addBlurEffect()
    model.editorMode = .effects
    if let effect = model.selectedEffect { model.jumpToEffect(effect) }
    await pump(3)
    await render(window(), size: size, to: output.appendingPathComponent("13-effects.png"))
    await render(ContentView().environmentObject(model).frame(width: minimum.width, height: minimum.height), size: minimum,
           to: output.appendingPathComponent("14-effects-minimum.png"))
    if let marker = model.selectedItem?.markers.first { model.selectMarker(marker) }
    await pump(1)
    await render(InspectorPane().environmentObject(model).frame(width: inspector.width, height: inspector.height), size: inspector,
           to: output.appendingPathComponent("15-marker.png"))
}

Task { @MainActor in
    do { try await run() } catch { print("snapshot failed: \(error)") }
    exit(0)
}
RunLoop.main.run()
