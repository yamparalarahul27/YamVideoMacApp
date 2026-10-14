import SwiftUI

// MARK: - Inspectors

/// The selected blur effect: when it runs, how strong, how it fades, on or off.
struct EffectInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let effect: VideoBlurEffect

    var body: some View {
        InspectorSection("Full-frame blur") {
            Text("\(timelineTime(effect.start)) – \(timelineTime(effect.end)) · \(String(format: "%.2f s", effect.duration))")
                .font(.callout)
            Toggle("On", isOn: Binding(get: { effect.isEnabled }, set: { on in model.updateEffect(effect.id) { $0.isEnabled = on } }))
                .help("Off keeps the block and its place, but draws nothing.")
            slider("Amount", \.amount, in: VideoBlurEffect.amountRange, label: String(format: "%.0f", effect.amount))
            slider("Mix", \.mix, in: VideoBlurEffect.mixRange, label: "\(Int((effect.mix * 100).rounded()))%")
            slider("Fade in", \.fadeIn, in: 0...max(0.01, effect.duration), label: String(format: "%.2f s", effect.fadeIn))
            slider("Fade out", \.fadeOut, in: 0...max(0.01, effect.duration), label: String(format: "%.2f s", effect.fadeOut))
            Text("Blurs the whole visible picture after crop and zoom. Blur areas stay hidden throughout.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let info = item.info, let problem = FFmpeg.effectProblem([effect], info: info, settings: model.settings) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    TimelineTimeField(label: "Start", value: effect.start) { start in
                        model.updateEffect(effect.id) { $0.start = start }
                        return model.selectedEffect?.start ?? effect.start
                    }
                    TimelineTimeField(label: "End", value: effect.end) { end in
                        model.updateEffect(effect.id) { $0.end = end }
                        return model.selectedEffect?.end ?? effect.end
                    }
                    Text("Seconds of the edited recording. Times snap to whole frames.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption)
            HStack {
                Button("Show It") { model.jumpToEffect(effect) }
                    .help("Move the playhead to where the effect is at full strength")
                Spacer()
                Button(role: .destructive) { model.removeSelectedEffect() } label: { Label("Delete", systemImage: "trash") }
            }
            .controlSize(.small)
        }
    }

    private func slider(_ name: String, _ path: WritableKeyPath<VideoBlurEffect, Double>, in range: ClosedRange<Double>,
                        label: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Slider(value: Binding(get: { effect[keyPath: path] }, set: { value in
                model.updateEffect(effect.id, live: true) { $0[keyPath: path] = value }
            }), in: range, onEditingChanged: { editing in if !editing { model.endGesture() } })
                .accessibilityLabel(name)
                .accessibilityValue(label)
            Text(label).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}

/// The selected marker: its name, colour and place.
struct MarkerInspector: View {
    @EnvironmentObject var model: AppModel
    let marker: TimelineMarker
    @State private var name = ""
    @FocusState private var naming: Bool

    var body: some View {
        InspectorSection("Marker at \(timelineTime(marker.time))") {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($naming)
                .onSubmit(commit)
                .onChange(of: naming) { _, active in if !active { commit() } }
                .accessibilityLabel("Marker name")
            Picker("Colour", selection: Binding(get: { marker.color }, set: { color in model.updateMarker(marker.id) { $0.color = color } })) {
                ForEach(TimelineMarker.Color.allCases) { color in
                    Label(color.label, systemImage: "flag.fill").foregroundStyle(color.swatch).tag(color)
                }
            }
            .accessibilityLabel("Marker colour")
            HStack {
                Button("Show It") { model.selectMarker(marker) }
                Spacer()
                Button(role: .destructive) { model.removeSelectedMarker() } label: { Label("Delete", systemImage: "trash") }
            }
            .controlSize(.small)
            Text("M adds a marker at the playhead, ⇧M names the selected one, ⇧↑ and ⇧↓ jump between them.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { name = marker.label; if model.renamingMarker { naming = true; model.renamingMarker = false } }
        .onChange(of: marker.label) { _, label in if !naming { name = label } }
        .onChange(of: model.renamingMarker) { _, rename in if rename { naming = true; model.renamingMarker = false } }
    }

    private func commit() {
        guard name != marker.label else { return }
        model.updateMarker(marker.id) { $0.label = name }
    }
}

/// The recording's effects and markers, below its other settings.
struct EffectsAndMarkersSection: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem

    var body: some View {
        InspectorSection("Effects") {
            Text(item.blurEffects.isEmpty
                 ? "A full-frame blur fades the whole picture out of focus and back, for a transition or a private moment. Add one at the playhead, then drag it on the Effects lane."
                 : "\(item.blurEffects.count) blur effect\(item.blurEffects.count == 1 ? "" : "s"). Select one on the Effects lane to adjust it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.addBlurEffect() } label: { Label("Add Blur Effect", systemImage: "camera.filters") }
                .controlSize(.small)
                .help("A three-second blur from the playhead, or up to the next effect")
        }
        InspectorSection("Markers") {
            if item.markers.isEmpty {
                Text("Press M to mark the playhead, to find a moment again or to tell an agent where you mean.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.markers) { marker in
                        Button { model.selectMarker(marker) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "flag.fill").foregroundStyle(marker.color.swatch)
                                Text(timelineTime(marker.time)).font(.system(.caption, design: .monospaced))
                                Text(marker.label.isEmpty ? "Untitled" : marker.label).font(.caption).lineLimit(1)
                                    .foregroundStyle(marker.label.isEmpty ? .secondary : .primary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                        .accessibilityLabel("Marker \(marker.label.isEmpty ? "untitled" : marker.label) at \(timelineTime(marker.time))")
                    }
                }
            }
            Button { model.addMarkerAtPlayhead() } label: { Label("Add Marker", systemImage: "flag") }
                .controlSize(.small)
                .help("A marker at the playhead (M)")
        }
    }
}

extension TimelineMarker.Color {
    var swatch: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

// MARK: - Timeline

/// One effect on the Effects lane. Drag it to move it, drag either edge to trim it; the
/// fades show as ramps at its ends. Changes commit when the drag ends.
struct EffectBlock: View {
    let effect: VideoBlurEffect
    let selected: Bool
    var highlighted = false
    let pixels: Double
    /// Where the block lands when moved to start at a time, and where a dragged edge lands.
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
        let width = max(4, effect.duration * pixels)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.purple.opacity(effect.isEnabled ? (selected ? 0.5 : 0.28) : 0.1))
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .purple.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: min(width / 2, effect.fadeIn * pixels))
                Spacer(minLength: 0)
                LinearGradient(colors: [.purple.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: min(width / 2, effect.fadeOut * pixels))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .allowsHitTesting(false)
            HStack(spacing: 3) {
                Image(systemName: effect.isEnabled ? "camera.filters" : "eye.slash")
                Text(effect.isEnabled ? "Blur \(Int(effect.amount))" : "Blur off").lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.leading, 9)
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.purple.opacity(selected ? 1 : 0.55), lineWidth: selected ? 2 : 1)
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange, lineWidth: 2.5)
                .shadow(color: .orange.opacity(0.6), radius: 4)
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
            .onChanged { value in delta = (movedStart(value.translation.width) - effect.start) * pixels }
            .onEnded { value in onSelect(); onMove(movedStart(value.translation.width)); delta = 0; endSnap() })
        .help("Drag to move this blur; drag an edge to change when it starts or ends")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blur effect from \(timelineTime(effect.start)) to \(timelineTime(effect.end))\(effect.isEnabled ? "" : ", off")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }

    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.purple)
            .frame(width: 5).padding(.vertical, 5).padding(.horizontal, 2)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let edge = start ? effect.start : effect.end
                    let moved = (snapEdge(edge + value.translation.width / pixels) - edge) * pixels
                    if start { startDelta = moved } else { endDelta = moved }
                }
                .onEnded { value in
                    let edge = start ? effect.start : effect.end
                    let landed = snapEdge(edge + value.translation.width / pixels)
                    onSelect()
                    onTrim(start ? landed : nil, start ? nil : landed)
                    startDelta = 0; endDelta = 0
                    endSnap()
                })
            .help(start ? "Drag to change when the blur starts" : "Drag to change when the blur ends")
    }

    private func movedStart(_ translation: Double) -> Double { snapStart(effect.start + translation / pixels) }
}

/// A marker's flag in the ruler. Click it to select the marker and go to it.
struct MarkerFlag: View {
    let marker: TimelineMarker
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "flag.fill")
                .font(.system(size: selected ? 11 : 9))
                .foregroundStyle(marker.color.swatch)
            Rectangle().fill(marker.color.swatch.opacity(0.8)).frame(width: 1, height: 8)
        }
        .frame(width: 14)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded(onSelect))
        .help(marker.label.isEmpty ? "Marker at \(timelineTime(marker.time))" : "\(marker.label) · \(timelineTime(marker.time))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Marker \(marker.label.isEmpty ? "untitled" : marker.label) at \(timelineTime(marker.time))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }
}
