import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var playback: PlaybackController
    let item: VideoItem
    @State private var overview: AudioOverview?
    @State private var audioError: String?
    @State private var reviewingSilence = false
    /// Where a drag has snapped to, drawn as a guide for as long as it holds.
    @State private var snapGuide: Double?

    // Lane geometry. Every height below derives from these, so adding a lane is one
    // entry rather than five magic numbers that have to be kept in step.
    private static let rulerHeight = 22.0
    private static let sectionHeight = 48.0
    private static let waveformHeight = 28.0
    private static let zoomHeight = 28.0
    private static let laneSpacing = 5.0

    private var laneHeights: [Double] {
        var lanes = [Self.rulerHeight, Self.sectionHeight]
        if overview != nil { lanes.append(Self.waveformHeight) }
        lanes.append(Self.zoomHeight)
        return lanes
    }

    private var contentHeight: Double {
        laneHeights.reduce(0, +) + Self.laneSpacing * Double(laneHeights.count - 1)
    }

    private var total: Double { max(0.001, item.editedDuration) }

    /// Each section with the offset it starts at, summed once rather than asking the
    /// timeline for every section's offset in turn.
    private var placedSegments: [(index: Int, segment: TimelineSegment, offset: Double)] {
        var offset = 0.0
        return item.timeline.segments.enumerated().map { index, segment in
            defer { offset += segment.duration }
            return (index, segment, offset)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            transport
            GeometryReader { geo in
                let width = max(1, geo.size.width - 2)
                let pixels = model.viewport.pixels(across: width)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: Self.laneSpacing) {
                        ruler(width: width)
                        sectionLane(width: width, pixels: pixels)
                        if let overview {
                            WaveformView(overview: overview, timeline: item.timeline, window: model.viewport)
                                .frame(width: width, height: Self.waveformHeight)
                                .contentShape(Rectangle())
                                .gesture(scrubGesture(width: width, pixels: pixels))
                        }
                        zoomLane(width: width, pixels: pixels)
                    }
                    playhead(width: width)
                    guide(width: width)
                }
                .frame(width: width, height: contentHeight)
                .overlay(
                    TimelineGestures(
                        onPan: { points in model.viewport.pan(by: points / pixels) },
                        onZoom: { factor, x in
                            // Hold whatever is under the pointer, so a pinch magnifies
                            // the part of the timeline being pointed at.
                            model.viewport.zoom(by: factor, keeping: model.viewport.time(atX: x, across: width))
                        }
                    )
                )
                .clipped()
            }
            .frame(height: contentHeight + 12)
            // Section speed, trims and order are in the inspector, which follows the selection.
            HStack(spacing: 10) {
                Text(model.selectedSegment == nil
                     ? "Click a section to edit it in the inspector. Drag its edges to trim, or drag it to reorder."
                     : "Drag a section's edges to trim it, or drag it to reorder.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if item.info?.hasAudio == true {
                    if overview != nil {
                        Button("Review Silence…") { playback.pause(); reviewingSilence = true }
                    } else if let audioError {
                        Text("Waveform unavailable").font(.caption).foregroundStyle(.secondary).help(audioError)
                    } else { ProgressView().controlSize(.small); Text("Reading audio…").font(.caption) }
                } else { Text("No audio track").font(.caption).foregroundStyle(.secondary) }
            }.controlSize(.small).frame(height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background.opacity(0.5))
        .onAppear { model.syncViewport() }
        .onChange(of: item.editedDuration) { _ in model.syncViewport() }
        .onChange(of: model.previewTime) { time in
            // Only chase the playhead while it is running away on its own; dragging it
            // should not tug the view out from under the pointer.
            if playback.isPlaying { model.viewport.reveal(time) }
        }
        .task(id: item.url) {
            overview = nil; audioError = nil
            model.zoomTimelineToFit()
            guard item.info?.hasAudio == true else { return }
            do {
                let result = try await AudioAnalyzer.analyze(item.url)
                try Task.checkCancellation()
                overview = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled { audioError = error.localizedDescription } }
        }
        .sheet(isPresented: $reviewingSilence) {
            if let overview { SilenceReviewView(clip: item, overview: overview).environmentObject(model) }
        }
    }

    private func scrubGesture(width: Double, pixels: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                playback.pause()
                let time = snap(model.viewport.time(atX: value.location.x, across: width), pixels: pixels, playhead: false)
                model.setPreviewFraction(time / total)
            }
            .onEnded { _ in endSnap() }
    }

    // MARK: Snapping

    /// The targets for one moment of a drag, or nil while snapping is off or ⌥ is held.
    private func snapping(playhead: Bool = true, excludingZoom: UUID? = nil) -> TimelineSnapping? {
        guard model.dragSnaps() else { return nil }
        return TimelineSnapping(timeline: item.timeline, zooms: item.zoomShots,
                                playhead: playhead ? model.previewTime : nil, excludingZoom: excludingZoom)
    }

    /// Where a dragged time lands, showing the guide while it is held by a target.
    private func snap(_ time: Double, pixels: Double, playhead: Bool = true,
                      excludingZoom: UUID? = nil, within range: ClosedRange<Double>? = nil) -> Double {
        let target = snapping(playhead: playhead, excludingZoom: excludingZoom)?
            .target(for: time, pixelsPerSecond: pixels, within: range)
        showGuide(at: target?.time)
        return target?.time ?? time
    }

    /// Where a zoom being moved whole lands: by whichever of its edges is nearer a target.
    private func snapZoom(_ shot: ZoomShot, to start: Double, pixels: Double) -> Double {
        guard let snapping = snapping(excludingZoom: shot.id) else { showGuide(at: nil); return start }
        let landed = snapping.snapSpan(start: start, duration: shot.duration, pixelsPerSecond: pixels)
        showGuide(at: landed.target?.time)
        return landed.start
    }

    private func showGuide(at time: Double?) {
        if snapGuide != time { snapGuide = time }
    }

    private func endSnap() { showGuide(at: nil) }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { model.stepFrame(-1) } label: { Image(systemName: "backward.frame") }
                .help("Previous frame (←)").accessibilityLabel("Previous frame")
            Button { model.togglePlayback() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                .help("Play / pause (Space)").accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button { model.stepFrame(1) } label: { Image(systemName: "forward.frame") }
                .help("Next frame (→)").accessibilityLabel("Next frame")
            Text("\(timelineTime(model.previewTime)) / \(timelineTime(item.editedDuration))")
                .font(.system(.caption, design: .monospaced)).monospacedDigit()
            Spacer(minLength: 4)
            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                .help("Split at the playhead (⌘B)")
            Toggle(isOn: $model.timelineSnapping) {
                Label("Snapping", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
            }
                .toggleStyle(.button)
                .help(model.timelineSnapping
                      ? "Snapping is on: edges line up with the playhead, sections and zooms. Hold ⌥ while dragging to place freely."
                      : "Snapping is off: drags place edges freely.")
                .accessibilityLabel("Snapping")
            zoomControls
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { model.zoomTimeline(in: false) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)").accessibilityLabel("Zoom out")
                .disabled(model.viewport.scale <= 1.0001)
            // The slider is logarithmic: the useful detail is in the first few times
            // magnified, and a linear one spends most of its travel above 30×.
            Slider(value: Binding(
                get: { log(max(1, model.viewport.scale)) / log(TimelineViewport.maximumScale) },
                set: { model.viewport.zoom(to: pow(TimelineViewport.maximumScale, $0), keeping: model.viewportAnchor) }
            ), in: 0...1)
                .frame(width: 68).accessibilityLabel("Timeline magnification")
                .accessibilityValue("\(Int(model.viewport.scale.rounded()))×")
            Button { model.zoomTimeline(in: true) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=)").accessibilityLabel("Zoom in")
                .disabled(model.viewport.scale >= TimelineViewport.maximumScale - 0.0001)
            Button { model.zoomTimelineToFit() } label: { Image(systemName: "arrow.left.and.right") }
                .help("Zoom to fit (⇧Z)").accessibilityLabel("Zoom to fit")
                .disabled(model.viewport.scale <= 1.0001)
        }
    }

    private func ruler(width: Double) -> some View {
        let viewport = model.viewport
        let pixels = viewport.pixels(across: width)
        let fps = item.info?.fps ?? 30
        let interval = TimelineRuler.interval(pixelsPerSecond: pixels, fps: fps)
        let minor = TimelineRuler.minorInterval(interval, pixelsPerSecond: pixels)
        // Enough room for "12:34" or "12:34.29" at 9pt monospace. The last label on the
        // ruler is the only one that can reach past the end, and it loses its text
        // rather than its tick.
        let labelWidth = interval >= 1 ? 34.0 : 46.0
        return ZStack(alignment: .topLeading) {
            Color.primary.opacity(0.001)
            if let minor {
                ForEach(TimelineRuler.ticks(every: minor, in: viewport.start...viewport.end), id: \.self) { tick in
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1, height: 3)
                        .offset(x: viewport.x(of: tick, across: width), y: 15)
                }
            }
            ForEach(TimelineRuler.ticks(every: interval, in: viewport.start...viewport.end), id: \.self) { tick in
                VStack(alignment: .leading, spacing: 3) {
                    if viewport.x(of: tick, across: width) + labelWidth <= width {
                        Text(TimelineRuler.label(tick, interval: interval, fps: fps))
                            .font(.system(size: 9, design: .monospaced))
                            .fixedSize()
                    } else {
                        Color.clear.frame(width: 1, height: 11)
                    }
                    Rectangle().frame(width: 1, height: 4)
                }
                .foregroundStyle(.secondary)
                .offset(x: viewport.x(of: tick, across: width))
            }
        }
        .frame(width: width, height: Self.rulerHeight, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(scrubGesture(width: width, pixels: pixels))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline playhead")
        .accessibilityValue(timelineTime(model.previewTime))
        .accessibilityAdjustableAction { direction in model.stepFrame(direction == .increment ? 1 : -1) }
    }

    private func sectionLane(width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(placedSegments.filter { viewport.intersects($0.offset, $0.offset + $0.segment.duration) },
                    id: \.segment.id) { placed in
                let span = placed.offset...(placed.offset + placed.segment.duration)
                SegmentBlock(segment: placed.segment, offset: placed.offset, number: placed.index + 1, name: item.name,
                             selected: model.selectedSegmentID == placed.segment.id,
                             highlighted: model.agentHighlight?.elements.contains(placed.segment.id) == true,
                             pixels: pixels,
                             // A trim keeps the frame under the edge, so only what lies over
                             // this section's own footage is worth lining up with.
                             snapEdge: { time in snap(time, pixels: pixels, within: span) },
                             endSnap: endSnap,
                             onSelect: { fraction in
                                 model.selectedSegmentID = placed.segment.id
                                 playback.pause()
                                 model.setPreviewFraction((placed.offset + placed.segment.duration * fraction) / total)
                             }, onTrim: { start, end in model.trimSegment(placed.segment.id, start: start, end: end) },
                             onMove: { delta in
                                 let time = placed.offset + placed.segment.duration / 2 + delta / pixels
                                 if let destination = item.timeline.location(at: time)?.index {
                                     model.moveSegment(placed.segment.id, to: destination)
                                 }
                             })
                    .frame(width: max(1, placed.segment.duration * pixels), height: Self.sectionHeight)
                    .offset(x: viewport.x(of: placed.offset, across: width))
            }
        }
        .frame(width: width, height: Self.sectionHeight, alignment: .leading)
        .clipped()
    }

    private func zoomLane(width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
            if item.zoomShots.isEmpty {
                Text("Zoom track · add a zoom at the playhead")
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 9).padding(.top, 7)
            }
            ForEach(item.zoomShots.filter { viewport.intersects($0.start, $0.start + $0.duration) }) { shot in
                ZoomBlock(shot: shot, selected: model.selectedShotID == shot.id,
                          highlighted: model.agentHighlight?.elements.contains(shot.id) == true, pixels: pixels,
                          snapStart: { snapZoom(shot, to: $0, pixels: pixels) },
                          snapEnd: { snap($0, pixels: pixels, excludingZoom: shot.id) },
                          endSnap: endSnap,
                          onSelect: { model.selectedShotID = shot.id; model.editorMode = .zoom },
                          onMove: { model.setZoomStart(shot.id, $0) },
                          onResize: { model.setZoomHold(shot.id, $0) })
                    .frame(width: max(3, shot.duration * pixels), height: Self.zoomHeight)
                    .offset(x: viewport.x(of: shot.start, across: width))
            }
        }
        .frame(width: width, height: Self.zoomHeight, alignment: .leading)
        .clipped()
    }

    private func playhead(width: Double) -> some View {
        let time = model.previewTime
        return Rectangle().fill(Color.primary)
            .frame(width: 1.5, height: contentHeight - 4)
            .offset(x: model.viewport.x(of: time, across: width))
            .opacity(model.viewport.contains(time) ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// The line a snapped edge is holding to.
    private func guide(width: Double) -> some View {
        let time = snapGuide ?? 0
        return Rectangle().fill(Color.accentColor)
            .frame(width: 1, height: contentHeight)
            .offset(x: model.viewport.x(of: time, across: width))
            .opacity(snapGuide != nil && model.viewport.contains(time) ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SegmentBlock: View {
    let segment: TimelineSegment
    /// Where the section starts on the timeline.
    let offset: Double
    let number: Int
    let name: String
    let selected: Bool
    /// An agent just changed this section: outlined for a moment, never selected.
    var highlighted = false
    let pixels: Double
    /// Where a trimmed edge dragged to a timeline time lands.
    let snapEdge: (Double) -> Double
    let endSnap: () -> Void
    let onSelect: (Double) -> Void
    let onTrim: (Double?, Double?) -> Void
    let onMove: (Double) -> Void
    @State private var moveDelta = 0.0
    @State private var trimDelta = 0.0
    @State private var trimmingStart = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(selected ? 0.42 : 0.2))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(number) · \(name)").font(.caption.weight(.medium)).lineLimit(1)
                    Text("\(timelineTime(segment.start)) – \(timelineTime(segment.end))\(segment.speed == 1 ? "" : " · \(segment.speed.formatted())×")")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.horizontal, 13).frame(maxWidth: .infinity, alignment: .leading)
                RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange, lineWidth: 2.5)
                    .shadow(color: .orange.opacity(0.6), radius: 4)
                    .opacity(highlighted ? 1 : 0)
                    .animation(.easeOut(duration: 0.35), value: highlighted)
                    .allowsHitTesting(false)
                HStack {
                    handle(start: true).offset(x: trimDelta != 0 && trimmingStart ? trimDelta : 0)
                    Spacer(minLength: 0)
                    handle(start: false).offset(x: trimDelta != 0 && !trimmingStart ? trimDelta : 0)
                }
                if trimDelta != 0 {
                    Text(timelineTime((trimmingStart ? segment.start : segment.end) + trimDelta / pixels * segment.speed))
                        .font(.system(.caption, design: .monospaced)).padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in onSelect(min(1, max(0, location.x / max(1, geo.size.width)))) }
            .gesture(DragGesture(minimumDistance: 12)
                .onChanged { moveDelta = $0.translation.width }
                .onEnded { value in onMove(value.translation.width); moveDelta = 0 })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Section \(number), \(timelineTime(segment.duration))")
        }
        .padding(.horizontal, 1)
        .offset(x: moveDelta)
        .zIndex(moveDelta == 0 ? 0 : 1)
    }

    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(selected ? 1 : 0.45))
            .frame(width: 7).padding(.vertical, 5).padding(.horizontal, 3)
            .contentShape(Rectangle())
            // Global, so the handle following the pointer does not shift the space its
            // own drag is measured in.
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in trimmingStart = start; trimDelta = travel(start: start, value.translation.width) }
                .onEnded { value in
                    let delta = travel(start: start, value.translation.width) / pixels * segment.speed
                    onTrim(start ? segment.start + delta : nil, start ? nil : segment.end + delta)
                    trimDelta = 0
                    endSnap()
                })
            .help(start ? "Drag to trim the start" : "Drag to trim the end")
            .accessibilityLabel(start ? "Trim section start" : "Trim section end")
    }

    /// Points an edge travels for a drag of `translation`, once snapped.
    private func travel(start: Bool, _ translation: Double) -> Double {
        let edge = offset + (start ? 0 : segment.duration)
        return (snapEdge(edge + translation / pixels) - edge) * pixels
    }
}

