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
}

/// The recording's graphics over the player, drawn by the same engine as the export.
/// It loads the engine page once per recording; after that a playhead change only seeks
/// the engine's timeline, and an edit only hands it new data.
struct GraphicsOverlay: NSViewRepresentable {
    let input: GraphicsOverlayInput

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = PassThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.update(input)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(input)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        private var loaded: GraphicsOverlayInput?
        private var ready = false
        private var sentTime = -1.0
        private var pending: GraphicsOverlayInput?

        static func folder(for clip: UUID) -> URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("YamVideo/GraphicsPreview/\(clip.uuidString)", isDirectory: true)
        }

        func update(_ input: GraphicsOverlayInput) {
            guard let view else { return }
            pending = input
            if loaded?.clip != input.clip {
                ready = false; sentTime = -1
                do {
                    let folder = Self.folder(for: input.clip)
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
            if loaded?.track != input.track || loaded?.duration != input.duration {
                let folder = Self.folder(for: input.clip)
                if let json = try? GraphicsEngine.pageJSON(input.track, duration: input.duration, fps: input.fps, folder: folder) {
                    view.evaluateJavaScript("YamGraphics.load(\(json), {mode: 'preview'});")
                    sentTime = -1
                }
            }
            loaded = input
            seek(input.time)
        }

        private func seek(_ time: Double) {
            guard abs(time - sentTime) > 0.0005 else { return }
            sentTime = time
            view?.evaluateJavaScript(String(format: "YamGraphics.seek(%.4f);", time))
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                ready = true
                // Fit the 1920×1080 design stage to whatever size the overlay has.
                webView.evaluateJavaScript("""
                    (function () {
                      document.documentElement.style.background = 'transparent';
                      document.body.style.background = 'transparent';
                      var fit = function () {
                        var stage = document.getElementById('stage');
                        stage.style.transformOrigin = '0 0';
                        stage.style.transform = 'scale(' + (window.innerWidth / 1920) + ')';
                      };
                      window.addEventListener('resize', fit);
                      fit();
                    })();
                    """)
                // An edit made while the page loaded is applied now, with the playhead.
                if let pending { sentTime = -1; update(pending) }
            }
        }
    }
}

/// Clicks go to the player and the editor underneath, never to the graphics.
final class PassThroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
