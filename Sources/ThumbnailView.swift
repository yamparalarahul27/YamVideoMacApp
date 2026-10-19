import AppKit
import SwiftUI
import WebKit

/// The thumbnail maker: choose a frame, write the video's title and the thumbnail's words,
/// and see the thumbnail as it will be, large or at a phone's sizes, with the check under
/// it: what does not read in 0.5 s, and whether the thumbnail only repeats the title.
/// Saving makes the 1280×720 PNG next to the recording, uses it as the thumbnail and keeps
/// the title, in one undo step. With versions B and C for YouTube's Test & Compare, Save
/// makes a PNG of each, and the Winner menu marks the one that won.
struct ThumbnailMakerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: VideoItem
    /// The version shown and edited; it goes back into `versions` when another is shown,
    /// and on Save.
    @State private var design: ThumbnailDesign
    /// Every version for YouTube's Test & Compare, A first. One is no test.
    @State private var versions: [ThumbnailDesign]
    @State private var current = 0
    /// The video's title on YouTube, written here beside the thumbnail's words.
    @State private var videoTitle: String
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
    /// design, eyePath or phone: the view above the check list.
    @AppStorage("thumbnailPreview") private var previewMode = "design"
    /// The findings whose advice shows under them.
    @State private var opened: Set<String> = []

    init(item: VideoItem, playhead: Double) {
        self.item = item
        let publish = item.publish ?? PublishInfo()
        var all = publish.versions
        if all.isEmpty { all = [ThumbnailDesign(time: playhead, title: publish.title)] }
        for index in all.indices { all[index].time = min(max(0, all[index].time), item.editedDuration) }
        _versions = State(initialValue: all)
        _design = State(initialValue: all[0])
        _videoTitle = State(initialValue: publish.title)
    }

    private var accent: String { item.graphics?.style.accent ?? GraphicsStyle().accent }
    private var publish: PublishInfo { item.publish ?? PublishInfo() }

    /// The thumbnail's words against the video's title, as they are now: no drawing needed.
    private var gap: InformationGap {
        let lines = design.image != nil && pictureWords?.url == design.image ? pictureWords?.words.map(\.text) ?? [] : []
        return InformationGap.make(design, pictureWords: lines, title: videoTitle)
    }

    /// The findings to show: the phone check's (a moment old) and the title's (now).
    private var findings: [PhoneCheck.Finding]? {
        check.map { $0.adding(gap).findings }
    }

    /// What the phone check depends on: the design and the frame it was drawn from.
    private struct CheckInput: Equatable {
        var design: ThumbnailDesign
        var frame: Double?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Make Thumbnail").font(.title2.weight(.semibold))
                Spacer()
                versionControls
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView { controls.padding(18) }.frame(width: 360)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Preview", selection: $previewMode) {
                        Text("Design").tag("design")
                        Text("Eye path").tag("eyePath")
                        Text("Phone").tag("phone")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Group {
                        switch previewMode {
                        case "phone": phoneViews
                        case "eyePath": eyePathView
                        default: preview(width: 640)
                        }
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
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working != nil || sources == nil || design.problem != nil || versions.contains { $0.problem != nil })
                    .help("Makes the 1280×720 PNG next to the recording, uses it as the video's thumbnail and keeps the video title")
            }
            .padding(14)
        }
        .frame(width: 1200, height: 720)
        .task(id: design.time) { await loadFrame() }
        .task(id: CheckInput(design: design, frame: loadedTime)) { await runCheck() }
    }

    // MARK: - On a phone

    // MARK: - Versions

    /// The recording's saved Test & Compare, as the project has it now.
    private var savedTest: ThumbnailTest? { model.items.first { $0.id == item.id }?.publish?.test }

    /// The versions for YouTube's Test & Compare: A, B and C, one more or one less, and,
    /// once they are saved, the one that won.
    @ViewBuilder private var versionControls: some View {
        if versions.count > 1 {
            Picker("Version", selection: Binding(get: { current }, set: { show($0) })) {
                ForEach(versions.indices, id: \.self) { index in Text(ThumbnailTest.letters[index]).tag(index) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("The versions for YouTube's Test & Compare")
            Button { removeVersion() } label: { Image(systemName: "minus") }
                .disabled(current == 0)
                .help(current == 0 ? "Version A stays" : "Remove version \(ThumbnailTest.letters[current])")
        }
        Button { addVersion() } label: { Label("Version", systemImage: "plus") }
            .disabled(versions.count >= ThumbnailTest.most)
            .help("Add a version for YouTube's Test & Compare: a copy of this one to change. Up to 3.")
        if let saved = savedTest, !saved.images.isEmpty {
            Picker("Winner", selection: Binding(get: { savedTest?.winner }, set: { model.markThumbnailWinner($0) })) {
                Text("None").tag(Int?.none)
                ForEach(0..<saved.count, id: \.self) { index in Text(ThumbnailTest.letters[index]).tag(Int?.some(index)) }
            }
            .fixedSize()
            .help("After the test in YouTube Studio: the version that won becomes the thumbnail, and the project's idea in the Library notes it")
        }
    }

    private func show(_ index: Int) {
        guard versions.indices.contains(index), index != current else { return }
        versions[current] = design
        current = index
        design = versions[index]
    }

    /// A copy of the version shown, to change.
    private func addVersion() {
        guard versions.count < ThumbnailTest.most else { return }
        versions[current] = design
        versions.append(design)
        current = versions.count - 1
    }

    private func removeVersion() {
        guard current > 0 else { return }
        versions.remove(at: current)
        current -= 1
        design = versions[current]
    }

    // MARK: - Eye path

    /// The checked picture with the eye path on it: a numbered mark just left of each stop,
    /// at its middle height, so the words stay clear; the marks are joined by a line in the
    /// order the eye takes them.
    private var eyePathView: some View {
        let width: CGFloat = 640, scale = width / 1920
        let stops = Array((check?.path ?? []).prefix(EyePath.shown))
        let points = stops.map { stop in
            CGPoint(x: min(max(stop.box.x * scale - 16, 12), width - 12),
                    y: min(max((stop.box.y + stop.box.h / 2) * scale, 12), width * 9 / 16 - 12))
        }
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black)
            if let checked {
                Image(decorative: checked, scale: 1).resizable().interpolation(.high)
                Path { line in
                    guard let first = points.first else { return }
                    line.move(to: first)
                    for point in points.dropFirst() { line.addLine(to: point) }
                }
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
                .shadow(color: .black.opacity(0.6), radius: 2)
                ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.black)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(stop.kind == .accent ? Color.yellow : Color.white))
                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                        .position(points[index])
                        .help(stopLabel(stop))
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement()
        .accessibilityLabel("Eye path: " + stops.enumerated().map { "\($0.offset + 1) \(stopLabel($0.element))" }.joined(separator: ", "))
    }

    private func stopLabel(_ stop: EyeStop) -> String {
        switch stop.kind {
        case .face: return "the face"
        case .tag: return "the tag"
        case .picture: return "“\(stop.text)” in the picture"
        case .title, .accent: return "“\(stop.text)”"
        }
    }

    /// The checked picture at the phone's sizes, with the title and channel as YouTube's
    /// app shows them beside it.
    private var phoneViews: some View {
        let title = videoTitle.isEmpty ? "Your title" : videoTitle
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
            .help("The size on an iPhone. Hold the Mac at arm's length to see it about as a phone shows it."
                  + (size == .searchList ? " Up next, the history and playlists use this size too." : ""))
    }

    /// What does not read on a phone in 0.5 s, and a title the thumbnail repeats, worst first.
    private var checkPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Thumbnail check").font(.headline)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                if let findings { counts(findings) }
            }
            if sources != nil, sources?.cutout == nil, design.cutout {
                Label("No speaker found in this frame.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let checkProblem {
                Label(checkProblem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if let findings {
                        if findings.isEmpty {
                            Text("Reads at a glance on a phone, and adds to the video title.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(findings) { finding in findingRow(finding) }
                    } else if design.problem == nil {
                        Text("Checking…").font(.callout).foregroundStyle(.secondary)
                        if let finding = gap.finding { findingRow(finding) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// How many findings fail and how many are weak, as icons with numbers.
    private func counts(_ findings: [PhoneCheck.Finding]) -> some View {
        let fails = findings.filter { $0.level == .fails }.count, weak = findings.count - fails
        return HStack(spacing: 10) {
            if findings.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if fails > 0 { Label("\(fails)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            if weak > 0 { Label("\(weak)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(findings.isEmpty ? "Reads at a glance" : "\(fails) do not work, \(weak) to look at")
    }

    /// One short line; the advice shows on hover, and under the line after a click.
    private func findingRow(_ finding: PhoneCheck.Finding) -> some View {
        let open = opened.contains(finding.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finding.level == .fails ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(finding.level == .fails ? Color.red : Color.orange)
                Text(finding.summary).font(.callout).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            if open {
                Text(finding.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if open { opened.remove(finding.id) } else { opened.insert(finding.id) } }
        .help(finding.message)
        .accessibilityElement(children: .combine)
        .accessibilityHint(finding.message)
    }

    /// Checks the design about 0.7 s after the last change: drawn offscreen once as it is
    /// and once with the title's letters marked, with Apple Vision's face and picture words
    /// kept between runs.
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
            check = PhoneCheck.make(layout: drawn.layout, image: drawn.image, letters: drawn.letters, face: face,
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
                Text("Pick a frame with a clear face.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("Apple Vision cuts the speaker out. With a screen recording, the speaker's own picture is used at every moment.")
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
            InspectorSection("Video title") {
                TextField("The title on YouTube", text: $videoTitle, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                HStack(alignment: .firstTextBaseline) {
                    Text("Saved with the thumbnail.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text("\(videoTitle.count)/\(PublishInfo.titleLimit)").font(.caption2.monospacedDigit())
                        .foregroundStyle(videoTitle.count > PublishInfo.titleLimit ? Color.red : Color.secondary)
                }
            }
            InspectorSection("Thumbnail title") {
                TextField("Big words, three lines at most", text: $design.title, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                Text("Put *asterisks* round words to colour them.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                gapLine
                Toggle("Highlight", isOn: $design.highlight)
                    .help("The coloured words get a band of the accent colour, in dark text")
                TextField("Tag, like NEW or 3 RULES", text: $design.tag).textFieldStyle(.roundedBorder)
                ColorPicker("Accent", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: design.accent ?? accent) ?? .systemYellow) },
                    set: { design.accent = NSColor($0).hexString }), supportsOpacity: false)
            }
            InspectorSection("Speaker") {
                Toggle("Cut-out", isOn: $design.cutout)
                    .help("Apple Vision cuts the speaker out, so the background can change behind them")
                Toggle("Outline", isOn: $design.outline).disabled(!design.cutout)
                    .help("A white outline round the cut-out speaker")
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
                .help("Clear: the speaker moves away from the title and the picture, so nothing overlaps")
                if design.place == .clear {
                    Text("Use Plain, White or White frost behind.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .help("The speaker moves to the far side, and gets smaller if necessary, so the title and the picture do not overlap them. The other backgrounds show the speaker in the old place.")
                }
                Picker("Behind", selection: $design.background) {
                    ForEach(ThumbnailDesign.Background.allCases) { Text($0.label).tag($0) }
                }
                Picker("Title side", selection: $design.side) {
                    ForEach(ThumbnailDesign.Side.allCases) { Text($0.label).tag($0) }
                }
                .help("Auto: the side away from the speaker")
            }
            InspectorSection("Picture") {
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
                Text("A transparent PNG looks best.")
                    .help("A product photo or an icon beside the title. A larger picture makes the title smaller.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let issue = design.problem {
                Label(issue, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// The thumbnail's words against the video's title, as you type, and how to open a
    /// question the title does not answer.
    private var gapLine: some View {
        let gap = self.gap
        let titled = !videoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Group {
            if !titled {
                Text("No video title to compare.").foregroundStyle(.secondary)
            } else if let finding = gap.finding {
                Label(finding.summary, systemImage: finding.level == .fails ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(finding.level == .fails ? Color.red : Color.orange)
                    .help(finding.message)
            } else if !gap.added.isEmpty {
                Label("Adds: " + gap.added.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("These words are not in the video title. " + InformationGap.advice)
            }
        }
        .font(.caption).lineLimit(1).truncationMode(.tail)
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

    /// Makes a PNG of each version (with its letter in the name when there are more than
    /// one) and keeps them, in one undo step. A winner already marked stays, and its picture
    /// stays the thumbnail.
    private func save() {
        versions[current] = design
        working = "Making the thumbnail…"
        let clip = ProjectClip(item)
        let all = versions, title = videoTitle
        let winner = savedTest?.winner.flatMap { $0 < all.count ? $0 : nil }
        Task {
            do {
                var urls: [URL] = []
                for (index, version) in all.enumerated() {
                    let letter = all.count > 1 ? ThumbnailTest.letters[index] : nil
                    if let letter { working = "Making version \(letter)…" }
                    urls.append(try await model.saveThumbnail(clip, design: version, version: letter))
                }
                model.setPublish(label: "Make Thumbnail") { info in
                    info.design = all[0]
                    info.test = all.count > 1 ? ThumbnailTest(versions: Array(all.dropFirst()), images: urls, winner: winner) : nil
                    info.thumbnail = urls[winner ?? 0]
                    info.title = title
                }
                model.statusMessage = all.count > 1 ? "Saved \(all.count) versions for Test & Compare."
                    : "Saved the thumbnail as \(urls[0].lastPathComponent)."
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
