import SwiftUI
import WebKit

/// What the preview needs to draw one recording's graphics.
struct GraphicsOverlayInput: Equatable {
    var clip: UUID
    var track: GraphicsTrack
    var duration: Double
    var fps: String
    /// The size of the picture the player shows, to fit the overlay to it.
    var frame: CGSize
    var time: Double
    /// A Short's burned-in captions, drawn over its graphics.
    var captions: CaptionOverlay? = nil
}

/// The recording's graphics over the player, drawn by the same engine as the export.
/// It loads the engine page once per recording; after that a playhead change only seeks
/// the engine's timeline, and an edit only hands it new data.
struct GraphicsOverlay: NSViewRepresentable {
    let input: GraphicsOverlayInput
    /// Each graphic's box on the picture, measured whenever the graphics are (re)built.
    var onBounds: ([UUID: GraphicBounds]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = PassThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.onBounds = onBounds
        context.coordinator.update(input)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onBounds = onBounds
        context.coordinator.update(input)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        var onBounds: ([UUID: GraphicBounds]) -> Void = { _ in }
        private var loaded: GraphicsOverlayInput?
        private var ready = false
        private var sentTime = -1.0
        private var pending: GraphicsOverlayInput?

        static func folder(for clip: UUID, canvas: GraphicsCanvas = .landscape) -> URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("YamVideo/GraphicsPreview/\(clip.uuidString)\(canvas == .landscape ? "" : "-short")", isDirectory: true)
        }

        private var sentCaptions: CaptionOverlay??

        func update(_ input: GraphicsOverlayInput) {
            guard let view else { return }
            pending = input
            // A different recording, or a change between the 16:9 video and a Short (a
            // different stage size), loads the page again.
            if loaded?.clip != input.clip || (loaded?.track.canvas == .landscape) != (input.track.canvas == .landscape) {
                ready = false; sentTime = -1; sentCaptions = nil
                do {
                    let folder = Self.folder(for: input.clip, canvas: input.track.canvas)
                    let index = try GraphicsEngine.writePage(input.track, duration: input.duration, fps: input.fps,
                                                             mode: "preview", to: folder)
                    view.loadFileURL(index, allowingReadAccessTo: folder)
                    loaded = input
                } catch {
                    loaded = nil
                }
                return
            }
            guard ready else { return }
            if sentCaptions != .some(input.captions) {
                sentCaptions = .some(input.captions)
                view.evaluateJavaScript("YamGraphics.captions(\(input.captions?.json ?? "null"));")
            }
            if let before = loaded, before.duration == input.duration, before.track != input.track,
               before.track.withoutPlacement == input.track.withoutPlacement {
                // Only moves and sizes on the picture changed, as in a drag: move those
                // graphics without rebuilding anything.
                place(changed: input.track.items.filter { item in before.track.items.first { $0.id == item.id }?.transform != item.transform })
            } else if loaded?.track != input.track || loaded?.duration != input.duration {
                let folder = Self.folder(for: input.clip, canvas: input.track.canvas)
                if let json = try? GraphicsEngine.pageJSON(input.track, duration: input.duration, fps: input.fps, folder: folder) {
                    view.evaluateJavaScript("YamGraphics.load(\(json), {mode: 'preview'});")
                    sentTime = -1
                    loaded = input
                    seek(input.time)
                    measure()
                    return
                }
            }
            loaded = input
            seek(input.time)
        }

        private func place(changed graphics: [Graphic]) {
            var transforms: [String: JSONValue] = [:]
            for graphic in graphics {
                let t = graphic.transform ?? GraphicTransform()
                transforms[graphic.id.uuidString] = .object(["x": .number(t.x), "y": .number(t.y), "scale": .number(t.scale)])
            }
            guard let data = try? JSONEncoder().encode(JSONValue.object(transforms)) else { return }
            view?.evaluateJavaScript("YamGraphics.place(\(String(decoding: data, as: UTF8.self)));")
        }

        /// Asks the engine for every graphic's box once the fonts are in, so text has its
        /// real width.
        private func measure() {
            let report = onBounds
            view?.callAsyncJavaScript("await document.fonts.ready; return JSON.stringify(YamGraphics.bounds());",
                                      arguments: [:], in: nil, in: .page) { result in
                if case .success(let value) = result, let text = value as? String { report(GraphicBounds.parse(text)) }
            }
        }

        private func seek(_ time: Double) {
            guard abs(time - sentTime) > 0.0005 else { return }
            sentTime = time
            view?.evaluateJavaScript(String(format: "YamGraphics.seek(%.4f);", time))
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                ready = true
                // Fit the design stage (1920×1080, or a Short's 1080×1920) to whatever size
                // the overlay has.
                webView.evaluateJavaScript("""
                    (function () {
                      document.documentElement.style.background = 'transparent';
                      document.body.style.background = 'transparent';
                      var fit = function () {
                        var stage = document.getElementById('stage');
                        stage.style.transformOrigin = '0 0';
                        stage.style.transform = 'scale(' + (window.innerWidth / YamGraphics.stageSize().width) + ')';
                      };
                      window.addEventListener('resize', fit);
                      fit();
                    })();
                    """)
                // An edit made while the page loaded is applied now, with the playhead.
                if let pending { sentTime = -1; sentCaptions = nil; update(pending) }
                measure()
            }
        }
    }
}