private struct ZoomBlock: View {
    let shot: ZoomShot
    let selected: Bool
    var highlighted = false
    let pixels: Double
    /// Where the zoom lands when moved to start at a time, and where its end lands.
    let snapStart: (Double) -> Double
    let snapEnd: (Double) -> Double
    let endSnap: () -> Void
    let onSelect: () -> Void
    let onMove: (Double) -> Void
    let onResize: (Double) -> Void
    @State private var delta = 0.0
    @State private var resize = 0.0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                Image(systemName: "plus.magnifyingglass")
                Text(shot.levelLabel).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .frame(width: max(8, geo.size.width + resize), height: 28)
            .background(Color.cyan.opacity(selected ? 0.45 : 0.23), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.cyan.opacity(selected ? 1 : 0.5)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange, lineWidth: 2.5)
                .shadow(color: .orange.opacity(0.6), radius: 4)
                .opacity(highlighted ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: highlighted)
                .allowsHitTesting(false))
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in delta = (movedStart(value.translation.width) - shot.start) * pixels }
                .onEnded { value in
                    onSelect(); onMove(movedStart(value.translation.width)); delta = 0; endSnap()
                })
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 2).fill(Color.cyan).frame(width: 5, height: 16).padding(.trailing, 3)
                    .contentShape(Rectangle())
                    .highPriorityGesture(DragGesture(minimumDistance: 1)
                        .onChanged { resize = (resizedEnd($0.translation.width) - shot.end) * pixels }
                        .onEnded { value in
                            onSelect(); onResize(shot.hold + resizedEnd(value.translation.width) - shot.end)
                            resize = 0; endSnap()
                        })
                    .help("Drag to change zoom duration")
            }
            .offset(x: delta)
            .help("Drag to move this zoom; drag its right edge to change duration")
            .accessibilityLabel("\(shot.levelLabel) zoom at \(timelineTime(shot.start))")
        }
    }

    private func movedStart(_ translation: Double) -> Double { snapStart(shot.start + translation / pixels) }
    private func resizedEnd(_ translation: Double) -> Double { snapEnd(shot.end + translation / pixels) }
}

