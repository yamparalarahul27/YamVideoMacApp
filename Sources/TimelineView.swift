import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var playback: PlaybackController
    let item: VideoItem
    @State private var scale = 1.0
    @State private var overview: AudioOverview?
    @State private var audioError: String?
    @State private var reviewingSilence = false

    var body: some View {
        VStack(spacing: 8) {
            transport
            GeometryReader { geo in
                let width = max(1, geo.size.width - 2) * scale
                let pixels = width / max(0.001, item.editedDuration)
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 5) {
                            ruler(width: width)
                            HStack(spacing: 0) {
                                ForEach(Array(item.timeline.segments.enumerated()), id: \.element.id) { index, segment in
                                    SegmentBlock(segment: segment, number: index + 1, name: item.name,
                                                 selected: model.selectedSegmentID == segment.id,
                                                 pixels: pixels,
                                                 onSelect: { fraction in
                                                     model.selectedSegmentID = segment.id
                                                     playback.pause()
                                                     model.setPreviewFraction((item.timeline.offset(of: segment.id) + segment.duration * fraction) / item.editedDuration)
                                                 }, onTrim: { start, end in model.trimSegment(segment.id, start: start, end: end) },
                                                 onMove: { delta in
                                                     let time = item.timeline.offset(of: segment.id) + segment.duration / 2 + delta / pixels
                                                     if let destination = item.timeline.location(at: time)?.index {
                                                         model.moveSegment(segment.id, to: destination)
                                                     }
                                                 })
                                        .frame(width: max(1, segment.duration * pixels), height: 48)
                                }
                            }
                            if let overview {
                                WaveformView(overview: overview, timeline: item.timeline)
                                    .frame(height: 28)
                                    .contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                        playback.pause(); model.setPreviewFraction(value.location.x / width)
                                    })
                            }
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
                                if item.zoomShots.isEmpty {
                                    Text("Zoom track · add a zoom at the playhead")
                                        .font(.caption2).foregroundStyle(.secondary).padding(.leading, 9).padding(.top, 7)
                                }
                                ForEach(item.zoomShots) { shot in
                                    ZoomBlock(shot: shot, selected: model.selectedShotID == shot.id, pixels: pixels,
                                              onSelect: { model.selectedShotID = shot.id; model.editorMode = .zoom },
                                              onMove: { model.setZoomStart(shot.id, $0) },
                                              onResize: { model.setZoomHold(shot.id, $0) })
                                        .frame(width: max(3, shot.duration * pixels), height: 28)
                                        .offset(x: shot.start * pixels)
                                }
                            }.frame(height: 28)
                        }
                        Rectangle().fill(Color.primary).frame(width: 1.5, height: overview == nil ? 104 : 137)
                            .offset(x: min(width - 1, max(0, item.previewFraction * width)))
                            .allowsHitTesting(false)
                    }
                    .frame(width: width, height: overview == nil ? 108 : 141)
                }
            }.frame(height: overview == nil ? 120 : 153)
            sectionControls
            HStack(spacing: 10) {
                if let segment = model.selectedSegment {
                    Picker("Speed", selection: Binding(get: { segment.speed }, set: { model.setSegmentSpeed(segment.id, speed: $0) })) {
                        ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { speed in
                            Text("\(speed.formatted())×").tag(speed)
                        }
                    }.frame(width: 125).accessibilityLabel("Section speed")
                    Text("\(timelineTime(segment.duration)) · preserve pitch").font(.caption).foregroundStyle(.secondary)
                }
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
        .task(id: item.url) {
            overview = nil; audioError = nil
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
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $scale, in: 1...8).frame(width: 68).accessibilityLabel("Timeline magnification")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func ruler(width: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Color.primary.opacity(0.001)
            ForEach(0...8, id: \.self) { tick in
                VStack(alignment: .leading, spacing: 3) {
                    Text(timelineTime(item.editedDuration * Double(tick) / 8)).font(.system(size: 9, design: .monospaced))
                    Rectangle().frame(width: 1, height: 4)
                }
                .foregroundStyle(.secondary)
                .offset(x: min(width - 52, width * Double(tick) / 8))
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            playback.pause()
            model.setPreviewFraction(value.location.x / width)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline playhead")
        .accessibilityValue(timelineTime(model.previewTime))
        .accessibilityAdjustableAction { direction in model.stepFrame(direction == .increment ? 1 : -1) }
    }

    private var sectionControls: some View {
        HStack(spacing: 8) {
            if let segment = model.selectedSegment,
               let index = item.timeline.segments.firstIndex(where: { $0.id == segment.id }) {
                Text("Section \(index + 1)").font(.caption.weight(.medium))
                TimelineTimeField(label: "In", value: segment.start) {
                    model.trimSegment(segment.id, start: $0)
                    return model.selectedSegment?.start ?? segment.start
                }
                TimelineTimeField(label: "Out", value: segment.end) {
                    model.trimSegment(segment.id, end: $0)
                    return model.selectedSegment?.end ?? segment.end
                }
                Button { model.moveSegment(segment.id, to: index - 1) } label: { Image(systemName: "arrow.left") }
                    .disabled(index == 0).help("Move section earlier").accessibilityLabel("Move section earlier")
                Button { model.moveSegment(segment.id, to: index + 1) } label: { Image(systemName: "arrow.right") }
                    .disabled(index == item.timeline.segments.count - 1).help("Move section later").accessibilityLabel("Move section later")
                Button { model.deleteSegment() } label: { Image(systemName: "trash") }
                    .disabled(item.timeline.segments.count < 2).help("Delete selected section (⌘⌫)").accessibilityLabel("Delete section")
            } else {
                Text("Click a section to trim it. Drag sections to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("\(item.timeline.segments.count) section\(item.timeline.segments.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(height: 24)
        .controlSize(.small)
    }
}

private struct SegmentBlock: View {
    let segment: TimelineSegment
    let number: Int
    let name: String
    let selected: Bool
    let pixels: Double
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
                HStack {
                    handle(start: true)
                    Spacer(minLength: 0)
                    handle(start: false)
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
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .onChanged { value in trimmingStart = start; trimDelta = value.translation.width }
                .onEnded { value in
                    let delta = value.translation.width / pixels * segment.speed
                    onTrim(start ? segment.start + delta : nil, start ? nil : segment.end + delta)
                    trimDelta = 0
                })
            .help(start ? "Drag to trim the start" : "Drag to trim the end")
            .accessibilityLabel(start ? "Trim section start" : "Trim section end")
    }
}

private struct ZoomBlock: View {
    let shot: ZoomShot
    let selected: Bool
    let pixels: Double
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
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in delta = value.translation.width }
                .onEnded { value in onSelect(); onMove(shot.start + value.translation.width / pixels); delta = 0 })
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 2).fill(Color.cyan).frame(width: 5, height: 16).padding(.trailing, 3)
                    .contentShape(Rectangle())
                    .highPriorityGesture(DragGesture(minimumDistance: 1)
                        .onChanged { resize = $0.translation.width }
                        .onEnded { value in onSelect(); onResize(shot.hold + value.translation.width / pixels); resize = 0 })
                    .help("Drag to change zoom duration")
            }
            .offset(x: delta)
            .help("Drag to move this zoom; drag its right edge to change duration")
            .accessibilityLabel("\(shot.levelLabel) zoom at \(timelineTime(shot.start))")
        }
    }
}

private struct TimelineTimeField: View {
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
