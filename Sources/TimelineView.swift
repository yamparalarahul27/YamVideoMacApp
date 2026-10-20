import AVFoundation
import SwiftUI

/// The timeline, laid out as Filmora lays it out: a tool bar above it, a header for each
/// row at the left, and the rows from what draws over the picture down to its sound.
struct TimelineView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var playback: PlaybackController
    let item: VideoItem
    @ObservedObject private var filmstrip = FilmstripCache.shared
    @State private var overview: AudioOverview?
    @State private var audioError: String?
    @State private var reviewingSilence = false
    /// Where a drag has snapped to, drawn as a guide for as long as it holds.
    @State private var snapGuide: Double?
    /// The pointer is over the rows: the playhead shows its scissors.
    @State private var hovering = false
    /// The quiet parts still in the edit, worked out once for each cut, not each frame.
    @State private var pauses: [ClosedRange<Double>] = []
    /// The captions on the edited timeline, worked out once for each change.
    @State private var cues: [CaptionCue] = []
    /// The sound levels of each music file, for the bars on the Music row.
    @State private var musicLevels: [URL: AudioOverview] = [:]

    // Row geometry. Every height below derives from these, so adding a row is one entry
    // rather than magic numbers that have to be kept in step.
    private static let rulerHeight = 22.0
    private static let foldedHeight = 16.0
    private static let headerWidth = 122.0
    private static let zoomHeight = 28.0
    private static let effectHeight = 22.0
    private static let blurBandHeight = 10.0
    /// Two rows: column graphics above, panel graphics below.
    private static let graphicsRowHeight = 17.0
    private static let graphicsHeight = graphicsRowHeight * 2 + 4
    private static let shortsHeight = 20.0
    private static let layoutHeight = 22.0
    private static let captionsHeight = 24.0
    private static let laneSpacing = 4.0
    static let speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private var sectionHeight: Double { model.timelineTallTracks ? 64 : 44 }
    private var waveformHeight: Double { model.timelineTallTracks ? 52 : 30 }
    private var musicHeight: Double { model.timelineTallTracks ? 36 : 24 }

    private var tracks: [TimelineTrack] { TimelineTrack.tracks(for: item) }
    private func folded(_ track: TimelineTrack) -> Bool { track.isEmpty(in: item) }
    private func hidden(_ track: TimelineTrack) -> Bool { model.timelineTracks.hidden.contains(track) }
    private func locked(_ track: TimelineTrack) -> Bool { model.timelineTracks.locked.contains(track) }
    /// The row's change is switched off in the inspector: kept, but not in the video.
    private func switchedOff(_ track: TimelineTrack) -> Bool {
        switch track {
        case .graphics: return !item.isOn(.graphics)
        case .zoom: return !item.isOn(.zooms)
        case .music: return !item.isOn(.music)
        default: return false
        }
    }

    private func height(of track: TimelineTrack) -> Double {
        if folded(track) { return Self.foldedHeight }
        switch track {
        case .shorts: return Self.shortsHeight
        case .graphics: return Self.graphicsHeight
        case .effects: return Self.effectHeight + (item.blurRegions.isEmpty ? 0 : Self.blurBandHeight + 2)
        case .zoom, .screenZoom: return Self.zoomHeight
        case .screenLayout: return Self.layoutHeight
        case .video: return sectionHeight
        case .audio: return overview == nil ? 20 : waveformHeight
        case .music: return musicHeight
        case .captions: return Self.captionsHeight
        }
    }

    private var laneHeights: [Double] { [Self.rulerHeight] + tracks.map(height(of:)) }

    private var contentHeight: Double {
        laneHeights.reduce(0, +) + Self.laneSpacing * Double(laneHeights.count - 1)
    }

    /// Where a row starts, down from the top of the ruler.
    private func top(of track: TimelineTrack) -> Double {
        var y = Self.rulerHeight + Self.laneSpacing
        for row in tracks {
            if row == track { return y }
            y += height(of: row) + Self.laneSpacing
        }
        return y
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
        VStack(spacing: 6) {
            toolbar
            HStack(alignment: .top, spacing: 0) {
                headers
                    .frame(width: Self.headerWidth, height: contentHeight, alignment: .top)
                GeometryReader { geo in
                    let width = max(1, geo.size.width - 2)
                    let pixels = model.viewport.pixels(across: width)
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: Self.laneSpacing) {
                            ruler(width: width)
                            ForEach(tracks) { track in
                                lane(track, width: width, pixels: pixels)
                                    .frame(width: width, height: height(of: track), alignment: .leading)
                                    .opacity(hidden(track) || switchedOff(track) ? 0.4 : 1)
                                    .allowsHitTesting(!locked(track))
                            }
                        }
                        playhead(width: width)
                        guide(width: width)
                        scissors(width: width)
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
                    .onHover { hovering = $0 }
                    .dropDestination(for: String.self) { texts, location in
                        guard let asset = texts.lazy.compactMap(MediaAsset.init(dragText:)).first else { return false }
                        model.add(asset, at: model.viewport.time(atX: location.x, across: width))
                        return true
                    }
                }
                .frame(height: contentHeight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(.background.opacity(0.5))
        .onAppear { model.syncViewport() }
        .onChange(of: item.editedDuration) { _, _ in model.syncViewport() }
        .onChange(of: item.gapLayout) { _, _ in model.syncViewport() }
        .onChange(of: model.previewTime) { _, time in
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
        .task(id: PausesKey(segments: item.timeline.segments, ready: overview != nil)) {
            pauses = overview?.pauses(in: item.timeline, fps: item.info?.fps ?? 30) ?? []
        }
        .task(id: CaptionsKey(segments: item.timeline.segments, transcript: item.transcript, file: item.subtitles)) {
            cues = item.captionCues()
        }
        .task(id: Set(item.music?.pieces.map(\.url) ?? [])) {
            for url in Set(item.music?.pieces.map(\.url) ?? []) where musicLevels[url] == nil {
                guard let levels = try? await AudioAnalyzer.analyze(url), !Task.isCancelled else { continue }
                musicLevels[url] = levels
            }
        }
        .sheet(isPresented: $reviewingSilence) {
            if let overview {
                SilenceReviewView(clip: item, overview: overview,
                                  stumbles: item.transcript.map { StumbleFinder.stumbles(in: $0.words) } ?? [])
                    .environmentObject(model)
            }
        }
    }

    private struct PausesKey: Equatable { let segments: [TimelineSegment]; let ready: Bool }
    private struct CaptionsKey: Equatable { let segments: [TimelineSegment]; let transcript: Transcript?; let file: URL? }

    private func scrubGesture(width: Double, pixels: Double, minimumDistance: Double = 0) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance)
            .onChanged { value in
                playback.pause()
                let time = snap(model.viewport.time(atX: value.location.x, across: width), pixels: pixels, playhead: false)
                model.setPreviewFraction(time / total)
            }
            .onEnded { _ in endSnap() }
    }

    // MARK: Snapping

    /// The targets for one moment of a drag, or nil while snapping is off or ⌥ is held.
    private func snapping(playhead: Bool = true, excluding: UUID? = nil) -> TimelineSnapping? {
        guard model.dragSnaps() else { return nil }
        return TimelineSnapping(timeline: item.timeline, zooms: item.zoomShots, effects: item.blurEffects, markers: item.markers,
                                playhead: playhead ? model.previewTime : nil, excluding: excluding)
    }

    /// Where a dragged time lands, showing the guide while it is held by a target.
    private func snap(_ time: Double, pixels: Double, playhead: Bool = true,
                      excluding: UUID? = nil, within range: ClosedRange<Double>? = nil) -> Double {
        let target = snapping(playhead: playhead, excluding: excluding)?
            .target(for: time, pixelsPerSecond: pixels, within: range)
        showGuide(at: target?.time)
        return target?.time ?? time
    }

    /// Where a block moved whole lands — a zoom or an effect — by whichever of its edges
    /// is nearer a target.
    private func snapSpan(_ id: UUID, start: Double, duration: Double, pixels: Double) -> Double {
        guard let snapping = snapping(excluding: id) else { showGuide(at: nil); return start }
        let landed = snapping.snapSpan(start: start, duration: duration, pixelsPerSecond: pixels)
        showGuide(at: landed.target?.time)
        return landed.start
    }

    private func showGuide(at time: Double?) {
        if snapGuide != time { snapGuide = time }
    }

    private func endSnap() { showGuide(at: nil) }

    // MARK: Tool bar

    /// The edit tools sit here, above the rows, as in Filmora: undo, the tools that act on
    /// the selection or at the playhead, then how the timeline looks.
    private var toolbar: some View {
        HStack(spacing: 1) {
            tool("arrow.uturn.backward", model.undoTitle + " (⌘Z)", label: "Undo") { model.undoEdit() }
                .disabled(!model.canUndoInModule)
            tool("arrow.uturn.forward", model.redoTitle + " (⇧⌘Z)", label: "Redo") { model.redoEdit() }
                .disabled(!model.canRedoInModule)
            toolDivider
            tool("trash", "Delete the selection (⌫; sections ⌘⌫). A deleted section leaves its space, so nothing else moves; ⇧⌘⌫ deletes and closes it.", label: "Delete") { model.deleteSelection() }
                .disabled(!model.canDeleteSelection)
            tool("scissors", "Split at the playhead (⌘B)", label: "Split") { model.splitAtPlayhead() }
                .disabled(locked(.video))
            tool("crop", "Crop the frame (⌥C)", label: "Crop") { model.beginCrop() }
            speedMenu
            tool("viewfinder", "Add a zoom at the playhead", label: "Add zoom") { model.addZoomFromTimeline() }
                .disabled(locked(.zoom))
            tool("camera.filters", "Add a full-frame blur at the playhead", label: "Add blur") { model.addBlurEffect() }
                .disabled(locked(.effects))
            tool("flag", "Add a marker at the playhead (M)", label: "Add marker") { model.addMarkerAtPlayhead() }
            if !item.gaps.isEmpty {
                toolDivider
                Button { model.closeGaps() } label: { Label("Close Gaps", systemImage: "arrow.right.to.line.compact") }
                    .labelStyle(.titleAndIcon)
                    .disabled(locked(.video))
                    .help("Join the sections on the timeline (⌥⌘G). Playback and exports already join them.")
            }
            toolDivider
            Button { model.showingAutoEdit = true } label: { Label("Auto Edit", systemImage: "wand.and.stars") }
                .labelStyle(.titleAndIcon)
                .help("Transcribe, cut pauses and stumbles, and set captions and loudness (⇧⌘E)")
            Group {
                if item.info?.hasAudio == true {
                    Button { playback.pause(); reviewingSilence = true } label: { Label("Review Silence", systemImage: "waveform") }
                        .labelStyle(.titleAndIcon)
                        .disabled(overview == nil)
                        .help("Review the pauses before you cut them")
                }
            }
            Spacer(minLength: 6)
            Toggle(isOn: $model.timelineSnapping) {
                Label("Snapping", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
            }
                .toggleStyle(.button).labelStyle(.iconOnly)
                .help(model.timelineSnapping
                      ? "Snapping is on (N): edges line up with the playhead, sections and zooms. Hold ⌥ while dragging to place freely."
                      : "Snapping is off (N): drags place edges freely.")
                .accessibilityLabel("Snapping")
            Toggle(isOn: $model.timelineTallTracks) {
                Label("Tall rows", systemImage: "rectangle.expand.vertical")
            }
                .toggleStyle(.button).labelStyle(.iconOnly)
                .help(model.timelineTallTracks ? "Tall rows: bigger frames and waveform. Click for short rows." : "Short rows. Click for tall rows with bigger frames.")
                .accessibilityLabel("Tall rows")
            toolDivider
            zoomControls
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .frame(height: 24)
    }

    private func tool(_ symbol: String, _ help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 20) }
            .help(help)
            .accessibilityLabel(label)
    }

    private var toolDivider: some View {
        Divider().frame(height: 16).padding(.horizontal, 5)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { speed in
                Button(speed == 1 ? "Normal Speed (1×)" : "\(speed.formatted())×") { model.setSelectedSectionsSpeed(speed) }
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26)
        .disabled(model.sectionSelection.isEmpty || locked(.video))
        .help("Speed of the selected sections")
        .accessibilityLabel("Speed")
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { model.zoomTimeline(in: false) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)").accessibilityLabel("Zoom out")
                .disabled(model.viewport.scale <= 1.0001)
            // The slider is logarithmic: the useful detail is in the first few times
            // magnified, and a linear one spends most of its travel above 30×.
            Slider(value: Binding(
                get: { log(max(1, model.viewport.scale)) / log(TimelineViewport.maximumScale) },
                set: { model.viewport.zoom(to: pow(TimelineViewport.maximumScale, $0), keeping: model.viewportAnchor) }
            ), in: 0...1)
                .frame(width: 80).accessibilityLabel("Timeline magnification")
                .accessibilityValue("\(Int(model.viewport.scale.rounded()))×")
            Button { model.zoomTimeline(in: true) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=)").accessibilityLabel("Zoom in")
                .disabled(model.viewport.scale >= TimelineViewport.maximumScale - 0.0001)
            Button { model.zoomTimelineToFit() } label: { Image(systemName: "arrow.left.and.right") }
                .help("Zoom to fit (⇧Z)").accessibilityLabel("Zoom to fit")
                .disabled(model.viewport.scale <= 1.0001)
        }
    }

    // MARK: Row headers

    private var headers: some View {
        VStack(alignment: .leading, spacing: Self.laneSpacing) {
            // The ruler's corner: where the playhead is.
            HStack {
                Text(timelineTime(model.previewTime)).font(.system(size: 10, design: .monospaced)).monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .frame(height: Self.rulerHeight)
            .accessibilityLabel("Playhead at \(timelineTime(model.previewTime))")
            ForEach(tracks) { track in
                header(track).frame(height: height(of: track))
            }
        }
        .padding(.trailing, 6)
    }

    private func header(_ track: TimelineTrack) -> some View {
        let isFolded = folded(track)
        return HStack(spacing: 2) {
            Image(systemName: track.symbol)
                .font(.system(size: isFolded ? 9 : 10))
                .foregroundStyle(tint(track).opacity(isFolded ? 0.6 : 1))
                .frame(width: 15)
            Text(track.label)
                .font(.system(size: isFolded ? 9.5 : 10.5, weight: isFolded ? .regular : .medium))
                .foregroundStyle(isFolded ? .tertiary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isFolded {
                if let add = addAction(track) {
                    Button(action: add.action) { Image(systemName: "plus").font(.system(size: 9, weight: .semibold)) }
                        .help(add.help).accessibilityLabel(add.help)
                }
            } else {
                if track.hides {
                    headerButton(hidden(track) ? "eye.slash" : "eye", on: hidden(track),
                                 help: hidden(track) ? "Show \(track.label.lowercased()) in the preview" : "Hide \(track.label.lowercased()) in the preview. The export keeps it.") {
                        model.toggleTrackHidden(track)
                    }
                }
                if track == .audio, item.info?.hasAudio == true {
                    headerButton(model.timelineTracks.muted ? "speaker.slash" : "speaker.wave.2", on: model.timelineTracks.muted,
                                 help: model.timelineTracks.muted ? "Turn the preview sound on" : "Mute the preview. The export keeps its sound.") {
                        model.toggleTrackMuted()
                    }
                }
                if track == .music {
                    let off = hidden(.music)
                    headerButton(off ? "speaker.slash" : "speaker.wave.2", on: off,
                                 help: off ? "Play the music in the preview" : "Mute the music in the preview. The export keeps it.") {
                        model.toggleMusicMuted()
                    }
                    if let add = addAction(.music) {
                        Button(action: add.action) { Image(systemName: "plus").font(.system(size: 9, weight: .semibold)) }
                            .help(add.help).accessibilityLabel(add.help)
                            .disabled(locked(.music))
                    }
                }
                if track.locks {
                    headerButton(locked(track) ? "lock.fill" : "lock.open", on: locked(track),
                                 help: locked(track) ? "Unlock \(track.label.lowercased())" : "Lock \(track.label.lowercased()), so the timeline does not change it") {
                        model.toggleTrackLocked(track)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 5)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(isFolded ? 0.18 : 0.4)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFolded ? "\(track.label), empty" : track.label)
    }

    private func headerButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(on ? Color.orange : Color.secondary)
                .frame(width: 18, height: 16)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private func tint(_ track: TimelineTrack) -> Color {
        switch track {
        case .shorts: return .pink
        case .graphics: return .purple
        case .effects: return .orange
        case .zoom: return .cyan
        case .screenLayout: return .teal
        case .screenZoom: return .indigo
        case .video: return .accentColor
        case .audio: return .teal
        case .music: return .mint
        case .captions: return .yellow
        }
    }

    /// What the + on an empty row adds, at the playhead.
    private func addAction(_ track: TimelineTrack) -> (help: String, action: () -> Void)? {
        switch track {
        case .shorts: return ("Add a Short at the playhead", { model.addShortAtPlayhead() })
        case .graphics: return ("Import a graphics file", { model.chooseGraphicsFile() })
        case .effects: return ("Add a full-frame blur at the playhead", { model.addBlurEffect() })
        case .zoom: return ("Add a zoom at the playhead", { model.addZoomFromTimeline() })
        case .screenZoom: return ("Add a screen zoom at the playhead", { model.addScreenZoomAtPlayhead() })
        case .captions: return ("Choose a caption file. Auto Edit makes captions from what is said.", { model.chooseSubtitles() })
        case .music:
            guard item.info?.hasAudio == true else { return nil }
            return ("Add music under the voice, at the playhead", { model.chooseMusicFile() })
        case .screenLayout, .video, .audio: return nil
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func lane(_ track: TimelineTrack, width: Double, pixels: Double) -> some View {
        if folded(track) {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.18))
        } else {
            switch track {
            case .shorts: shortsLane(width: width, pixels: pixels)
            case .graphics: graphicsLane(width: width, pixels: pixels)
            case .effects: effectLane(width: width, pixels: pixels)
            case .zoom: zoomLane(width: width, pixels: pixels)
            case .screenLayout:
                if let screen = item.screen { layoutLane(screen, width: width, pixels: pixels) }
            case .screenZoom:
                if let screen = item.screen { screenZoomLane(screen, width: width, pixels: pixels) }
            case .video: sectionLane(width: width, pixels: pixels)
            case .audio: audioLane(width: width, pixels: pixels)
            case .music: musicLane(width: width, pixels: pixels)
            case .captions: captionsLane(width: width, pixels: pixels)
            }
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
                ForEach(TimelineRuler.ticks(every: minor, in: viewport.editedStart...viewport.editedEnd), id: \.self) { tick in
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1, height: 3)
                        .offset(x: viewport.x(of: tick, across: width), y: 15)
                }
            }
            ForEach(TimelineRuler.ticks(every: interval, in: viewport.editedStart...viewport.editedEnd), id: \.self) { tick in
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
        .overlay(alignment: .topLeading) {
            // Markers fly in the ruler, not a row of their own.
            ForEach(item.markers.filter { viewport.contains($0.time) }) { marker in
                MarkerFlag(marker: marker, selected: model.selectedMarkerID == marker.id) { model.selectMarker(marker) }
                    .offset(x: viewport.x(of: marker.time, across: width) - 7, y: 3)
            }
        }
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
        let height = sectionHeight
        let aspect = item.info.map { Double($0.width) / Double(max(1, $0.height)) } ?? 16.0 / 9.0
        let tileWidth = max(24, height * aspect)
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(placedSegments.filter { (item.gaps[$0.segment.id] ?? 0) >= SectionGap.minimum
                && viewport.intersects($0.offset, $0.offset) }, id: \.segment.id) { placed in
                let from = viewport.x(ofEnd: placed.offset, across: width)
                GapBlock(length: item.gaps[placed.segment.id] ?? 0, width: viewport.x(of: placed.offset, across: width) - from,
                         locked: locked(.video),
                         onClose: { model.closeGap(before: placed.segment.id) },
                         onCloseAll: { model.closeGaps() })
                    .frame(width: max(1, viewport.x(of: placed.offset, across: width) - from), height: height)
                    .offset(x: from)
            }
            ForEach(placedSegments.filter { viewport.intersects($0.offset, $0.offset + $0.segment.duration) },
                    id: \.segment.id) { placed in
                let span = placed.offset...(placed.offset + placed.segment.duration)
                SegmentBlock(segment: placed.segment, offset: placed.offset, number: placed.index + 1,
                             selected: model.sectionSelection.contains(placed.segment.id),
                             highlighted: model.agentHighlight?.elements.contains(placed.segment.id) == true,
                             pixels: pixels,
                             badges: item.badges(for: placed.segment, settings: model.settings),
                             frames: Filmstrip.tiles(for: placed.segment, offset: placed.offset, viewport: viewport,
                                                     width: width, tileWidth: tileWidth)
                                .map { FilmstripFrame(x: $0.x, image: filmstrip.image(for: item.url, at: $0.source)) },
                             tileWidth: tileWidth,
                             // A trim keeps the frame under the edge, so only what lies over
                             // this section's own footage is worth lining up with.
                             snapEdge: { time in snap(time, pixels: pixels, within: span) },
                             endSnap: endSnap,
                             onSelect: { fraction in
                                 let modifiers = NSEvent.modifierFlags
                                 model.clickSegment(placed.segment.id, at: placed.offset + placed.segment.duration * fraction,
                                                    extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
                             }, onTrim: { start, end in model.trimSegment(placed.segment.id, start: start, end: end) },
                             onMove: { delta in moveSection(placed, by: delta, width: width, pixels: pixels) })
                    .frame(width: max(1, placed.segment.duration * pixels), height: height)
                    .offset(x: viewport.x(of: placed.offset, across: width))
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }

    /// The recording's sound under its sections, following every cut and speed change.
    /// It is linked to the picture: a click selects the section, the selected section's
    /// sound shows with it, and the pauses still in the edit are marked.
    @ViewBuilder
    private func audioLane(width: Double, pixels: Double) -> some View {
        if let overview {
            let viewport = model.viewport
            ZStack(alignment: .topLeading) {
                ForEach(placedSegments.filter { model.sectionSelection.contains($0.segment.id)
                    && viewport.intersects($0.offset, $0.offset + $0.segment.duration) }, id: \.segment.id) { placed in
                    RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5))
                        .frame(width: max(1, placed.segment.duration * pixels), height: waveformHeight)
                        .offset(x: viewport.x(of: placed.offset, across: width))
                }
                ForEach(Array(pauses.enumerated()).filter { viewport.intersects($0.element.lowerBound, $0.element.upperBound) }, id: \.offset) { _, pause in
                    Rectangle().fill(Color.yellow.opacity(0.16))
                        .frame(width: max(1, viewport.width(from: pause.lowerBound, to: pause.upperBound, across: width)), height: waveformHeight)
                        .offset(x: viewport.x(of: pause.lowerBound, across: width))
                        .help("A pause of \(String(format: "%.1f", pause.upperBound - pause.lowerBound)) s. Review Silence can cut it.")
                }
                WaveformView(overview: overview, timeline: item.timeline, window: viewport)
                    .frame(width: width, height: waveformHeight)
                    .allowsHitTesting(false)
                ForEach(placedSegments.dropFirst().filter { viewport.contains($0.offset) }, id: \.segment.id) { placed in
                    Rectangle().fill(Color.primary.opacity(0.4))
                        .frame(width: 1, height: waveformHeight)
                        .offset(x: viewport.x(of: placed.offset, across: width))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: waveformHeight, alignment: .leading)
            .clipped()
            .opacity(model.timelineTracks.muted ? 0.4 : 1)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard !viewport.inGap(atX: location.x, across: width) else { return }
                let time = viewport.time(atX: location.x, across: width)
                guard let placed = placedSegments.first(where: { time >= $0.offset && time < $0.offset + $0.segment.duration }) else { return }
                let modifiers = NSEvent.modifierFlags
                model.clickSegment(placed.segment.id, at: time, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
            }
            .simultaneousGesture(scrubGesture(width: width, pixels: pixels, minimumDistance: 3))
            .help("Click to select a section, with its picture. Drag to move the playhead. Yellow marks a pause.")
        } else {
            HStack(spacing: 6) {
                if item.info?.hasAudio != true {
                    Text("No audio track")
                } else if let audioError {
                    Text("Waveform unavailable").help(audioError)
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Reading audio…")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.leading, 9)
            .frame(width: width, alignment: .leading)
        }
    }

    /// The captions as the export shows them. A click selects one, so its words can be
    /// fixed in the inspector.
    private func captionsLane(width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        let off = model.settings.captionUse(hasFile: item.subtitles != nil) == .off
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.35))
            ForEach(cues.filter { viewport.intersects($0.start, $0.end) }) { cue in
                let selected = model.inspectorFocus == .caption && model.selectedCaptionIndex == cue.index
                let span = max(2, viewport.width(from: cue.start, to: cue.end, across: width) - 1)
                Text(span > 28 ? cue.text : "")
                    .font(.system(size: 9.5))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(width: span, height: Self.captionsHeight - 6, alignment: .leading)
                    .background(Color.yellow.opacity(selected ? 0.6 : 0.18), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.yellow).frame(width: 2) }
                    .foregroundStyle(selected ? Color.black : Color.primary)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playback.pause()
                        model.selectedCaptionIndex = cue.index
                        model.setPreviewFraction(min(cue.start + 0.05, cue.end) / total)
                    }
                    .help(cue.text)
                    .offset(x: viewport.x(of: cue.start, across: width), y: 3)
            }
        }
        .frame(width: width, height: Self.captionsHeight, alignment: .leading)
        .opacity(off ? 0.45 : 1)
        .clipped()
    }

    /// The screen's layouts over its base layout.
    private func layoutLane(_ screen: ScreenTrack, width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(screen.layout.tint.opacity(0.1))
            HStack(spacing: 3) {
                Image(systemName: screen.layout.symbol)
                Text(screen.spans.isEmpty ? "\(screen.layout.label) throughout · add a layout at the playhead in the inspector"
                     : "\(screen.layout.label) elsewhere")
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 9).padding(.top, 4)
            .allowsHitTesting(false)
            ForEach(screen.spans.filter { viewport.intersects($0.start, $0.end) }) { span in
                let space = BlockSpace(viewport, width: width, from: span.start, to: span.end)
                LayoutBlock(span: span, selected: model.selectedLayoutID == span.id,
                            highlighted: model.agentHighlight?.elements.contains(span.id) == true, pixels: space.pixels,
                            snapStart: { space.block(snapSpan(span.id, start: space.time($0), duration: span.duration, pixels: pixels)) },
                            snapEdge: { space.block(snap(space.time($0), pixels: pixels, excluding: span.id)) },
                            endSnap: endSnap,
                            onSelect: { model.selectLayout(span) },
                            onMove: { start in let start = space.time(start); model.updateLayout(span.id) { $0.end = start + $0.duration; $0.start = start } },
                            onTrim: { start, end in
                                let start = start.map(space.time), end = end.map(space.time)
                                model.updateLayout(span.id) { if let start { $0.start = start }; if let end { $0.end = end } }
                            })
                    .frame(height: Self.layoutHeight)
                    .offset(x: viewport.x(of: span.start, across: width))
            }
        }
        .frame(width: width, height: Self.layoutHeight, alignment: .leading)
        .clipped()
    }

    /// Zooms on the screen recording, as the zoom row shows the recording's own.
    private func screenZoomLane(_ screen: ScreenTrack, width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.indigo.opacity(0.08))
            ForEach(screen.zooms.filter { viewport.intersects($0.start, $0.end) }) { shot in
                let space = BlockSpace(viewport, width: width, from: shot.start, to: shot.end)
                ZoomBlock(shot: shot, selected: model.selectedScreenZoomID == shot.id,
                          highlighted: model.agentHighlight?.elements.contains(shot.id) == true, pixels: space.pixels,
                          snapStart: { space.block(snapSpan(shot.id, start: space.time($0), duration: shot.duration, pixels: pixels)) },
                          snapEnd: { space.block(snap(space.time($0), pixels: pixels, excluding: shot.id), end: true) },
                          endSnap: endSnap,
                          onSelect: { model.selectScreenZoom(shot) },
                          onMove: { model.setScreenZoomStart(shot.id, space.time($0)) },
                          onResize: { model.setScreenZoomHold(shot.id, space.hold($0, of: shot)) },
                          tint: .indigo, symbol: "macwindow")
                    .frame(width: max(3, space.points), height: Self.zoomHeight)
                    .offset(x: viewport.x(of: shot.start, across: width))
            }
        }
        .frame(width: width, height: Self.zoomHeight, alignment: .leading)
        .clipped()
    }

    private func zoomLane(width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
            ForEach(item.zoomShots.filter { viewport.intersects($0.start, $0.start + $0.duration) }) { shot in
                let space = BlockSpace(viewport, width: width, from: shot.start, to: shot.end)
                ZoomBlock(shot: shot, selected: model.selectedShotID == shot.id,
                          highlighted: model.agentHighlight?.elements.contains(shot.id) == true, pixels: space.pixels,
                          snapStart: { space.block(snapSpan(shot.id, start: space.time($0), duration: shot.duration, pixels: pixels)) },
                          snapEnd: { space.block(snap(space.time($0), pixels: pixels, excluding: shot.id), end: true) },
                          endSnap: endSnap,
                          onSelect: { model.selectedShotID = shot.id },
                          onMove: { model.setZoomStart(shot.id, space.time($0)) },
                          onResize: { model.setZoomHold(shot.id, space.hold($0, of: shot)) })
                    .frame(width: max(3, space.points), height: Self.zoomHeight)
                    .offset(x: viewport.x(of: shot.start, across: width))
            }
        }
        .frame(width: width, height: Self.zoomHeight, alignment: .leading)
        .clipped()
    }

    /// Full-frame blurs on top, and under them a band for the blur areas, which hide their
    /// part of the picture for the whole video.
    private func effectLane(width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        let height = self.height(of: .effects)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.35))
            ForEach(item.blurEffects.filter { viewport.intersects($0.start, $0.end) }) { effect in
                let space = BlockSpace(viewport, width: width, from: effect.start, to: effect.end)
                EffectBlock(effect: effect, selected: model.selectedEffectID == effect.id,
                            highlighted: model.agentHighlight?.elements.contains(effect.id) == true, pixels: space.pixels,
                            snapStart: { space.block(snapSpan(effect.id, start: space.time($0), duration: effect.duration, pixels: pixels)) },
                            snapEdge: { space.block(snap(space.time($0), pixels: pixels, excluding: effect.id)) },
                            endSnap: endSnap,
                            onSelect: { model.selectedEffectID = effect.id },
                            onMove: { start in let start = space.time(start); model.updateEffect(effect.id) { $0.end = start + $0.duration; $0.start = start } },
                            onTrim: { start, end in
                                let start = start.map(space.time), end = end.map(space.time)
                                model.updateEffect(effect.id) { if let start { $0.start = start }; if let end { $0.end = end } }
                            })
                    .frame(height: Self.effectHeight)
                    .offset(x: viewport.x(of: effect.start, across: width))
            }
            if !item.blurRegions.isEmpty {
                let start = max(0, viewport.x(of: 0, across: width))
                let end = min(width, viewport.x(ofEnd: total, across: width))
                let selected = model.inspectorFocus == .blurArea
                HStack(spacing: 3) {
                    Image(systemName: "camera.filters")
                    Text((item.blurRegions.count == 1 ? "Blur area · whole video" : "\(item.blurRegions.count) blur areas · whole video")
                         + (item.isOn(.blurAreas) ? "" : " · off"))
                        .strikethrough(!item.isOn(.blurAreas))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 8, weight: .medium))
                .padding(.horizontal, 6)
                .frame(width: max(8, end - start), height: Self.blurBandHeight)
                .background(Color.orange.opacity(selected ? 0.45 : 0.2), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.orange.opacity(selected ? 1 : 0.45)))
                .contentShape(Rectangle())
                .onTapGesture { model.beginBlurAreas() }
                .help("Blur areas hide their part of the picture for the whole video. Click to edit them on the frame.")
                .opacity(item.isOn(.blurAreas) ? 1 : 0.45)
                .offset(x: start, y: Self.effectHeight + 2)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }

    private func graphicsLane(width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        let graphics = item.graphics?.items ?? []
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
            ForEach(graphics.filter { viewport.intersects($0.start, $0.end) }) { graphic in
                let space = BlockSpace(viewport, width: width, from: graphic.start, to: graphic.end)
                GraphicBlock(graphic: graphic, ink: item.graphics?.look(of: graphic) == .ink,
                             selected: model.selectedGraphicID == graphic.id,
                             highlighted: model.agentHighlight?.elements.contains(graphic.id) == true, pixels: space.pixels,
                             snapStart: { block in
                                 let start = space.time(block)
                                 guard let snapping = snapping() else { showGuide(at: nil); return space.block(start) }
                                 let landed = snapping.snapSpan(start: start, duration: graphic.length, pixelsPerSecond: pixels)
                                 showGuide(at: landed.target?.time)
                                 return space.block(landed.start)
                             },
                             snapEnd: { space.block(snap(space.time($0), pixels: pixels), end: true) },
                             endSnap: endSnap,
                             onSelect: { model.selectedGraphicID = graphic.id },
                             onMove: { model.moveGraphic(graphic.id, to: space.time($0)) },
                             onResize: { model.setGraphicEdge(graphic.id, end: space.time($0)) })
                    // The end screen takes the whole screen, so it spans both rows.
                    .frame(width: max(3, space.points),
                           height: graphic.kind.zone == .screen ? Self.graphicsRowHeight * 2 + 2 : Self.graphicsRowHeight)
                    .offset(x: viewport.x(of: graphic.start, across: width),
                            y: graphic.kind.zone == .panel ? Self.graphicsRowHeight + 3 : 1)
            }
        }
        .frame(width: width, height: Self.graphicsHeight, alignment: .leading)
        .clipped()
    }

    /// The music under the voice: a bar for each piece, with the waveform of what plays.
    private func musicLane(width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        let duration = item.editedDuration
        let pieces = item.music?.pieces ?? []
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
            ForEach(pieces.filter { viewport.intersects($0.start, $0.end(in: duration)) }) { piece in
                let end = piece.end(in: duration)
                let space = BlockSpace(viewport, width: width, from: piece.start, to: end)
                MusicBlock(piece: piece, end: end, selected: model.selectedMusicID == piece.id, pixels: space.pixels,
                           snapStart: { block in
                               let start = space.time(block)
                               guard let snapping = snapping() else { showGuide(at: nil); return space.block(start) }
                               let landed = snapping.snapSpan(start: start, duration: end - piece.start, pixelsPerSecond: pixels)
                               showGuide(at: landed.target?.time)
                               return space.block(landed.start)
                           },
                           snapEdge: { space.block(snap(space.time($0), pixels: pixels)) },
                           endSnap: endSnap,
                           onSelect: { model.selectedMusicID = piece.id },
                           onMove: { model.moveMusic(piece.id, to: space.time($0)) },
                           onStart: { model.setMusicStart(piece.id, to: space.time($0)) },
                           onEnd: { model.setMusicEnd(piece.id, to: space.time($0)) })
                    .frame(width: max(6, space.points), height: musicHeight - 2)
                    .offset(x: viewport.x(of: piece.start, across: width), y: 1)
                if let levels = musicLevels[piece.url] {
                    // Only the part on screen is drawn: a long piece at a close zoom is wider
                    // than any canvas should be. Each run between gaps is drawn on its own,
                    // so the sound lines up with the sections either side of a gap.
                    let plays = Self.playsTimeline(piece, duration: duration)
                    ForEach(Self.runs(from: max(piece.start, viewport.editedStart), to: min(end, viewport.editedEnd), in: viewport),
                            id: \.from) { run in
                        WaveformView(overview: levels, timeline: plays.cut(from: run.from - piece.start, to: run.to - piece.start))
                            .frame(width: max(1, viewport.width(from: run.from, to: run.to, across: width)), height: max(4, musicHeight - 14))
                            .opacity(0.55)
                            .offset(x: viewport.x(of: run.from, across: width), y: 11)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(width: width, height: musicHeight, alignment: .leading)
        .clipped()
        .opacity(hidden(.music) ? 0.5 : 1)
    }

    /// `from...to` in pieces that do not cross a gap.
    private static func runs(from: Double, to: Double, in viewport: TimelineViewport) -> [TimeRun] {
        guard to - from > 0.01 else { return [] }
        var runs: [TimeRun] = []
        var start = from
        for opening in viewport.gaps.openings where opening > from + 0.000001 && opening < to - 0.000001 {
            runs.append(TimeRun(from: start, to: opening))
            start = opening
        }
        runs.append(TimeRun(from: start, to: to))
        return runs.filter { $0.to - $0.from > 0.01 }
    }

    /// A section dragged `delta` points. Over another section it takes that place in the
    /// order. Into the space beside it, it slides there; into space further along, it goes
    /// there. Either way the sections around it stay where they are.
    private func moveSection(_ placed: (index: Int, segment: TimelineSegment, offset: Double), by delta: Double,
                             width: Double, pixels: Double) {
        let viewport = model.viewport
        let left = viewport.x(of: placed.offset, across: width) + delta
        let middle = left + placed.segment.duration * pixels / 2
        let time = viewport.time(atX: middle, across: width)
        if viewport.inGap(atX: middle, across: width),
           let after = placedSegments.first(where: { abs($0.offset - time) < 0.000001 && (item.gaps[$0.segment.id] ?? 0) > 0 }) {
            if after.index == placed.index || after.index == placed.index + 1 {
                model.shiftSegment(placed.segment.id, by: delta / pixels)
            } else {
                model.moveSegment(placed.segment.id, to: after.index > placed.index ? after.index - 1 : after.index,
                                  place: viewport.start + max(0, left) / pixels)
            }
            return
        }
        guard let destination = item.timeline.location(at: time)?.index else { return }
        if destination == placed.index {
            model.shiftSegment(placed.segment.id, by: delta / pixels)
        } else {
            model.moveSegment(placed.segment.id, to: destination)
        }
    }

    /// What a piece plays, as file ranges in its own time from 0: each play up to where the
    /// next one crosses in.
    private static func playsTimeline(_ piece: MusicPiece, duration: Double) -> ClipTimeline {
        let plays = piece.plays(videoDuration: duration)
        return ClipTimeline(segments: plays.enumerated().map { index, play in
            let length = index + 1 < plays.count ? plays[index + 1].at - play.at : play.length
            return TimelineSegment(start: play.from, end: play.from + max(0.001, length))
        })
    }

    private func shortsLane(width: Double, pixels: Double) -> some View {
        let viewport = model.viewport
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.35))
            ForEach(Array(item.shorts.enumerated()).filter { viewport.intersects($0.element.start, $0.element.end) }, id: \.element.id) { index, short in
                let space = BlockSpace(viewport, width: width, from: short.start, to: short.end)
                ShortBlock(short: short, name: short.name(index: index), selected: model.selectedShortID == short.id,
                           highlighted: model.agentHighlight?.elements.contains(short.id) == true, pixels: space.pixels,
                           snapStart: { space.block(snapSpan(short.id, start: space.time($0), duration: short.length, pixels: pixels)) },
                           snapEdge: { space.block(snap(space.time($0), pixels: pixels)) },
                           endSnap: endSnap,
                           onSelect: { model.selectShort(short.id) },
                           onMove: { model.moveShort(short.id, to: space.time($0)) },
                           onTrim: { start, end in model.setShortEdge(short.id, start: start.map(space.time), end: end.map(space.time)) })
                    .frame(height: Self.shortsHeight)
                    .offset(x: viewport.x(of: short.start, across: width))
            }
        }
        .frame(width: width, height: Self.shortsHeight, alignment: .leading)
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

    /// Filmora's split button: scissors on the playhead while the pointer is over the
    /// rows, where a click splits the section under it.
    @ViewBuilder
    private func scissors(width: Double) -> some View {
        let time = model.previewTime
        if hovering, !locked(.video), model.viewport.contains(time), canSplit(at: time) {
            Button { model.splitAtPlayhead() } label: {
                Image(systemName: "scissors")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .help("Split here (⌘B)")
            .accessibilityLabel("Split at the playhead")
            .offset(x: model.viewport.x(of: time, across: width) - 10, y: top(of: .video) - 10)
        }
    }

    /// Far enough from a section's edges to make two sections of at least a frame each.
    private func canSplit(at time: Double) -> Bool {
        let frame = 1 / max(1, item.info?.fps ?? 30)
        return placedSegments.contains { placed in
            time > placed.offset + frame && time < placed.offset + placed.segment.duration - frame
        }
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

/// A stretch of edited time.
private struct TimeRun: Hashable {
    var from: Double
    var to: Double
}

/// How a block on a row draws and moves when the row has gaps. A block measures its own
/// time at one scale from its start. Over a gap the row is wider than the block's own
/// time, so the block gets the scale that fills its place, and its times pass through the
/// row on the way in and out. Without gaps it changes nothing.
private struct BlockSpace {
    let viewport: TimelineViewport
    let width: Double
    let from: Double
    /// Points the block takes on the row.
    let points: Double
    /// Points per second of the block's own time.
    let pixels: Double

    init(_ viewport: TimelineViewport, width: Double, from: Double, to: Double) {
        self.viewport = viewport
        self.width = width
        self.from = from
        points = viewport.width(from: from, to: to, across: width)
        pixels = to - from > 0.000001 && points > 0 ? points / (to - from) : viewport.pixels(across: width)
    }

    private var origin: Double { viewport.x(of: from, across: width) }

    /// The edited time at a time the block worked out.
    func time(_ block: Double) -> Double { viewport.time(atX: origin + (block - from) * pixels, across: width) }

    /// The block's own time for an edited time; `end` for where something ends.
    func block(_ time: Double, end: Bool = false) -> Double {
        let x = end ? viewport.x(ofEnd: time, across: width) : viewport.x(of: time, across: width)
        return from + (x - origin) / pixels
    }

    /// A zoom's new hold, from the hold its block worked out.
    func hold(_ block: Double, of shot: ZoomShot) -> Double { shot.hold + time(block - shot.hold + shot.end) - shot.end }
}

/// Space the timeline leaves in front of a section. Playback and exports skip it.
private struct GapBlock: View {
    let length: Double
    let width: Double
    let locked: Bool
    let onClose: () -> Void
    let onCloseAll: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .overlay {
                if width >= 24, !locked {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .help("Close this gap: the sections after it move up")
                    .accessibilityLabel("Close gap")
                }
            }
            .padding(.horizontal, 1)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Close Gap", action: onClose).disabled(locked)
                Button("Close All Gaps", action: onCloseAll).disabled(locked)
            }
            .help("A gap of \(timelineTime(length)). Only the timeline shows it: playback and exports join the sections. Close Gaps (⌥⌘G) joins them here too.")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Gap, \(timelineTime(length))")
    }
}

/// One tile of a section's filmstrip: where it sits, and its frame once it is made.
struct FilmstripFrame {
    let x: Double
    let image: CGImage?
}

private struct SegmentBlock: View {
    let segment: TimelineSegment
    /// Where the section starts on the timeline.
    let offset: Double
    let number: Int
    let selected: Bool
    /// An agent just changed this section: outlined for a moment, never selected.
    var highlighted = false
    let pixels: Double
    let badges: [SectionBadge]
    let frames: [FilmstripFrame]
    let tileWidth: Double
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
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.22))
                filmstrip(size: geo.size)
                topBar(width: geo.size.width)
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(selected ? 0.18 : 0))
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: selected ? 2 : 1)
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
                .frame(width: geo.size.width, height: geo.size.height)
                if trimDelta != 0 {
                    Text(timelineTime((trimmingStart ? segment.start : segment.end) + trimDelta / pixels * segment.speed))
                        .font(.system(.caption, design: .monospaced)).padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in onSelect(min(1, max(0, location.x / max(1, geo.size.width)))) }
            .gesture(DragGesture(minimumDistance: 12)
                .onChanged { moveDelta = $0.translation.width }
                .onEnded { value in onMove(value.translation.width); moveDelta = 0 })
            .help("Click to select; ⇧- or ⌘-click to select several. Drag the edges to trim; the space they free stays. Drag the section into empty space, or past another section to reorder.")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Section \(number), \(timelineTime(segment.duration))"
                                + (segment.speed == 1 ? "" : ", \(segment.speed.formatted()) times speed"))
        }
        .padding(.horizontal, 1)
        .offset(x: moveDelta)
        .zIndex(moveDelta == 0 ? 0 : 1)
    }

    /// The frames of the part on screen, one per tile.
    private func filmstrip(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(frames, id: \.x) { frame in
                Group {
                    if let image = frame.image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.black.opacity(0.18)
                    }
                }
                .frame(width: tileWidth, height: size.height)
                .clipped()
                .offset(x: frame.x)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .allowsHitTesting(false)
    }

    /// The section's number, its source times and what is applied to it.
    private func topBar(width: Double) -> some View {
        HStack(spacing: 4) {
            Text("\(number)")
                .font(.system(size: 9.5, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
            if width > 130 {
                Text("\(timelineTime(segment.start)) – \(timelineTime(segment.end))")
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.8), radius: 1)
            }
            Spacer(minLength: 0)
            if width > 70 {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in badgeView(badge) }
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 12).padding(.trailing, 13).padding(.top, 3)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func badgeView(_ badge: SectionBadge) -> some View {
        switch badge {
        case .speed(let speed):
            Text("\(speed.formatted())×")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.yellow, in: RoundedRectangle(cornerRadius: 3))
                .help(badge.help)
        default:
            Image(systemName: badge.symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .frame(width: 15, height: 14)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                .help(badge.help)
        }
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

// MARK: - Filmstrip frames

/// Frames for the sections' filmstrips, made on demand from the recording and kept while
/// the app runs. AVFoundation makes them rather than ffmpeg: a small frame near a time is
/// all a tile needs, and the nearest keyframe is fast.
@MainActor
final class FilmstripCache: ObservableObject {
    static let shared = FilmstripCache()
    /// Enough for several long recordings at any zoom; past it the oldest go.
    static let limit = 1200

    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private var pending: Set<String> = []
    private var queued: [URL: Set<Double>] = [:]
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var flushScheduled = false
    private var publishScheduled = false

    private static func key(_ url: URL, _ source: Double) -> String { "\(url.path)|\(Int((source * 100).rounded()))" }

    /// The frame at `source`, or nil while it is being made. Asking starts it.
    func image(for url: URL, at source: Double) -> CGImage? {
        let key = Self.key(url, source)
        if let image = images[key] { return image }
        if !pending.contains(key) {
            pending.insert(key)
            queued[url, default: []].insert(source)
            scheduleFlush()
        }
        return nil
    }

    /// Asked for during a view update, so the work starts just after it.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        let batches = queued
        queued = [:]
        for (url, sources) in batches {
            let generator = generators[url] ?? makeGenerator(url)
            let times = sources.sorted().map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
            generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, _, _ in
                let source = requested.seconds
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.store(image, url: url, source: source) }
                }
            }
        }
    }

    private func makeGenerator(_ url: URL) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generators[url] = generator
        return generator
    }

    private func store(_ image: CGImage?, url: URL, source: Double) {
        let key = Self.key(url, source)
        pending.remove(key)
        guard let image else { return }
        images[key] = image
        order.append(key)
        if order.count > Self.limit {
            let dropped = order.prefix(order.count - Self.limit)
            dropped.forEach { images[$0] = nil }
            order.removeFirst(dropped.count)
        }
        // Many frames land together: one redraw for the lot.
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.publishScheduled = false
                self?.objectWillChange.send()
            }
        }
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
    var tint = Color.cyan
    var symbol = "plus.magnifyingglass"
    @State private var delta = 0.0
    @State private var resize = 0.0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text(shot.levelLabel).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .frame(width: max(8, geo.size.width + resize), height: 28)
            .background(tint.opacity(selected ? 0.45 : 0.23), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(selected ? 1 : 0.5)))
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
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 5, height: 16).padding(.trailing, 3)
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

