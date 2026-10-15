import SwiftUI

/// The right-hand pane. It follows the selection — a section, a zoom or a blur area —
/// and below that always shows the recording's own settings. Common controls use plain
/// words; exact numbers sit behind Details.
struct InspectorPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isMovieMode {
                    movieSummary
                } else if let item = model.selectedItem, let info = item.info, let crop = item.crop {
                    selection(item: item, info: info)
                    RecordingInspector(item: item, info: info, crop: crop)
                } else {
                    Text("Select a recording to edit it. Its sections, zooms, blur areas and captions appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func selection(item: VideoItem, info: MediaInfo) -> some View {
        switch model.inspectorFocus {
        case .section:
            if model.sectionSelection.count > 1 {
                SectionsInspector(item: item, sections: model.sectionSelection.ordered(in: item.timeline))
                Divider()
            } else if let segment = model.selectedSegment,
               let index = item.timeline.segments.firstIndex(where: { $0.id == segment.id }) {
                SectionInspector(item: item, segment: segment, index: index)
                Divider()
            }
        case .zoom:
            if let shot = model.selectedShot {
                ZoomInspector(item: item, shot: shot)
                Divider()
            }
        case .blurArea:
            if let region = model.selectedRegion {
                BlurAreaInspector(region: region, info: info)
                Divider()
            }
        case .graphic:
            if let graphic = model.selectedGraphic {
                GraphicInspector(item: item, graphic: graphic)
                Divider()
            }
        case .effect:
            if let effect = model.selectedEffect {
                EffectInspector(item: item, effect: effect)
                Divider()
            }
        case .marker:
            if let marker = model.selectedMarker {
                MarkerInspector(marker: marker).id(marker.id)
                Divider()
            }
        case .short:
            if let short = model.selectedShort, let index = item.shorts.firstIndex(where: { $0.id == short.id }) {
                ShortInspector(item: item, info: info, short: short, index: index).id(short.id)
                Divider()
            }
        case .recording:
            EmptyView()
        }
    }

    private var movieSummary: some View {
        InspectorSection("Movie") {
            if let plan = try? model.moviePlan() {
                Text("\(plan.clips.count) recording\(plan.clips.count == 1 ? "" : "s") · \(timelineTime(plan.duration)) · \(Int(plan.size.width))×\(Int(plan.size.height))")
                    .font(.callout)
            }
            Text("Each recording keeps its own cuts, crop, zooms and captions. Choose Edit next to a recording to change it, and set which recordings are included and in what order below the preview.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A titled group in the inspector or the export sheet.
struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

// MARK: - Selection

private struct SectionInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let segment: TimelineSegment
    let index: Int

    var body: some View {
        InspectorSection("Section \(index + 1) of \(item.timeline.segments.count)") {
            Text("Plays for \(timelineTime(segment.duration))\(segment.speed == 1 ? "" : " at \(segment.speed.formatted())×")")
                .font(.callout)
            Picker("Speed", selection: Binding(get: { segment.speed }, set: { model.setSegmentSpeed(segment.id, speed: $0) })) {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { speed in
                    Text(speed == 1 ? "Normal speed" : "\(speed.formatted())×").tag(speed)
                }
            }
            .accessibilityLabel("Section speed")
            if segment.speed != 1 {
                Text("Audio keeps its pitch.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Start at Playhead") { model.trimToPlayhead(start: true) }
                    .help("Trim this section's start to the playhead (⇧⌘[)")
                Button("End at Playhead") { model.trimToPlayhead(start: false) }
                    .help("Trim this section's end to the playhead (⇧⌘])")
            }
            .controlSize(.small)
            HStack {
                Button { model.moveSegment(segment.id, to: index - 1) } label: { Label("Earlier", systemImage: "arrow.left") }
                    .disabled(index == 0)
                Button { model.moveSegment(segment.id, to: index + 1) } label: { Label("Later", systemImage: "arrow.right") }
                    .disabled(index == item.timeline.segments.count - 1)
                Spacer()
                Button(role: .destructive) { model.deleteSegment() } label: { Label("Delete", systemImage: "trash") }
                    .disabled(item.timeline.segments.count < 2)
                    .help("Delete this section (⌫)")
            }
            .controlSize(.small)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    TimelineTimeField(label: "Source in", value: segment.start) {
                        model.trimSegment(segment.id, start: $0)
                        return model.selectedSegment?.start ?? segment.start
                    }
                    TimelineTimeField(label: "Source out", value: segment.end) {
                        model.trimSegment(segment.id, end: $0)
                        return model.selectedSegment?.end ?? segment.end
                    }
                    Text("Seconds of the original recording.").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}

/// Several sections at once: what they add up to, and the edits that make sense for
/// all of them together. Each is one undo step.
private struct SectionsInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let sections: [TimelineSegment]

    private static let speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]

    /// The speed they share, or nil when they differ.
    private var speed: Double? {
        let speeds = Set(sections.map(\.speed))
        return speeds.count == 1 ? speeds.first : nil
    }

    var body: some View {
        InspectorSection("\(sections.count) of \(item.timeline.segments.count) sections") {
            Text("Play for \(timelineTime(sections.reduce(0) { $0 + $1.duration }))")
                .font(.callout)
            Picker("Speed", selection: Binding<Double?>(get: { speed }, set: { if let speed = $0 { model.setSelectedSectionsSpeed(speed) } })) {
                if speed == nil { Text("Mixed").tag(Double?.none) }
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "Normal speed" : "\(speed.formatted())×").tag(Double?.some(speed))
                }
            }
            .accessibilityLabel("Speed of the selected sections")
            if speed == nil {
                Text("Choosing a speed sets it for every selected section.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Select All") { model.selectAllSegments() }
                    .disabled(sections.count == item.timeline.segments.count)
                    .help("Select every section (⌘A)")
                Spacer()
                Button(role: .destructive) { model.deleteSegment() } label: { Label("Delete \(sections.count)", systemImage: "trash") }
                    .disabled(sections.count >= item.timeline.segments.count)
                    .help(sections.count >= item.timeline.segments.count
                          ? "Keep at least one section: leave one unselected to delete the rest."
                          : "Delete the selected sections (⌘⌫)")
            }
            .controlSize(.small)
            Text("⇧-click a section to select a range, ⌘-click to add or remove one. Trims and order are edited one section at a time.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ZoomInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let shot: ZoomShot

    var body: some View {
        InspectorSection("Zoom \(shot.levelLabel) at \(timelineTime(shot.start))") {
            Picker("Zoom", selection: Binding(get: { shot.level }, set: { model.setZoomLevel(shot.id, $0) })) {
                ForEach(ZoomShot.levels, id: \.self) { level in
                    Text(level == level.rounded() ? "\(Int(level))×" : String(format: "%.1f×", level)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Zoom level")
            HStack {
                Text("Hold").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { shot.hold }, set: { model.setZoomHold(shot.id, $0, live: true) }),
                       in: 0.5...8, step: 0.5,
                       onEditingChanged: { editing in if !editing { model.endGesture() } })
                    .accessibilityLabel("Zoom hold length")
                Text(String(format: "%.1f s", shot.hold))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("Eases in and out over \(String(format: "%.1f", ZoomShot.ease)) s each way. Drag the target on the picture to aim it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Move to Playhead") { model.retimeSelectedZoomToPlayhead() }
                Button("Show It") { model.scrubToShot(shot) }
                Spacer()
                Button(role: .destructive) { model.removeSelectedZoom() } label: { Label("Delete", systemImage: "trash") }
            }
            .controlSize(.small)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    TimelineTimeField(label: "Starts at", value: shot.start) {
                        model.setZoomStart(shot.id, $0)
                        return model.selectedShot?.start ?? shot.start
                    }
                    Text("Target \(Int(shot.target.x)), \(Int(shot.target.y)) px · ends at \(timelineTime(shot.end))")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}

private struct BlurAreaInspector: View {
    @EnvironmentObject var model: AppModel
    let region: BlurRegion
    let info: MediaInfo

    var body: some View {
        InspectorSection("Blur area") {
            Text("\(Int(region.rect.width))×\(Int(region.rect.height)) px · \(model.settings.blurStyle.label.lowercased())")
                .font(.callout)
            Text("Drag it on the picture to move or resize it.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Use on All Recordings") { model.applyCropToAll() }
                    .disabled(model.items.count < 2)
                    .help("Copy this recording's crop, blur areas and zooms to every recording of the same size")
                Spacer()
                Button(role: .destructive) { model.removeSelectedRegion() } label: { Label("Delete", systemImage: "trash") }
            }
            .controlSize(.small)
            DisclosureGroup("Details") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        PixelField(label: "X", accessibleName: "Blur area left", value: region.rect.minX, range: 0...CGFloat(info.width)) {
                            model.updateRegion(region.id, rect: CGRect(x: $0, y: region.rect.minY, width: region.rect.width, height: region.rect.height))
                        }
                        PixelField(label: "Y", accessibleName: "Blur area top", value: region.rect.minY, range: 0...CGFloat(info.height)) {
                            model.updateRegion(region.id, rect: CGRect(x: region.rect.minX, y: $0, width: region.rect.width, height: region.rect.height))
                        }
                    }
                    GridRow {
                        PixelField(label: "W", accessibleName: "Blur area width", value: region.rect.width, range: 16...CGFloat(info.width)) {
                            model.updateRegion(region.id, rect: CGRect(x: region.rect.minX, y: region.rect.minY, width: $0, height: region.rect.height))
                        }
                        PixelField(label: "H", accessibleName: "Blur area height", value: region.rect.height, range: 16...CGFloat(info.height)) {
                            model.updateRegion(region.id, rect: CGRect(x: region.rect.minX, y: region.rect.minY, width: region.rect.width, height: $0))
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}

// MARK: - Recording

/// Everything that belongs to the selected recording as a whole.
private struct RecordingInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let info: MediaInfo
    let crop: CGRect

    private var settingsBinding: Binding<ExportSettings> {
        Binding(get: { model.settings }, set: { model.updateSettings($0) })
    }
    private var liveSettingsBinding: Binding<ExportSettings> {
        Binding(get: { model.settings }, set: { model.updateSettings($0, live: true) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorSection("Recording") {
                Text(item.name).font(.headline).lineLimit(2).truncationMode(.middle)
                Text("\(info.width)×\(info.height) · \(formatDuration(info.duration)) · " + (info.fps > 0 ? String(format: "%.0f fps", info.fps) : "")
                     + (info.hasAudio ? "" : " · no audio"))
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(item.timeline.segments.count) section\(item.timeline.segments.count == 1 ? "" : "s") · plays for \(timelineTime(item.editedDuration))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            frame
            blurAreas
            zooms
            GraphicsSection(item: item)
            ShortsSection(item: item)
            subtitles
            ColorInspector(item: item, info: info)
            EffectsAndMarkersSection(item: item)
        }
    }

    private var frame: some View {
        InspectorSection("Frame") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(AspectPreset.all) { preset in
                    Button { model.applyAspect(preset) } label: { Text(preset.label).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .tint(item.aspectLabel == preset.label ? .accentColor : nil)
                        .accessibilityLabel(preset.ratio == nil ? "Free-form crop" : "Lock crop to \(preset.label)")
                }
            }
            .controlSize(.small)
            Text(outputSummary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            HStack {
                Button("Reset Crop") { model.resetCrop() }
                Button("Use on All Recordings") { model.applyCropToAll() }
                    .disabled(model.items.count < 2)
                    .help("Copy this recording's crop, blur areas and zooms to every recording of the same size")
            }
            .controlSize(.small)
            DisclosureGroup("Details") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        PixelField(label: "X", accessibleName: "Crop left", value: crop.minX, range: 0...CGFloat(info.width)) {
                            model.updateCrop(CGRect(x: $0, y: crop.minY, width: crop.width, height: crop.height))
                        }
                        PixelField(label: "Y", accessibleName: "Crop top", value: crop.minY, range: 0...CGFloat(info.height)) {
                            model.updateCrop(CGRect(x: crop.minX, y: $0, width: crop.width, height: crop.height))
                        }
                    }
                    GridRow {
                        PixelField(label: "W", accessibleName: "Crop width", value: crop.width, range: 16...CGFloat(info.width)) {
                            model.updateCrop(CGRect(x: crop.minX, y: crop.minY, width: $0, height: crop.height))
                        }
                        PixelField(label: "H", accessibleName: "Crop height", value: crop.height, range: 16...CGFloat(info.height)) {
                            model.updateCrop(CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: $0))
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    private var blurAreas: some View {
        InspectorSection("Blur areas") {
            Text(item.blurRegions.isEmpty
                 ? "None. Switch the picture to Blur and drag over anything you want hidden."
                 : "\(item.blurRegions.count) area\(item.blurRegions.count == 1 ? "" : "s"). Click one on the picture to select it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Style", selection: settingsBinding.blurStyle) {
                ForEach(BlurStyle.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: model.settings.blurStyle) { _, _ in model.refreshPreview() }
            if model.settings.blurStyle != .black {
                HStack {
                    Text(model.settings.blurStyle == .pixelate ? "Block size" : "Strength").font(.caption).foregroundStyle(.secondary)
                    Slider(value: liveSettingsBinding.blurStrength, in: 4...80, step: 2,
                           onEditingChanged: { editing in if !editing { model.endGesture() } })
                        .onChange(of: model.settings.blurStrength) { _, _ in model.refreshPreview() }
                        .accessibilityLabel(model.settings.blurStyle == .pixelate ? "Block size" : "Blur strength")
                    Text("\(Int(model.settings.blurStrength))").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Text("Style and strength apply to every blur area in the project.").font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Button("Add Area") { model.editorMode = .blur; model.addDefaultRegion() }
                Button("Clear All") { model.clearRegions() }.disabled(item.blurRegions.isEmpty)
            }
            .controlSize(.small)
        }
    }

    private var zooms: some View {
        InspectorSection("Zooms") {
            Text(item.zoomShots.isEmpty
                 ? "None. Switch the picture to Zoom, scrub to a moment and click where to zoom."
                 : "\(item.zoomShots.count) zoom\(item.zoomShots.count == 1 ? "" : "s"). Select one on the timeline to adjust it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add at Playhead") { model.editorMode = .zoom; model.addZoomAtCentre() }
                    .help("Add a zoom at the playhead, aimed at the middle of the frame")
                if model.isAnalyzingZooms {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelZoomAnalysis() }
                } else {
                    Button { model.suggestZooms() } label: { Label("Suggest", systemImage: "sparkles") }
                        .disabled(item.editedDuration < 1.5)
                        .help("Find moments of local activity on this Mac; you review them before anything is added")
                }
                Spacer()
                Button("Clear All") { model.clearZooms() }.disabled(item.zoomShots.isEmpty)
            }
            .controlSize(.small)
        }
    }

    private var captionUse: Binding<CaptionUse> {
        Binding(get: { model.settings.captionUse(hasFile: item.subtitles != nil) },
                set: { use in var changed = model.settings; changed.captions = use; model.updateSettings(changed); model.refreshPreview() })
    }

    private var subtitles: some View {
        InspectorSection("Captions") {
            if let file = item.subtitles {
                HStack(spacing: 6) {
                    Image(systemName: "captions.bubble").foregroundStyle(.secondary)
                    Text(file.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle).help(file.path)
                    Spacer()
                    Button("Change…") { model.chooseSubtitles() }.controlSize(.small)
                    Button { model.clearSubtitles() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help(item.transcript == nil ? "Export without captions" : "Use captions from the transcript instead")
                        .accessibilityLabel("Remove caption file")
                }
            } else if let transcript = item.transcript {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote").foregroundStyle(.secondary)
                    Text("From the transcript · \(transcript.words.count) words").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Choose File…") { model.chooseSubtitles() }.controlSize(.small)
                }
            } else {
                HStack {
                    Text("No caption file.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { model.chooseSubtitles() }.controlSize(.small)
                }
                Text("An .srt, .vtt or .ass file; one next to the video with the same name is found automatically. Auto Edit can make captions from what is said.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.subtitles != nil || item.transcript != nil {
                Picker("Use", selection: captionUse) {
                    ForEach(CaptionUse.allCases) { Text($0.label).tag($0) }
                }
                Text(captionUse.wrappedValue.detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if captionUse.wrappedValue.burns {
                    Picker("Placement", selection: settingsBinding.subtitlePlacement) {
                        ForEach(SubtitlePlacement.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: model.settings.subtitlePlacement) { _, _ in model.refreshPreview() }
                    Text(model.settings.subtitlePlacement.detail).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Size", selection: settingsBinding.subtitleSize) {
                        ForEach(SubtitleSize.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.settings.subtitleSize) { _, _ in model.refreshPreview() }
                    if !model.subtitlesAvailable {
                        warning("This ffmpeg was built without libass and cannot burn captions in. Run brew install ffmpeg-full and relaunch, or choose SRT for upload.")
                    }
                }
            }
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private var outputSummary: String {
        let cropped = crop.evenClamped(in: info.fullFrame)
        let base = "\(item.aspectLabel) · \(Int(cropped.width))×\(Int(cropped.height))"
        if let scaled = FFmpeg.scaledSize(for: cropped.size, limit: model.settings.sizeLimit) {
            return base + " → \(Int(scaled.width))×\(Int(scaled.height))"
        }
        return base
    }
}
