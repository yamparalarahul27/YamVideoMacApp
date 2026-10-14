// Renders YamVideo's real views offscreen to PNGs, for checking layout without a person
// at the screen and for screenshots in reviews. Nothing is captured from the display:
// each view draws itself into a bitmap.
//
//   Tools/Snapshot/snapshot.sh RECORDING OUTPUT_DIR
//
// Built from every app source except App.swift (the app's entry point) plus this file.

import AppKit
import SwiftUI

@MainActor
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
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
func render<V: View>(_ view: V, size: CGSize, to url: URL) {
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
    pump(1.5)
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
    model.setPreviewFraction(0.3)
    model.splitAtPlayhead()
    model.addZoom(at: CGPoint(x: info.width / 2, y: info.height / 2))
    model.addRegion(CGRect(x: 40, y: 40, width: info.width / 5, height: info.height / 6))
    // An agent's step, so the activity list and the highlight have something to show.
    _ = model.perform([.setSectionSpeed(clip: id, section: model.items[0].timeline.segments[1].id, speed: 1.5)],
                      label: "Speed up the ending", origin: .agent("Claude"), expectedRevision: model.revision)
    model.agentClients = [AgentClient(name: "Claude", lastSeen: Date(), lastAction: "Speed up the ending"),
                          AgentClient(name: "Codex", lastSeen: Date().addingTimeInterval(-600), lastAction: "state")]
    pump(1.5)

    let size = CGSize(width: 1360, height: 880)
    let window = { ContentView().environmentObject(model).frame(width: size.width, height: size.height) }

    model.selectedShotID = nil; model.selectedRegionID = nil
    model.selectedSegmentID = model.items[0].timeline.segments[0].id
    render(window(), size: size, to: output.appendingPathComponent("1-section.png"))

    model.agentHighlight = nil
    model.editorMode = .zoom
    model.selectedShotID = model.items[0].zoomShots.first?.id
    render(window(), size: size, to: output.appendingPathComponent("2-zoom.png"))

    model.editorMode = .blur
    model.selectedRegionID = model.items[0].blurRegions.first?.id
    render(window(), size: size, to: output.appendingPathComponent("3-blur-area.png"))

    model.editorMode = .crop
    model.selectedSegmentID = nil; model.selectedShotID = nil; model.selectedRegionID = nil
    render(window(), size: size, to: output.appendingPathComponent("4-recording.png"))

    render(ExportSheet(scope: .selected).environmentObject(model), size: CGSize(width: 520, height: 640),
           to: output.appendingPathComponent("5-export-sheet.png"))
    render(AgentActivityView().environmentObject(model).frame(width: 400), size: CGSize(width: 400, height: 520),
           to: output.appendingPathComponent("6-local-agents.png"))

    model.setMovieMode(true)
    pump(1)
    render(window(), size: size, to: output.appendingPathComponent("7-movie.png"))

    let minimum = CGSize(width: 1140, height: 800)
    model.setMovieMode(false)
    render(ContentView().environmentObject(model).frame(width: minimum.width, height: minimum.height), size: minimum,
           to: output.appendingPathComponent("8-minimum-size.png"))
}

Task { @MainActor in
    do { try await run() } catch { print("snapshot failed: \(error)") }
    exit(0)
}
RunLoop.main.run()