/// One piece of music on the timeline: drag to move it, drag an edge to trim it.
private struct MusicBlock: View {
    let piece: MusicPiece
    let end: Double
    let selected: Bool
    let pixels: Double
    let snapStart: (Double) -> Double
    let snapEdge: (Double) -> Double
    let endSnap: () -> Void
    let onSelect: () -> Void
    let onMove: (Double) -> Void
    let onStart: (Double) -> Void
    let onEnd: (Double) -> Void
    @State private var delta = 0.0
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                Image(systemName: piece.loop ? "repeat" : "music.note")
                Text(piece.name).lineLimit(1)
                if piece.credit.licence == nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .frame(width: max(6, geo.size.width - trimStart + trimEnd), height: geo.size.height, alignment: .top)
            .padding(.top, 1)
            .background(Color.mint.opacity(selected ? 0.42 : 0.2), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.mint.opacity(selected ? 1 : 0.5)))
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in delta = (snapStart(piece.start + value.translation.width / pixels) - piece.start) * pixels }
                .onEnded { value in onSelect(); onMove(snapStart(piece.start + value.translation.width / pixels)); delta = 0; endSnap() })
            .overlay(alignment: .leading) {
                handle.highPriorityGesture(DragGesture(minimumDistance: 1)
                    .onChanged { trimStart = (snapEdge(piece.start + $0.translation.width / pixels) - piece.start) * pixels }
                    .onEnded { value in onSelect(); onStart(snapEdge(piece.start + value.translation.width / pixels)); trimStart = 0; endSnap() })
                    .help("Drag to change where the music starts")
            }
            .overlay(alignment: .trailing) {
                handle.highPriorityGesture(DragGesture(minimumDistance: 1)
                    .onChanged { trimEnd = (snapEdge(end + $0.translation.width / pixels) - end) * pixels }
                    .onEnded { value in onSelect(); onEnd(snapEdge(end + value.translation.width / pixels)); trimEnd = 0; endSnap() })
                    .help("Drag to change where the music stops. At the end of the video, it plays to the end.")
            }
            .offset(x: delta + trimStart)
            .help("\(piece.name): drag to move it, drag an edge to trim it" + (piece.credit.licence == nil ? ". Set its licence in the inspector." : ""))
            .accessibilityLabel("Music \(piece.name) at \(timelineTime(piece.start))")
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.mint).frame(width: 4, height: 12).padding(.horizontal, 2)
            .contentShape(Rectangle())
    }
}