/// Clicks go to the player and the editor underneath, never to the graphics.
final class PassThroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A recording's graphics at one moment, drawn offscreen by the engine page the Preview
/// lays over the picture, for an agent's composed preview: the picture with the graphics
/// on it, and each showing graphic's box in that picture's pixels.
@MainActor
final class GraphicsSnapshot: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var loading: CheckedContinuation<Void, Error>?

    static func draw(_ track: GraphicsTrack, duration: Double, fps: String, time: Double,
                     over picture: CGImage, captions: CaptionOverlay? = nil) async throws -> (image: CGImage, boxes: [UUID: CGRect]) {
        try await GraphicsSnapshot().render(track, duration: duration, fps: fps, time: time, over: picture, captions: captions)
    }

    private func render(_ track: GraphicsTrack, duration: Double, fps: String, time: Double,
                        over picture: CGImage, captions: CaptionOverlay?) async throws -> (image: CGImage, boxes: [UUID: CGRect]) {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/GraphicsSnapshot/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try GraphicsEngine.writePage(track, duration: duration, fps: fps, mode: "preview", to: folder)
        let width = Double(picture.width), height = Double(picture.height)
        // The view is sized so its snapshot has the picture's own pixels.
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width / backing, height: height / backing),
                             configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        self.view = view
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            view.loadFileURL(index, allowingReadAccessTo: folder)
        }
        let script = """
            document.documentElement.style.background = 'transparent';
            document.body.style.background = 'transparent';
            const stage = document.getElementById('stage');
            stage.style.transformOrigin = '0 0';
            stage.style.transform = 'scale(' + (window.innerWidth / YamGraphics.stageSize().width) + ')';
            YamGraphics.captions(\(captions?.json ?? "null"));
            await document.fonts.ready;
            YamGraphics.seek(time);
            return JSON.stringify(YamGraphics.boxes());
            """
        let measured = try await view.callAsyncJavaScript(script, arguments: ["time": time], contentWorld: .page) as? String ?? "{}"
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        configuration.afterScreenUpdates = true
        let snapshot = try await view.takeSnapshot(configuration: configuration)
        let spaces = [picture.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        guard let graphics = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = spaces.lazy.compactMap({
                  CGContext(data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: $0, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
              }).first else {
            throw FFmpegError(message: "The graphics could not be drawn.")
        }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(picture, in: frame)
        context.draw(graphics, in: frame)
        guard let image = context.makeImage() else { throw FFmpegError(message: "The graphics could not be drawn.") }
        let k = width / track.canvas.size.width
        let boxes = GraphicBounds.parse(measured).mapValues { box in
            CGRect(x: box.content.minX * k, y: box.content.minY * k, width: box.content.width * k, height: box.content.height * k)
        }
        return (image, boxes)
    }

    /// Loads `index` offscreen at `size` pixels with the stage fitted to it, runs `script`
    /// (which may await) and returns the picture.
    static func capture(page index: URL, folder: URL, size: CGSize, script: String) async throws -> CGImage {
        try await GraphicsSnapshot().capture(page: index, folder: folder, size: size, steps: [script + "\nreturn null;"])[0].image
    }

    /// Loads `index` offscreen once and, for each of `steps` in turn, runs it (it may await
    /// and return a string) and takes a picture: one page, several looks at it.
    static func capture(page index: URL, folder: URL, size: CGSize, steps: [String]) async throws -> [(image: CGImage, result: String?)] {
        try await GraphicsSnapshot().capture(page: index, folder: folder, size: size, steps: steps)
    }

    private func capture(page index: URL, folder: URL, size: CGSize, steps: [String]) async throws -> [(image: CGImage, result: String?)] {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: size.width / backing, height: size.height / backing),
                             configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        self.view = view
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            view.loadFileURL(index, allowingReadAccessTo: folder)
        }
        _ = try await view.callAsyncJavaScript("""
            const stage = document.getElementById('stage');
            stage.style.transformOrigin = '0 0';
            stage.style.transform = 'scale(' + (window.innerWidth / 1920) + ')';
            await document.fonts.ready;
            return true;
            """, arguments: [:], contentWorld: .page)
        var shots: [(image: CGImage, result: String?)] = []
        for step in steps {
            let result = try await view.callAsyncJavaScript(step, arguments: [:], contentWorld: .page) as? String
            let configuration = WKSnapshotConfiguration()
            configuration.rect = view.bounds
            configuration.afterScreenUpdates = true
            let snapshot = try await view.takeSnapshot(configuration: configuration)
            guard let picture = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw FFmpegError(message: "The picture could not be drawn.")
            }
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(origin: .zero, size: size))
            guard let image = context.makeImage() else { throw FFmpegError(message: "The picture could not be drawn.") }
            shots.append((image, result))
        }
        return shots
    }

    /// Each graphic's box once fully in, unmoved, as the Preview measures it.
    static func bounds(_ track: GraphicsTrack, duration: Double, fps: String) async throws -> [UUID: GraphicBounds] {
        try await GraphicsSnapshot().measure(track, duration: duration, fps: fps)
    }

    private func measure(_ track: GraphicsTrack, duration: Double, fps: String) async throws -> [UUID: GraphicBounds] {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/GraphicsSnapshot/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try GraphicsEngine.writePage(track, duration: duration, fps: fps, mode: "preview", to: folder)
        let size = track.canvas.size
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2), configuration: WKWebViewConfiguration())
        view.navigationDelegate = self
        self.view = view
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            view.loadFileURL(index, allowingReadAccessTo: folder)
        }
        let measured = try await view.callAsyncJavaScript("await document.fonts.ready; return JSON.stringify(YamGraphics.bounds());",
                                                          arguments: [:], contentWorld: .page) as? String ?? "{}"
        return GraphicBounds.parse(measured)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loading?.resume(); loading = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loading?.resume(throwing: error); loading = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loading?.resume(throwing: error); loading = nil }
    }
}