struct TimelineTimeField: View {
    let label: String
    let value: Double
    let onCommit: (Double) -> Double
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            TextField("Seconds", text: $text).frame(width: 58).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit(commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
                .accessibilityLabel("Section \(label.lowercased()) in seconds")
        }.font(.system(.caption, design: .monospaced))
        .onAppear { text = String(format: "%.3f", value) }
        .onChange(of: value) { _, value in if !focused { text = String(format: "%.3f", value) } }
    }
    private func commit() {
        let committed: Double
        if let seconds = Double(text), seconds.isFinite, abs(seconds - value) > 0.0005 {
            committed = onCommit(seconds)
        } else { committed = value }
        text = String(format: "%.3f", committed)
    }
}

// MARK: - Trackpad

/// Two-finger scroll and pinch over the timeline.
///
/// SwiftUI on macOS 14 surfaces neither, and a timeline needs both: two fingers travel
/// along the recording, a pinch magnifies it. The view never takes part in hit testing,
/// so clicks, drags and trims underneath behave exactly as they did; it watches for the
/// two event kinds it wants and lets everything else past.
private struct TimelineGestures: NSViewRepresentable {
    /// Points to travel; positive moves the view later in the recording.
    var onPan: (Double) -> Void
    /// A magnification factor, and the x in view coordinates to hold still.
    var onZoom: (Double, Double) -> Void

    final class Catcher: NSView {
        var onPan: ((Double) -> Void)?
        var onZoom: ((Double, Double) -> Void)?
        private var monitor: Any?

        /// Never intercept the mouse: the sections below are still the things being
        /// clicked, dragged and trimmed.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                switch event.type {
                case .magnify:
                    self.onZoom?(1 + Double(event.magnification), Double(local.x))
                case .scrollWheel:
                    if event.modifierFlags.contains(.command) {
                        // A trackpad reports many small deltas and a wheel a few large
                        // ones; an exponent turns both into a smooth factor.
                        self.onZoom?(pow(1.01, Double(event.scrollingDeltaY)), Double(local.x))
                    } else {
                        // Horizontal intent wins, but a plain wheel with only a vertical
                        // delta should still travel along an axis that is the only one
                        // there is.
                        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                        self.onPan?(-Double(delta))
                    }
                default:
                    return event
                }
                return nil
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.onPan = onPan
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
    }
}