/// One graphic on the timeline: drag to move it, drag its right edge to change its length.
private struct GraphicBlock: View {
    let graphic: Graphic
    let ink: Bool
    let selected: Bool
    var highlighted = false
    let pixels: Double
    let snapStart: (Double) -> Double
    let snapEnd: (Double) -> Double
    let endSnap: () -> Void
    let onSelect: () -> Void
    let onMove: (Double) -> Void
    let onResize: (Double) -> Void
    @State private var delta = 0.0
    @State private var resize = 0.0

    private var tint: Color {
        switch graphic.kind.zone {
        case .panel: return .orange
        case .screen: return .teal
        case .column: return .purple
        case .speaker: return .pink
        case .cover: return .indigo
        }
    }
    /// The end screen ends where the video ends: dragging it moves only its start.
    private var pinned: Bool { graphic.kind == .endScreen }
    private var title: String {
        let props = graphic.props
        let labels = LogoBadge.logos(props).compactMap(\.label).joined(separator: " + ")
        let spoken = (props["words"]?.array ?? []).compactMap { $0.object?["text"]?.string }.joined(separator: " ")
        let text = props["title"]?.string ?? props["kicker"]?.string ?? props["url"]?.string ?? props["text"]?.string
            ?? (spoken.isEmpty ? nil : spoken) ?? (labels.isEmpty ? graphic.kind.label : labels)
        return (props["number"]?.string.map { $0 + " " } ?? "") + text
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                Image(systemName: pinned ? "rectangle.inset.filled.and.person.filled" : ink ? "pencil.and.scribble" : "rectangle.on.rectangle")
                Text(pinned ? "End screen" : title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .frame(width: max(8, geo.size.width + resize - (pinned ? delta : 0)), height: geo.size.height)
            .background(tint.opacity(selected ? 0.5 : 0.25), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(selected ? 1 : 0.5)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.orange, lineWidth: 2.5)
                .opacity(highlighted ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: highlighted)
                .allowsHitTesting(false))
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in delta = (movedStart(value.translation.width) - graphic.start) * pixels }
                .onEnded { value in onSelect(); onMove(movedStart(value.translation.width)); delta = 0; endSnap() })
            .overlay(alignment: .trailing) {
                if !pinned {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4, height: 12).padding(.trailing, 2)
                        .contentShape(Rectangle())
                        .highPriorityGesture(DragGesture(minimumDistance: 1)
                            .onChanged { resize = (resizedEnd($0.translation.width) - graphic.end) * pixels }
                            .onEnded { value in onSelect(); onResize(resizedEnd(value.translation.width)); resize = 0; endSnap() })
                        .help("Drag to change how long the graphic shows")
                }
            }
            .offset(x: delta)
            .help(pinned ? "End screen: drag to change where it starts; it runs to the end of the video, 5 to 20 seconds as YouTube allows"
                         : "\(graphic.kind.label): drag to move it, drag its right edge to change its length")
            .accessibilityLabel("\(graphic.kind.label) graphic at \(timelineTime(graphic.start))")
        }
    }

    private func movedStart(_ translation: Double) -> Double { snapStart(graphic.start + translation / pixels) }
    private func resizedEnd(_ translation: Double) -> Double { snapEnd(graphic.end + translation / pixels) }
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
