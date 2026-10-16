import AppKit
import SwiftUI
import WebKit

/// The thumbnail maker: choose a frame, write the title and tag, and see the thumbnail as
/// it will be, large and at YouTube's search size. Saving makes the 1280×720 PNG next to
/// the recording and uses it as the thumbnail, in one undo step.
struct ThumbnailMakerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: VideoItem
    @State private var design: ThumbnailDesign
    @State private var sources: ThumbnailMaker.Sources?
    @State private var loadedTime: Double?
    @State private var working: String?
    @State private var problem: String?
    @State private var suggestions: [FrameSuggestion] = []
    @State private var suggesting: Task<Void, Never>?

    init(item: VideoItem, playhead: Double) {
        self.item = item
        let publish = item.publish ?? PublishInfo()
        var start = publish.design ?? ThumbnailDesign(time: playhead, title: publish.title)
        start.time = min(max(0, start.time), item.editedDuration)
        _design = State(initialValue: start)
    }

    private var accent: String { item.graphics?.style.accent ?? GraphicsStyle().accent }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Make Thumbnail").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView { controls.padding(18) }.frame(width: 360)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    preview(width: 640)
                    HStack(alignment: .top, spacing: 14) {
                        preview(width: 360)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("At YouTube's search size").font(.caption.weight(.semibold))
                            Text("Most people see it this small. A short title in big letters reads best.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let cut = sources?.cutout, design.cutout {
                                Text("Speaker found: \(Int(cut.box.width)) × \(Int(cut.box.height)) px.").font(.caption2).foregroundStyle(.tertiary)
                            } else if sources != nil, design.cutout {
                                Label("No speaker found in this frame; it is used as it is.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(18)
            }
            Divider()
            HStack {
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).font(.caption).foregroundStyle(.secondary)
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Thumbnail") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working != nil || sources == nil || design.problem != nil)
                    .help("Makes the 1280×720 PNG next to the recording and uses it as the video's thumbnail")
            }
            .padding(14)
        }
        .frame(width: 1060, height: 720)
        .task(id: design.time) { await loadFrame() }
    }

    @ViewBuilder private func preview(width: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let sources {
                ThumbnailPreview(clip: item.id, design: design, sources: sources, accent: accent)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: width > 400 ? 10 : 8))
        .accessibilityElement()
        .accessibilityLabel("Thumbnail preview")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorSection("Frame") {
                HStack {
                    Text(PublishInfo.timestamp(design.time) + String(format: ".%02d", Int((design.time * 100).rounded()) % 100))
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Use Playhead") { design.time = min(model.previewTime, item.editedDuration) }.controlSize(.small)
                }
                Slider(value: Binding(get: { design.time }, set: { design.time = $0 }), in: 0...max(0.1, item.editedDuration)) {
                    EmptyView()
                }
                .accessibilityLabel("Frame time")
                Text("Pick a moment with a clear face; the speaker is cut out with Apple Vision. With a screen recording, the speaker's own picture is used at every moment.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(suggesting == nil ? "Suggest Frames" : "Stop") { suggesting == nil ? suggestFrames() : suggesting?.cancel() }
                        .controlSize(.small)
                        .help("Finds the moments where you smile, look at the camera and have your eyes open")
                    if suggesting != nil { ProgressView().controlSize(.small) }
                }
                if !suggestions.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(suggestions) { suggestion in suggestionButton(suggestion) }
                    }
                }
            }
            InspectorSection("Title") {
                TextField("Big words, three lines at most", text: $design.title, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                Text("Put words between asterisks to colour them: Edit for the *viewer*.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Highlight the coloured words", isOn: $design.highlight)
                TextField("Tag, like NEW or 3 RULES", text: $design.tag).textFieldStyle(.roundedBorder)
                ColorPicker("Accent", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: design.accent ?? accent) ?? .systemYellow) },
                    set: { design.accent = NSColor($0).hexString }), supportsOpacity: false)
            }
            InspectorSection("Speaker") {
                Toggle("Cut the speaker out", isOn: $design.cutout)
                Toggle("White outline", isOn: $design.outline).disabled(!design.cutout)
                HStack {
                    Text("Width").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $design.outlineWidth, in: ThumbnailDesign.outlineWidths, step: 1).disabled(!design.cutout || !design.outline)
                        .accessibilityLabel("Outline width")
                    Text("\(Int(design.outlineWidth.rounded())) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $design.zoom, in: ThumbnailDesign.zooms, step: 0.05).disabled(!design.cutout)
                        .accessibilityLabel("Speaker size")
                    Text("\(Int((design.zoom * 100).rounded())) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Picker("Place", selection: $design.place) {
                    ForEach(ThumbnailDesign.Place.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!design.cutout)
                if design.place == .clear {
                    Text("The speaker moves to the far side, and gets smaller if necessary, so the title and the picture do not overlap them. Use Plain or White behind, because the frame shows the speaker in the old place.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Picker("Behind", selection: $design.background) {
                    ForEach(ThumbnailDesign.Background.allCases) { Text($0.label).tag($0) }
                }
                Picker("Title side", selection: $design.side) {
                    ForEach(ThumbnailDesign.Side.allCases) { Text($0.label).tag($0) }
                }
            }
            InspectorSection("Picture beside the title") {
                HStack {
                    Text(design.image?.lastPathComponent ?? "None").font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseImage() }.controlSize(.small)
                    if design.image != nil { Button("Clear") { design.image = nil }.controlSize(.small) }
                }
                Text("A product photo or an icon; a transparent PNG looks best.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let issue = design.problem {
                Label(issue, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func suggestionButton(_ suggestion: FrameSuggestion) -> some View {
        Button { design.time = suggestion.time } label: {
            VStack(spacing: 2) {
                if let picture = suggestion.picture {
                    Image(nsImage: NSImage(cgImage: picture, size: NSSize(width: 72, height: 72)))
                        .resizable().aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(abs(design.time - suggestion.time) < 0.05 ? Color.accentColor : Color.clear, lineWidth: 2))
                }
                Text(PublishInfo.timestamp(suggestion.time)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(String(format: "Smile %.0f %%, face %.0f %%, eyes %.0f %%, facing %.0f %%", suggestion.look.smile * 100,
                     suggestion.look.quality * 100, suggestion.look.eyes * 100, suggestion.look.facing * 100))
        .accessibilityLabel("Use the frame at \(PublishInfo.timestamp(suggestion.time))")
    }

    private func suggestFrames() {
        problem = nil
        suggesting = Task {
            defer { suggesting = nil }
            do {
                let found = try await FrameAnalyzer.analyze(item, count: 8)
                suggestions = found
                if found.isEmpty { problem = "Apple Vision found no face in the kept footage." }
                else if let best = found.first { design.time = best.time }
            } catch is CancellationError {
            } catch { problem = error.localizedDescription }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.message = "Choose a picture to show beside the title."
        if panel.runModal() == .OK, let url = panel.url { design.image = url }
    }

    private func loadFrame() async {
        let time = design.time
        guard loadedTime != time else { return }
        // A slider drag asks for many frames; wait until it settles.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        working = "Cutting the speaker out…"
        problem = nil
        do {
            sources = try await model.thumbnailSources(ProjectClip(item), at: time, cutout: true)
            loadedTime = time
        } catch {
            if !Task.isCancelled { problem = error.localizedDescription }
        }
        working = nil
    }

    private func save() {
        working = "Making the thumbnail…"
        let clip = ProjectClip(item)
        let chosen = design
        Task {
            do {
                let url = try await model.saveThumbnail(clip, design: chosen)
                model.setPublish(label: "Make Thumbnail") { info in
                    info.design = chosen
                    info.thumbnail = url
                }
                model.statusMessage = "Saved the thumbnail as \(url.lastPathComponent)."
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            working = nil
        }
    }
}

/// The thumbnail page, live: the frame and cut-out are written once, and each change to
/// the design redraws it in place.
struct ThumbnailPreview: NSViewRepresentable {
    let clip: UUID
    let design: ThumbnailDesign
    let sources: ThumbnailMaker.Sources
    let accent: String

    func makeCoordinator() -> Coordinator { Coordinator(clip: clip) }

    func makeNSView(context: Context) -> WKWebView {
        let view = PassThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.update(design: design, sources: sources, accent: accent)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(design: design, sources: sources, accent: accent)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        let folder: URL
        private var ready = false
        private var pending: String?
        private var shown: String?
        /// The pictures are written once per frame, not on every keystroke.
        private var media: (frame: CGImage, files: ThumbnailMaker.Media)?

        init(clip: UUID) {
            folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("YamVideo/ThumbnailPreview/\(clip.uuidString)", isDirectory: true)
        }

        func update(design: ThumbnailDesign, sources: ThumbnailMaker.Sources, accent: String) {
            guard let view else { return }
            if media?.frame !== sources.frame, let files = try? ThumbnailMaker.writeMedia(sources, folder: folder) {
                media = (sources.frame, files)
            }
            guard let files = media?.files,
                  let data = try? ThumbnailMaker.pageData(design, media: files, accent: accent, folder: folder) else { return }
            let json = String(decoding: data, as: UTF8.self)
            guard json != shown else { return }
            if !ready {
                pending = json
                if view.url == nil, let index = try? ThumbnailMaker.writePage(to: folder) {
                    view.loadFileURL(index, allowingReadAccessTo: folder)
                }
                return
            }
            shown = json
            view.evaluateJavaScript("YamGraphics.thumbnail(\(json));")
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                ready = true
                webView.evaluateJavaScript("""
                    (function () {
                      var fit = function () {
                        var stage = document.getElementById('stage');
                        stage.style.transformOrigin = '0 0';
                        stage.style.transform = 'scale(' + (window.innerWidth / 1920) + ')';
                      };
                      window.addEventListener('resize', fit);
                      fit();
                    })();
                    """)
                if let pending {
                    shown = pending
                    webView.evaluateJavaScript("YamGraphics.thumbnail(\(pending));")
                }
            }
        }
    }
}
