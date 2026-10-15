import AppKit
import SwiftUI

// Shorts in the window: the inspector's list and the selected Short, the Shorts row on the
// timeline, YouTube's buttons drawn faintly over the Short viewer, and the Publish
// sheet's Short form with a sketch of the Shorts player.

// MARK: - Inspector

/// The recording's Shorts: what they are, each one, and Add Short.
struct ShortsSection: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem

    var body: some View {
        InspectorSection("Shorts") {
            Text("A Short is a vertical 1080×1920 version of up to 3:00 of this recording, for YouTube Shorts: the same edit, graphics and captions, laid out for a phone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(item.shorts.enumerated()), id: \.element.id) { index, short in
                Button { model.selectShort(short.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.portrait")
                        Text(short.name(index: index)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(PublishInfo.timestamp(short.start))–\(PublishInfo.timestamp(short.end))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
                .background(model.selectedShortID == short.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("\(short.name(index: index)), from \(PublishInfo.timestamp(short.start)) to \(PublishInfo.timestamp(short.end))")
            }
            HStack {
                Button("Add Short at Playhead") { model.addShortAtPlayhead() }
                    .help("The whole recording when it is under 3:00; otherwise a minute from the playhead. Its window is centred on the speaker.")
                if !item.shorts.isEmpty {
                    Button("Show Short") { model.setViewer(.short) }
                        .help("Show the selected Short in the viewer, 9:16, with its graphics and captions")
                }
            }
            .controlSize(.small)
        }
    }
}

/// The selected Short: its time, its window, how its panels and captions lay out, which
/// graphics show in it, its cover, and what YouTube would say about it.
struct ShortInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let info: MediaInfo
    let short: Short
    let index: Int

    private var frame: CGRect { (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame) }
    private var place: ShortWindowPlace { ShortWindowPlace(window: short.frame(info: info, crop: item.crop), in: frame) }
    /// Graphics that start inside the Short (the end screen never shows in one).
    private var graphics: [Graphic] {
        (item.graphics?.items ?? []).filter {
            $0.kind != .endScreen && $0.start >= short.start - 0.0005 && $0.start < short.end - GraphicsTrack.minimumLength + 0.000001
        }
    }
    private var issues: [PublishInfo.Issue] { short.issues(graphics: item.graphics, publish: item.publish) }

    var body: some View {
        InspectorSection("\(short.name(index: index)) · \(PublishInfo.timestamp(short.length))") {
            HStack(spacing: 12) {
                TimelineTimeField(label: "From", value: short.start) {
                    model.setShortEdge(short.id, start: $0)
                    return model.selectedShort?.start ?? short.start
                }
                TimelineTimeField(label: "to", value: short.end) {
                    model.setShortEdge(short.id, end: $0)
                    return model.selectedShort?.end ?? short.end
                }
            }
            .font(.caption)
            Text("Up to 3:00; a vertical video that long is a Short on YouTube.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button(model.viewer == .short && model.playback.shortID == short.id ? "Play Short" : "Show Short") {
                    if model.viewer == .short, model.playback.shortID == short.id { model.togglePlayback() } else { model.showShort(short) }
                }
                Button("Export for YouTube…") { model.promptForShortExport(short.id) }
                    .disabled(model.isConverting || issues.contains { $0.severity == .blocking })
                Spacer()
                Button(role: .destructive) { model.removeSelectedShort() } label: { Label("Delete", systemImage: "trash") }
            }
            .controlSize(.small)

            window
            options
            graphicsList
            cover
            details
            ForEach(issues, id: \.message) { issue in
                Label(issue.message, systemImage: issue.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(issue.severity == .blocking ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Window").font(.caption.weight(.semibold))
            slider("Across", value: place.across, range: 0...1, format: { "\(Int(($0 * 100).rounded())) %" }) {
                model.setShortWindow(short.id, across: $0, live: $1)
            }
            slider("Size", value: place.size, range: 1...3, format: { "\(Int(($0 * 100).rounded())) %" }) {
                model.setShortWindow(short.id, size: $0, live: $1)
            }
            if place.size > 1.01 {
                slider("Down", value: place.down, range: 0...1, format: { "\(Int(($0 * 100).rounded())) %" }) {
                    model.setShortWindow(short.id, down: $0, live: $1)
                }
            }
            HStack {
                Button("Centre on Speaker") { model.centreShortOnSpeaker(short.id) }
                    .help("Apple Vision finds the face in the middle of the Short and centres the window on it")
                Button("Reset") { model.updateShort(short.id, label: "Reset Short Window") { $0.window = nil } }
                    .disabled(short.window == nil)
            }
            .controlSize(.small)
            let rect = short.frame(info: info, crop: item.crop)
            Text("\(Int(rect.width))×\(Int(rect.height)) of the picture, made 1080×1920" + (rect.height < 1920 ? " (scaled up)" : ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String,
                        set: @escaping (Double, Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set($0, true) }), in: range) { editing in
                if !editing { set(value, false); model.endGesture() }
            }
            .controlSize(.small)
            .accessibilityLabel("Short window \(label.lowercased())")
            Text(format(value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Panels").font(.caption.weight(.semibold))
            Picker("Panels", selection: Binding(get: { short.panels }, set: { value in model.updateShort(short.id, label: "Short Panels") { $0.panels = value } })) {
                ForEach(ShortPanels.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(short.panels.detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Captions under a graphic").font(.caption.weight(.semibold))
            Picker("Captions under a graphic", selection: Binding(get: { short.captions }, set: { value in model.updateShort(short.id, label: "Short Captions") { $0.captions = value } })) {
                ForEach(ShortCaptions.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(short.captions.detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.settings.captionUse(hasFile: item.subtitles != nil).burns {
                Text("Captions are not burned in, so this only matters once they are (Captions in the inspector or Auto Edit).")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Try these while the Short plays: the viewer keeps playing as they change.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var graphicsList: some View {
        if !graphics.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Graphics in this Short").font(.caption.weight(.semibold))
                ForEach(graphics) { graphic in
                    HStack(spacing: 6) {
                        Toggle(isOn: Binding(get: { !short.hidden.contains(graphic.id) },
                                             set: { model.setShortGraphic(short.id, graphic: graphic.id, shown: $0) })) {
                            Text("\(graphic.kind.label) at \(PublishInfo.timestamp(graphic.start))").lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 4)
                        if short.placements[graphic.id] != nil {
                            Button("Reset Place") { model.placeGraphicInShort(short.id, graphic: graphic.id, nil, label: "Reset Graphic in Short") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.caption)
                }
                Text("In the Short viewer, drag a graphic to move it in this Short only, or a corner to resize it.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cover: some View {
        HStack {
            Text("Cover").font(.caption.weight(.semibold))
            Text(short.cover.map { "the frame at \(PublishInfo.timestamp($0)) into the Short" } ?? "not chosen")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Use Playhead") { model.setShortCoverToPlayhead(short.id) }
                .controlSize(.small)
                .disabled(model.previewTime < short.start || model.previewTime > short.end)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("For YouTube").font(.caption.weight(.semibold))
            CommitTextField(label: "Title", value: short.title) { text in
                model.updateShort(short.id, label: "Short Title") { $0.title = text.replacingOccurrences(of: "\n", with: " ") }
            }
            CommitTextField(label: "Description", value: short.description) { text in
                model.updateShort(short.id, label: "Short Description") { $0.description = text }
            }
            CommitTextField(label: "Tags, comma-separated", value: short.tags.joined(separator: ", ")) { text in
                let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                model.updateShort(short.id, label: "Short Tags") { $0.tags = tags }
            }
        }
    }
}

// MARK: - Timeline

/// One Short on the timeline: drag to move it, drag an edge to change when it starts or ends.
struct ShortBlock: View {
    let short: Short
    let name: String
    let selected: Bool
    var highlighted = false
    let pixels: Double
    let snapStart: (Double) -> Double
    let snapEdge: (Double) -> Double
    let endSnap: () -> Void
    let onSelect: () -> Void
    let onMove: (Double) -> Void
    let onTrim: (Double?, Double?) -> Void
    @State private var delta = 0.0
    @State private var startDelta = 0.0
    @State private var endDelta = 0.0

    var body: some View {
        let width = max(4, short.length * pixels)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.pink.opacity(selected ? 0.45 : 0.22))
            HStack(spacing: 3) {
                Image(systemName: "rectangle.portrait")
                Text("\(name) · \(PublishInfo.timestamp(short.length))").lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.leading, 9)
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.pink.opacity(selected ? 1 : 0.55), lineWidth: selected ? 2 : 1)
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange, lineWidth: 2.5)
                .opacity(highlighted ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: highlighted)
                .allowsHitTesting(false)
            HStack {
                handle(start: true)
                Spacer(minLength: 0)
                handle(start: false)
            }
        }
        .frame(width: max(4, width + endDelta - startDelta))
        .offset(x: delta + startDelta)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in delta = (movedStart(value.translation.width) - short.start) * pixels }
            .onEnded { value in onSelect(); onMove(movedStart(value.translation.width)); delta = 0; endSnap() })
        .help("A Short: drag to move it, drag an edge to change when it starts or ends (up to 3:00)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) from \(timelineTime(short.start)) to \(timelineTime(short.end))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }

    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.pink)
            .frame(width: 5).padding(.vertical, 4).padding(.horizontal, 2)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let edge = start ? short.start : short.end
                    let moved = (snapEdge(edge + value.translation.width / pixels) - edge) * pixels
                    if start { startDelta = moved } else { endDelta = moved }
                }
                .onEnded { value in
                    let edge = start ? short.start : short.end
                    let landed = snapEdge(edge + value.translation.width / pixels)
                    onSelect()
                    onTrim(start ? landed : nil, start ? nil : landed)
                    startDelta = 0; endDelta = 0
                    endSnap()
                })
    }

    private func movedStart(_ translation: Double) -> Double { snapStart(short.start + translation / pixels) }
}

// MARK: - Publish: a Short

/// A Short's upload details in the Publish sheet.
struct ShortPublishForm: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let short: Short

    private var issues: [PublishInfo.Issue] { short.issues(graphics: item.graphics, publish: item.publish) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorSection("Title") {
                PublishTextField(placeholder: "What the Short is called", value: short.title, axis: .horizontal) { text in
                    model.updateShort(short.id, label: "Short Title") { $0.title = text }
                }
                Text("\(short.title.count) / \(PublishInfo.titleLimit)").font(.caption2.monospacedDigit())
                    .foregroundStyle(short.title.count > PublishInfo.titleLimit ? .red : .secondary)
                lines("title")
            }
            InspectorSection("Description") {
                PublishTextField(placeholder: "What viewers read with the Short", value: short.description, axis: .vertical) { text in
                    model.updateShort(short.id, label: "Short Description") { $0.description = text }
                }
                lines("description")
            }
            InspectorSection("Tags") {
                PublishTextField(placeholder: "Comma-separated", value: short.tags.joined(separator: ", "), axis: .horizontal) { text in
                    let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.updateShort(short.id, label: "Short Tags") { $0.tags = tags }
                }
                lines("tags")
            }
            InspectorSection("Cover") {
                Text(short.cover.map { "The frame \(PublishInfo.timestamp($0)) into the Short, with its graphics, goes out as a 1080×1920 JPEG." }
                     ?? "No cover frame chosen. Move the playhead into the Short and use it as the cover.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("Use Frame at Playhead") { model.setShortCoverToPlayhead(short.id) }
                    .controlSize(.small)
                    .disabled(model.previewTime < short.start || model.previewTime > short.end)
                Text("Custom Shorts thumbnails are reaching channels in stages (Partner Program first); otherwise pick the nearest frame YouTube suggests.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            InspectorSection("Related video") {
                Text(ShortFormat.relatedVideoNote).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            InspectorSection("Shown as") {
                Text("1080×1920 · \(PublishInfo.timestamp(short.length)) · \(short.panels.label.lowercased()) panels · captions \(short.captions.label.lowercased()) under graphics. Change these in the inspector.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                lines("length"); lines("endScreen")
            }
        }
    }

    @ViewBuilder private func lines(_ field: String) -> some View {
        ForEach(issues.filter { $0.field == field }, id: \.message) { issue in
            Label(issue.message, systemImage: issue.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A sketch of the Shorts player at a phone's proportions: the cover frame, YouTube's rail
/// and the title and channel along the bottom.
struct ShortsPlayerPreview: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let short: Short
    @State private var cover: NSImage?

    private var channel: String { (item.publish?.channel).flatMap { $0.isEmpty ? nil : $0 } ?? "Your channel" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.black)
                if let cover { Image(nsImage: cover).resizable().aspectRatio(9 / 16, contentMode: .fit) }
                else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.accentColor.opacity(0.9)).frame(width: 22, height: 22)
                            .overlay(Text(String(channel.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                        Text("@" + channel.replacingOccurrences(of: " ", with: "")).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).truncationMode(.tail)
                        Text("Subscribe").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Color.white, in: Capsule())
                    }
                    Text(short.title.isEmpty ? "Your Short's title" : short.title).font(.system(size: 13)).lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(10).padding(.trailing, 44)
                VStack(spacing: 16) {
                    ForEach(["hand.thumbsup.fill", "hand.thumbsdown.fill", "text.bubble.fill", "arrowshape.turn.up.right.fill"], id: \.self) {
                        Image(systemName: $0).font(.system(size: 18))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10).padding(.bottom, 90)
            }
            .frame(width: 270, height: 480)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("A sketch of YouTube's Shorts player at a phone's proportions, for checking the cover, title and what YouTube covers. YouTube changes its player often.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                .frame(width: 270, alignment: .leading)
        }
        .task(id: "\(short.id)-\(short.cover ?? -1)-\(short.window.map { "\($0)" } ?? "")-\(short.panels.rawValue)") {
            let clip = ProjectClip(item)
            let time = short.cover ?? min(1, short.length / 2)
            if let frame = try? await model.composedShortFrame(clip, short: short, at: time, settings: model.settings).image {
                cover = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
        }
    }
}
