import SwiftUI

// MARK: - Inspector

/// The recording's screen recording: which file, how it lines up with the speaker, the base
/// layout and the speaker's bubble.
struct ScreenSection: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let info: MediaInfo

    var body: some View {
        InspectorSection("Screen") {
            if let screen = item.screen {
                details(screen)
            } else {
                Text("Show a screen recording with this recording: the speaker in a bubble on the screen, or beside it. Every cut cuts both.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.chooseScreenRecording() } label: { Label("Add Screen Recording…", systemImage: "macwindow.badge.plus") }
                    .controlSize(.small)
                    .help("Choose a screen recording made at the same time as this recording")
            }
        }
    }

    @ViewBuilder
    private func details(_ screen: ScreenTrack) -> some View {
        Text(screen.name).font(.callout).lineLimit(2).truncationMode(.middle)
        Text("\(screen.info.width)×\(screen.info.height) · \(formatDuration(screen.info.duration))")
            .font(.caption).foregroundStyle(.secondary)
        if !FileManager.default.fileExists(atPath: screen.url.path) {
            warning("The screen recording is no longer there. Add it again to show it.")
        }
        HStack(spacing: 6) {
            if let crop = screen.crop {
                Text("Shows \(Int(crop.width))×\(Int(crop.height))").font(.caption).foregroundStyle(.secondary)
                Button("Show All") { model.updateScreen(label: "Crop Screen") { $0.crop = nil } }
                    .help("Show the whole screen recording again")
            } else {
                Button("Crop Border") { model.cropScreenBorder() }
                    .help("Cut away a dark border round the recorded window")
            }
        }
        .controlSize(.small)

        // Sync
        HStack(spacing: 6) {
            TimelineTimeField(label: "Offset", value: screen.offset) { offset in
                model.updateScreen(label: "Screen Offset") { $0.offset = offset }
                return model.selectedItem?.screen?.offset ?? screen.offset
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: 4) {
            nudge("−1 s", -1, "Show the screen one second earlier")
            nudge("−1 fr", -1 / max(1, info.fps), "Show the screen one frame earlier")
            nudge("+1 fr", 1 / max(1, info.fps), "Show the screen one frame later")
            nudge("+1 s", 1, "Show the screen one second later")
        }
        if let time = model.screenTimeAtPlayhead {
            TimelineTimeField(label: "Screen at playhead", value: time) { value in
                model.setScreenTime(atPlayhead: value)
                return model.screenTimeAtPlayhead ?? time
            }
            .help("Type the screen recording's time that belongs at the playhead, for example the moment of a click you name. The offset follows.")
        }
        let covered = screen.covered(on: item.timeline)
        if covered.count != 1 || covered.first.map({ $0.lowerBound > 0.05 || $0.upperBound < item.editedDuration - 0.05 }) == true {
            Text(covered.isEmpty
                 ? "The screen recording does not overlap this recording at this offset. Its first or last frame shows."
                 : "The screen recording covers \(covered.map { "\(timelineTime($0.lowerBound))–\(timelineTime($0.upperBound))" }.joined(separator: ", ")). Elsewhere its first or last frame holds.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Layout
        Picker("Layout", selection: Binding(get: { screen.layout }, set: { layout in model.updateScreen(label: "Screen Layout") { $0.layout = layout } })) {
            ForEach(ScreenLayout.allCases) { layout in Text(layout.label).tag(layout) }
        }
        .pickerStyle(.segmented)
        .help("The layout wherever no layout on the Layout lane says otherwise")
        Picker("Bubble", selection: Binding(get: { screen.bubble.corner }, set: { corner in model.updateScreen(label: "Bubble Corner") { $0.bubble.corner = corner } })) {
            ForEach(SpeakerBubble.Corner.allCases) { corner in Text(corner.label).tag(corner) }
        }
        HStack(spacing: 6) {
            Text("Size").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Slider(value: Binding(get: { screen.bubble.size }, set: { size in model.updateScreen(live: true, label: "Bubble Size") { $0.bubble.size = size } }),
                   in: SpeakerBubble.sizeRange, onEditingChanged: { editing in if !editing { model.endGesture() } })
                .accessibilityLabel("Bubble size")
            Text("\(Int((screen.bubble.size * 100).rounded()))%").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        Picker("Shape", selection: Binding(get: { screen.bubble.shape }, set: { shape in model.updateScreen(label: "Bubble Shape") { $0.bubble.shape = shape } })) {
            ForEach(SpeakerBubble.Shape.allCases) { shape in Text(shape.label).tag(shape) }
        }
        .pickerStyle(.segmented)
        .help("The speaker's bubble in the Screen layout: a circle, or a square with soft corners")
        if screen.bubble.shape == .rounded {
            HStack(spacing: 6) {
                Text("Corners").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                Slider(value: Binding(get: { screen.bubble.corners }, set: { corners in
                    model.updateScreen(live: true, label: "Bubble Corners") { $0.bubble.corners = corners }
                }), in: SpeakerBubble.cornersRange, onEditingChanged: { editing in if !editing { model.endGesture() } })
                    .accessibilityLabel("Bubble corner roundness")
                Text("\(Int((screen.bubble.corners * 100).rounded()))%").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .help("How round the corners are, as a share of the bubble's side")
        }
        screenZooms(screen)
        HStack {
            Button("Find Speaker") { model.findSpeaker() }
                .help("Put the bubble on the face Apple Vision finds at the playhead")
            Button("Add Layout") { model.addLayoutAtPlayhead() }
                .help("A layout of its own from the playhead, for five seconds or up to the next one")
            Spacer()
            Button(role: .destructive) { model.removeScreen() } label: { Label("Remove", systemImage: "trash") }
                .help("Remove the screen recording and its layouts")
        }
        .controlSize(.small)
        Text("The Preview shows the layouts. The speaker's sound plays; the screen recording's sound does not.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func screenZooms(_ screen: ScreenTrack) -> some View {
        Text(screen.zooms.isEmpty
             ? "Zooms on the screen make small text readable. Add one at the playhead, then click the screen in the Preview to aim it."
             : "\(screen.zooms.count) screen zoom\(screen.zooms.count == 1 ? "" : "s"). Select one on the Screen zooms lane to adjust it.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Add Zoom") { model.addScreenZoomAtPlayhead() }
                .help("A 2× zoom on the screen from the playhead")
            if model.isAnalyzingZooms {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelZoomAnalysis() }
            } else {
                Button { model.suggestZooms(screen: true) } label: { Label("Suggest", systemImage: "sparkles") }
                    .disabled(item.editedDuration < 1.5)
                    .help("Find moments of local activity on the screen recording; you review them before anything is added")
            }
            Spacer()
            Button("Clear") { model.clearScreenZooms() }.disabled(screen.zooms.isEmpty)
        }
        .controlSize(.small)
    }

    private func nudge(_ title: String, _ seconds: Double, _ help: String) -> some View {
        Button(title) { model.nudgeScreenOffset(by: seconds) }
            .controlSize(.small)
            .help(help)
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

/// The selected screen zoom: how far, how long, when, and where it aims.
struct ScreenZoomInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let shot: ZoomShot

    var body: some View {
        InspectorSection("Screen zoom \(shot.levelLabel) at \(timelineTime(shot.start))") {
            Picker("Zoom", selection: Binding(get: { shot.level }, set: { model.setScreenZoomLevel(shot.id, $0) })) {
                ForEach(AppModel.screenZoomLevels, id: \.self) { level in
                    Text(level == level.rounded() ? "\(Int(level))×" : String(format: "%.1f×", level)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Screen zoom level")
            HStack {
                Text("Hold").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { shot.hold }, set: { model.setScreenZoomHold(shot.id, $0, live: true) }),
                       in: 0.5...8, step: 0.5,
                       onEditingChanged: { editing in if !editing { model.endGesture() } })
                    .accessibilityLabel("Screen zoom hold length")
                Text(String(format: "%.1f s", shot.hold))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("Click the screen in the Preview to aim it. It eases in and out over \(String(format: "%.1f", ZoomShot.ease)) s each way.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Move to Playhead") { model.retimeSelectedScreenZoomToPlayhead() }
                Button("Show It") { model.selectScreenZoom(shot) }
                Spacer()
                Button(role: .destructive) { model.removeSelectedScreenZoom() } label: { Label("Delete", systemImage: "trash") }
            }
            .controlSize(.small)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    TimelineTimeField(label: "Starts at", value: shot.start) {
                        model.setScreenZoomStart(shot.id, $0)
                        return model.selectedScreenZoom?.start ?? shot.start
                    }
                    Text("Target \(Int(shot.target.x)), \(Int(shot.target.y)) px of the screen recording · ends at \(timelineTime(shot.end))")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}

/// Over the Preview while a screen zoom is selected: a click on the picture aims it.
struct ScreenAimLayer: View {
    /// The picture's size in pixels: the recording's crop.
    let frame: CGSize
    let onAim: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            // The Preview draws the picture fitted inside its 16-point padding.
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 16, dy: 16)
            let scale = min(bounds.width / frame.width, bounds.height / frame.height)
            let picture = CGRect(x: bounds.midX - frame.width * scale / 2, y: bounds.midY - frame.height * scale / 2,
                                 width: frame.width * scale, height: frame.height * scale)
            Color.clear
                .frame(width: max(1, picture.width), height: max(1, picture.height))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    onAim(CGPoint(x: location.x / scale, y: location.y / scale))
                }
                .position(x: picture.midX, y: picture.midY)
                .help("Click the screen to aim the selected screen zoom")
        }
    }
}

/// The selected layout span: which layout, when.
struct LayoutInspector: View {
    @EnvironmentObject var model: AppModel
    let span: LayoutSpan

    var body: some View {
        InspectorSection("Layout") {
            Text("\(timelineTime(span.start)) – \(timelineTime(span.end)) · \(String(format: "%.2f s", span.duration))")
                .font(.callout)
            Picker("Layout", selection: Binding(get: { span.layout }, set: { layout in model.updateLayout(span.id) { $0.layout = layout } })) {
                ForEach(ScreenLayout.allCases) { layout in Text(layout.label).tag(layout) }
            }
            .pickerStyle(.segmented)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    TimelineTimeField(label: "Start", value: span.start) { start in
                        model.updateLayout(span.id) { $0.start = start }
                        return model.selectedLayout?.start ?? span.start
                    }
                    TimelineTimeField(label: "End", value: span.end) { end in
                        model.updateLayout(span.id) { $0.end = end }
                        return model.selectedLayout?.end ?? span.end
                    }
                    Text("Seconds of the edited recording. Times snap to whole frames. A change of layout eases over 0.4 s from its start.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .font(.caption)
            HStack {
                Button("Show It") { model.selectLayout(span) }
                    .help("Move the playhead into the layout")
                Spacer()
                Button(role: .destructive) { model.removeSelectedLayout() } label: { Label("Delete", systemImage: "trash") }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Timeline

extension ScreenLayout {
    var tint: Color {
        switch self {
        case .speaker: return .orange
        case .screen: return .blue
        case .split: return .teal
        case .ink: return .purple
        }
    }
}

/// One layout span on the Layout lane: drag to move it, drag an edge to trim it.
struct LayoutBlock: View {
    let span: LayoutSpan
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
        let width = max(4, span.duration * pixels)
        let tint = span.layout.tint
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(tint.opacity(selected ? 0.45 : 0.22))
            HStack(spacing: 3) {
                Image(systemName: span.layout.symbol)
                Text(span.layout.label).lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.leading, 9)
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(selected ? 1 : 0.55), lineWidth: selected ? 2 : 1)
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
            .onChanged { value in delta = (movedStart(value.translation.width) - span.start) * pixels }
            .onEnded { value in onSelect(); onMove(movedStart(value.translation.width)); delta = 0; endSnap() })
        .help("A layout: drag to move it, drag an edge to change when it starts or ends")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(span.layout.label) layout from \(timelineTime(span.start)) to \(timelineTime(span.end))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }

    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(span.layout.tint)
            .frame(width: 5).padding(.vertical, 4).padding(.horizontal, 2)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let edge = start ? span.start : span.end
                    let moved = (snapEdge(edge + value.translation.width / pixels) - edge) * pixels
                    if start { startDelta = moved } else { endDelta = moved }
                }
                .onEnded { value in
                    let edge = start ? span.start : span.end
                    let landed = snapEdge(edge + value.translation.width / pixels)
                    onSelect()
                    onTrim(start ? landed : nil, start ? nil : landed)
                    startDelta = 0; endDelta = 0
                    endSnap()
                })
    }

    private func movedStart(_ translation: Double) -> Double { snapStart(span.start + translation / pixels) }
}
