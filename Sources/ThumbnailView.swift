import AppKit
import SwiftUI
import WebKit

/// The thumbnail maker: choose a frame, write the title and tag, and see the thumbnail as
/// it will be, large or at a phone's sizes, with the phone check under it: what does not
/// read in 0.5 s. Saving makes the 1280×720 PNG next to the recording and uses it as the
/// thumbnail, in one undo step.
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
    /// The phone check of the design as it was a moment ago, and the picture it checked.
    @State private var check: PhoneCheck?
    @State private var checked: CGImage?
    @State private var checking = false
    @State private var checkRun = 0
    @State private var checkProblem: String?
    /// Apple Vision's finds, kept while the frame and the picture stay the same.
    @State private var faceFound: (frame: CGImage, face: CGRect?)?
    @State private var pictureWords: (url: URL, words: [(text: String, box: CGRect)])?
    @AppStorage("thumbnailOnPhone") private var onPhone = false

    init(item: VideoItem, playhead: Double) {
        self.item = item
        let publish = item.publish ?? PublishInfo()
        var start = publish.design ?? ThumbnailDesign(time: playhead, title: publish.title)
        start.time = min(max(0, start.time), item.editedDuration)
        _design = State(initialValue: start)
    }

    private var accent: String { item.graphics?.style.accent ?? GraphicsStyle().accent }
    private var publish: PublishInfo { item.publish ?? PublishInfo() }

    /// What the phone check depends on: the design and the frame it was drawn from.
    private struct CheckInput: Equatable {
        var design: ThumbnailDesign
        var frame: Double?
    }

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
                    Picker("Preview", selection: $onPhone) {
                        Text("Design").tag(false)
                        Text("On a phone").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Group {
                        if onPhone { phoneViews } else { preview(width: 640) }
                    }
                    .frame(height: 360, alignment: .topLeading)
                    checkPanel
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
        .frame(width: 1200, height: 720)
        .task(id: design.time) { await loadFrame() }
        .task(id: CheckInput(design: design, frame: loadedTime)) { await runCheck() }
    }

    // MARK: - On a phone

    /// The checked picture at the phone's sizes, with the title and channel as YouTube's
    /// app shows them beside it.
    private var phoneViews: some View {
        let title = publish.title.isEmpty ? "Your title" : publish.title
        let channel = publish.channel.isEmpty ? "Your channel" : publish.channel
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                phoneThumbnail(.homeFeed)
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Color.accentColor.opacity(0.85)).frame(width: 34, height: 34)
                        .overlay(Text(String(channel.prefix(1)).uppercased()).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                        Text("\(channel) · 0 views · just now").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                phoneSizeLabel(.homeFeed)
            }
            .frame(width: PhoneSize.homeFeed.width)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    phoneThumbnail(.searchList)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 14, weight: .medium)).lineLimit(3)
                        Text("\(channel) · 0 views").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                phoneSizeLabel(.searchList)
                Text("These are the sizes on an iPhone. Hold the Mac at arm's length to see them about as a phone shows them. Up next, the history and playlists use the search list's size.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(width: PhoneSize.homeFeed.width, alignment: .leading)
        }
    }

    private func phoneThumbnail(_ size: PhoneSize) -> some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let checked {
                Image(decorative: checked, scale: 1).resizable().interpolation(.high)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomTrailing) {
            Text(PublishInfo.timestamp(item.editedDuration)).font(.system(size: size == .homeFeed ? 12 : 10, weight: .semibold))
                .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                .padding(size == .homeFeed ? 6 : 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: size == .homeFeed ? 12 : 8))
        .accessibilityElement()
        .accessibilityLabel("The thumbnail in the \(size.label.lowercased())")
    }

    private func phoneSizeLabel(_ size: PhoneSize) -> some View {
        Text("\(size.label), \(Int(size.width)) × \(Int(size.height)) pt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// What does not read on a phone in 0.5 s, worst first.
    private var checkPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Phone check").font(.headline)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                if let check {
                    if check.reads {
                        Label("Reads in 0.5 s", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    } else {
                        let weak = check.findings.count - check.fails
                        Text([check.fails > 0 ? "\(check.fails) do not read" : nil, weak > 0 ? "\(weak) to look at" : nil]
                                .compactMap { $0 }.joined(separator: ", "))
                            .font(.caption.weight(.semibold)).foregroundStyle(check.fails > 0 ? .red : .orange)
                    }
                }
            }
            if sources != nil, sources?.cutout == nil, design.cutout {
                Label("No speaker found in this frame; it is used as it is.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let checkProblem {
                Label(checkProblem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if let check {
                        if check.reads {
                            Text("The words and the face read at a glance in the home feed and in the search list.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(check.findings) { finding in findingRow(finding) }
                    } else if design.problem == nil {
                        Text("Checking the design at a phone's sizes…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func findingRow(_ finding: PhoneCheck.Finding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: finding.level == .fails ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(finding.level == .fails ? Color.red : Color.orange)
            Text(finding.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(finding.sizes.count == PhoneSize.allCases.count ? "Both sizes" : finding.sizes.map(\.label).joined(separator: ", "))
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// Checks the design about 0.7 s after the last change: drawn offscreen once with the
    /// words and once without, with Apple Vision's face and picture words kept between runs.
    private func runCheck() async {
        guard let sources, loadedTime != nil, design.problem == nil else { return }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !Task.isCancelled else { return }
        checkRun += 1
        let run = checkRun
        checking = true
        defer { if run == checkRun { checking = false } }
        let chosen = design, frame = sources.frame
        let face: CGRect?
        if let found = faceFound, found.frame === frame { face = found.face } else {
            face = await Task.detached(priority: .userInitiated) { PhoneCheck.face(in: frame) }.value
            faceFound = (frame, face)
        }
        var words: [(text: String, box: CGRect)] = []
        if let url = chosen.image {
            if let found = pictureWords, found.url == url { words = found.words } else {
                words = await Task.detached(priority: .userInitiated) { PhoneCheck.words(in: url) }.value
                pictureWords = (url, words)
            }
        }
        do {
            let drawn = try await ThumbnailMaker.measure(chosen, sources: sources, accent: accent)
            guard !Task.isCancelled else { return }
            check = PhoneCheck.make(layout: drawn.layout, image: drawn.image, plate: drawn.plate, face: face,
                                    frameWidth: frame.width, pictureWords: words)
            checked = drawn.image
            checkProblem = nil
        } catch {
            if !Task.isCancelled { checkProblem = "The phone check could not run: \(error.localizedDescription)" }
        }
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
                    Text("The speaker moves to the far side, and gets smaller if necessary, so the title and the picture do not overlap them. Use Plain, White or White frost behind: the other backgrounds show the speaker in the old place.")
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
                HStack {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $design.imageSize, in: ThumbnailDesign.imageSizes, step: 0.05).disabled(design.image == nil)
                        .accessibilityLabel("Picture size")
                    Text("\(Int((design.imageSize * 100).rounded())) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("A product photo or an icon; a transparent PNG looks best. A larger picture makes the title smaller.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
