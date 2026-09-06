import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTarget = false
    @State private var showCommand = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.toolsAvailable { missingToolsBanner }

            HSplitView {
                QueueSidebar()
                    .frame(minWidth: 210, idealWidth: 240, maxWidth: 340)

                editorPane
                    .frame(minWidth: 460)

                SettingsPane(showCommand: $showCommand)
                    .frame(minWidth: 268, idealWidth: 288, maxWidth: 340)
            }

            Divider()
            statusBar
        }
        .frame(minWidth: 1020, minHeight: 660)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.promptForFiles()
                } label: {
                    Label("Add Videos", systemImage: "plus")
                }
                .help("Add video files (⌘O)")

                Spacer()

                if model.isConverting {
                    Button(role: .destructive) {
                        model.cancelConversion()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        model.convertSelected()
                    } label: {
                        Label("Convert Selected", systemImage: "play")
                    }
                    .disabled(model.selectedItem?.info == nil || !model.toolsAvailable)

                    Button {
                        model.convertAll()
                    } label: {
                        Label("Convert All (\(model.convertibleCount))", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.convertibleCount == 0 || !model.toolsAvailable)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            loadDroppedURLs(providers) { urls in model.addDropped(urls) }
            return true
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Panes

    @ViewBuilder
    private var editorPane: some View {
        if let item = model.selectedItem, let info = item.info, let crop = item.crop {
            CropEditorPane(item: item, info: info, crop: crop)
        } else if let item = model.selectedItem, case .failed(let message) = item.status {
            centeredMessage(
                icon: "exclamationmark.triangle",
                title: item.name,
                detail: message,
                action: ("Try Again", { model.retry(item.id) })
            )
        } else if model.selectedItem != nil {
            centeredMessage(icon: "hourglass", title: "Reading video…", detail: nil, action: nil)
        } else {
            centeredMessage(
                icon: "film.stack",
                title: "Drop MOV files here",
                detail: "Or press ⌘O to choose files. Crop visually, then convert to MP4, GIF or WebP.",
                action: ("Add Videos…", { model.promptForFiles() })
            )
        }
    }

    private func centeredMessage(
        icon: String,
        title: String,
        detail: String?,
        action: (String, () -> Void)?
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if let action {
                Button(action.0, action: action.1)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private var missingToolsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("ffmpeg was not found").font(.callout.weight(.semibold))
                Text("Install it with  brew install ffmpeg  — or point YamVideo at an existing copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Locate ffmpeg…") { model.locateFFmpeg() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isConverting {
                ProgressView().controlSize(.small)
            }
            Text(model.statusMessage ?? defaultStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let folder = model.settings.outputFolder {
                Text("→ \(folder.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("→ alongside originals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var defaultStatus: String {
        if model.items.isEmpty { return "No videos queued." }
        let count = model.items.count
        let settings = model.settings
        let detail = settings.format == .mp4
            ? settings.encoder.label
            : "\(settings.format.label) · \(settings.frameRate.label)"
        return "\(count) video\(count == 1 ? "" : "s") queued · \(detail) · \(settings.qualityDescription)"
    }

    private func loadDroppedURLs(
        _ providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

// MARK: - Queue sidebar

struct QueueSidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: model.listSelection) {
                ForEach(model.items) { item in
                    QueueRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            if case .done(let url) = item.status {
                                Button("Show in Finder") { model.reveal(url) }
                            }
                            Button("Remove from Queue") { model.remove(item.id) }
                                .disabled(model.isConverting && item.status.isBusy)
                        }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 6) {
                Button {
                    model.promptForFiles()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add videos")

                Button {
                    if let id = model.selection { model.remove(id) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(model.selection == nil || model.isConverting)
                .help("Remove selected")

                Spacer()

                Button("Clear Done") { model.clearFinished() }
                    .font(.caption)
                    .disabled(model.isConverting)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

struct QueueRow: View {
    let item: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 5) {
                statusIcon
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if case .converting(let fraction) = item.status {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .probing:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
        case .ready:
            Image(systemName: item.cropIsFullFrame ? "rectangle" : "crop")
                .font(.caption2).foregroundStyle(.secondary)
        case .converting:
            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(.red)
        }
    }

    private var subtitle: String {
        switch item.status {
        case .probing:
            return "Reading…"
        case .ready:
            guard let info = item.info, let crop = item.crop else { return "Ready" }
            let out = FFmpeg.scaledSize(for: crop.size, limit: .original) ?? crop.size
            return "\(Int(out.width))×\(Int(out.height)) · \(formatDuration(info.duration))"
        case .converting(let fraction):
            return "Converting \(Int(fraction * 100))%"
        case .done:
            return "Done"
        case .failed(let message):
            return message.split(separator: "\n").first.map(String.init) ?? "Failed"
        }
    }
}

// MARK: - Crop editor pane

struct CropEditorPane: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let info: MediaInfo
    let crop: CGRect

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            CropCanvas(
                image: model.previewImage,
                info: info,
                crop: crop,
                ratio: item.aspectLock,
                isLoading: model.previewIsLoading,
                mode: model.editorMode,
                regions: item.blurRegions,
                selectedRegionID: model.selectedRegionID,
                shots: item.zoomShots,
                selectedShotID: model.selectedShotID,
                onChange: { model.updateCrop($0) },
                onSelectRegion: { model.selectedRegionID = $0 },
                onChangeRegion: { model.updateRegion($0, rect: $1, live: $2) },
                onAddRegion: { model.addRegion($0); model.refreshPreview() },
                onSelectShot: { model.selectedShotID = $0 },
                onMoveShot: { model.moveZoomTarget($0, to: $1) },
                onAddShot: { model.addZoom(at: $0) }
            )
            .frame(maxHeight: .infinity)

            scrubber
            Divider()
            switch model.editorMode {
            case .crop: cropControls
            case .blur: blurControls
            case .zoom: zoomControls
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDeleteCommand {
            switch model.editorMode {
            case .blur: model.removeSelectedRegion()
            case .zoom: model.removeSelectedZoom()
            case .crop: break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.editorMode) {
                ForEach(EditorMode.allCases) { mode in
                    Text(mode == .blur && !item.blurRegions.isEmpty
                         ? "\(mode.label) (\(item.blurRegions.count))"
                         : mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(info.width)×\(info.height) · \(info.videoCodec.uppercased()) · \(formatDuration(info.duration))"
                     + (info.fps > 0 ? String(format: " · %.0f fps", info.fps) : "")
                     + (info.hasAudio ? " · \(info.audioCodec ?? "audio")" : " · no audio"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .done(let url) = item.status {
                Button("Show in Finder") { model.reveal(url) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Image(systemName: "film")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { item.previewFraction },
                    set: { model.setPreviewFraction($0) }
                ),
                in: 0...1
            )
            .overlay(alignment: .bottomLeading) {
                // Where the zooms sit along the clip.
                if model.editorMode == .zoom, info.duration > 0, !item.zoomShots.isEmpty {
                    GeometryReader { geo in
                        ForEach(item.zoomShots) { shot in
                            Capsule()
                                .fill(Color.cyan.opacity(shot.id == model.selectedShotID ? 0.9 : 0.45))
                                .frame(
                                    width: max(3, geo.size.width * shot.duration / info.duration),
                                    height: 3
                                )
                                .offset(x: geo.size.width * shot.start / info.duration, y: geo.size.height - 1)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            Text(formatDuration(info.duration * item.previewFraction))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Aspect")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(AspectPreset.all) { preset in
                    Button(preset.label) { model.applyAspect(preset) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(item.aspectLabel == preset.label ? .accentColor : nil)
                        .accessibilityLabel(preset.ratio == nil
                            ? "Free-form crop"
                            : "Lock crop to \(preset.label)")
                        .help(preset.ratio == nil
                            ? "Resize the crop freely"
                            : "Lock the crop to \(preset.label)")
                }
                Spacer()
            }

            HStack(spacing: 10) {
                PixelField(label: "X", accessibleName: "Crop left",
                           value: crop.minX, range: 0...CGFloat(info.width)) {
                    model.updateCrop(CGRect(x: $0, y: crop.minY, width: crop.width, height: crop.height))
                }
                PixelField(label: "Y", accessibleName: "Crop top",
                           value: crop.minY, range: 0...CGFloat(info.height)) {
                    model.updateCrop(CGRect(x: crop.minX, y: $0, width: crop.width, height: crop.height))
                }
                PixelField(label: "W", accessibleName: "Crop width",
                           value: crop.width, range: 16...CGFloat(info.width)) {
                    model.updateCrop(CGRect(x: crop.minX, y: crop.minY, width: $0, height: crop.height))
                }
                PixelField(label: "H", accessibleName: "Crop height",
                           value: crop.height, range: 16...CGFloat(info.height)) {
                    model.updateCrop(CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: $0))
                }

                Divider().frame(height: 18)

                Button("Reset") { model.resetCrop() }
                    .controlSize(.small)
                Button("Apply to All") { model.applyCropToAll() }
                    .controlSize(.small)
                    .disabled(model.items.count < 2)

                Spacer()

                Text(outputSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var blurControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.blurRegions.isEmpty
                     ? "Drag on the video to cover an area you want hidden."
                     : "Drag an area to move it, or drag on empty space to add another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Area") { model.addDefaultRegion() }
                    .controlSize(.small)
                Button("Delete") { model.removeSelectedRegion() }
                    .controlSize(.small)
                    .disabled(model.selectedRegionID == nil)
                Button("Clear All") { model.clearRegions() }
                    .controlSize(.small)
                    .disabled(item.blurRegions.isEmpty)
            }

            HStack(spacing: 10) {
                if let region = model.selectedRegion {
                    PixelField(label: "X", accessibleName: "Blur area left",
                               value: region.rect.minX, range: 0...CGFloat(info.width)) {
                        model.updateRegion(region.id, rect: CGRect(
                            x: $0, y: region.rect.minY,
                            width: region.rect.width, height: region.rect.height))
                    }
                    PixelField(label: "Y", accessibleName: "Blur area top",
                               value: region.rect.minY, range: 0...CGFloat(info.height)) {
                        model.updateRegion(region.id, rect: CGRect(
                            x: region.rect.minX, y: $0,
                            width: region.rect.width, height: region.rect.height))
                    }
                    PixelField(label: "W", accessibleName: "Blur area width",
                               value: region.rect.width, range: 16...CGFloat(info.width)) {
                        model.updateRegion(region.id, rect: CGRect(
                            x: region.rect.minX, y: region.rect.minY,
                            width: $0, height: region.rect.height))
                    }
                    PixelField(label: "H", accessibleName: "Blur area height",
                               value: region.rect.height, range: 16...CGFloat(info.height)) {
                        model.updateRegion(region.id, rect: CGRect(
                            x: region.rect.minX, y: region.rect.minY,
                            width: region.rect.width, height: $0))
                    }

                    Divider().frame(height: 18)
                    Button("Apply to All") { model.applyCropToAll() }
                        .controlSize(.small)
                        .disabled(model.items.count < 2)
                } else {
                    Text("No area selected.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text("\(item.blurRegions.count) area\(item.blurRegions.count == 1 ? "" : "s") · \(model.settings.blurStyle.label.lowercased())")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.zoomShots.isEmpty
                     ? "Scrub to the moment, then click the spot you want to zoom into."
                     : "Click to add another zoom, or drag a marker to move it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Zoom") { model.addZoomAtCentre() }
                    .controlSize(.small)
                    .help("Add a zoom at the playhead, aimed at the middle of the frame")
                Button("Delete") { model.removeSelectedZoom() }
                    .controlSize(.small)
                    .disabled(model.selectedShotID == nil)
                Button("Clear All") { model.clearZooms() }
                    .controlSize(.small)
                    .disabled(item.zoomShots.isEmpty)
            }

            if let shot = model.selectedShot {
                HStack(spacing: 10) {
                    Picker("", selection: Binding(
                        get: { shot.level },
                        set: { model.setZoomLevel(shot.id, $0) }
                    )) {
                        ForEach(ZoomShot.levels, id: \.self) { level in
                            Text(level == level.rounded() ? "\(Int(level))×" : String(format: "%.1f×", level))
                                .tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                    .accessibilityLabel("Zoom level")

                    Text("at \(formatDuration(shot.start))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button("Move to Playhead") { model.retimeSelectedZoomToPlayhead() }
                        .controlSize(.small)
                        .help("Start this zoom at the current scrubber position")

                    Divider().frame(height: 18)

                    Text("Hold").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { shot.hold },
                            set: { model.setZoomHold(shot.id, $0) }
                        ),
                        in: 0.5...8, step: 0.5
                    )
                    .frame(width: 110)
                    .accessibilityLabel("Zoom hold length")
                    Text(String(format: "%.1fs", shot.hold))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)

                    Spacer()

                    Button("Jump to It") { model.scrubToShot(shot) }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Text(item.zoomShots.isEmpty
                         ? "No zooms yet."
                         : "Select a zoom marker to adjust it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(item.zoomShots.count) zoom\(item.zoomShots.count == 1 ? "" : "s")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 62, alignment: .top)
    }

    private var outputSummary: String {
        let cropped = crop.evenClamped(in: info.fullFrame)
        if let scaled = FFmpeg.scaledSize(for: cropped.size, limit: model.settings.sizeLimit) {
            return "out \(Int(cropped.width))×\(Int(cropped.height)) → \(Int(scaled.width))×\(Int(scaled.height))"
        }
        return "out \(Int(cropped.width))×\(Int(cropped.height))"
    }
}

// MARK: - Settings pane

struct SettingsPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var showCommand: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Format") {
                    Picker("Format", selection: $model.settings.format) {
                        ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()

                    Text(model.settings.format.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if model.settings.format == .webp, !model.webpAvailable {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("This ffmpeg was built without libwebp and cannot write WebP. "
                                 + "Homebrew's plain ffmpeg is a slim build — run "
                                 + "brew install ffmpeg-full and relaunch, or export a GIF instead.")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                if model.settings.format.isAnimation {
                    animationSection
                } else {
                    videoSection
                }

                colourSection

                section("Blur Areas") {
                    Picker("Style", selection: $model.settings.blurStyle) {
                        ForEach(BlurStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: model.settings.blurStyle) { _, _ in model.refreshPreview() }

                    Text(model.settings.blurStyle.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if model.settings.blurStyle != .black {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(model.settings.blurStyle == .pixelate ? "Block size" : "Strength")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(model.settings.blurStrength))")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $model.settings.blurStrength, in: 4...80, step: 2)
                                .onChange(of: model.settings.blurStrength) { _, _ in
                                    model.refreshPreview()
                                }
                        }
                    }

                    if model.selectedItem?.blurRegions.isEmpty ?? true {
                        Text("Switch the editor to Blur Areas and drag over anything you want hidden.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                subtitleSection

                if model.settings.format == .mp4 {
                    audioSection
                }

                section("Destination") {
                    HStack(spacing: 6) {
                        Text(model.settings.outputFolder?.lastPathComponent ?? "Alongside originals")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { model.chooseOutputFolder() }
                            .controlSize(.small)
                        if model.settings.outputFolder != nil {
                            Button {
                                model.settings.outputFolder = nil
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Save next to each source file")
                        }
                    }
                    HStack(spacing: 6) {
                        Text("Suffix").font(.caption).foregroundStyle(.secondary)
                        TextField("-converted", text: $model.settings.suffix)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }

                DisclosureGroup(isExpanded: $showCommand) {
                    if let command = model.previewCommand {
                        Text(command)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.06)))
                    } else {
                        Text("Select a video to see the command.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("ffmpeg command").font(.caption.weight(.semibold))
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Per-format sections

    private var videoSection: some View {
        section("Video") {
            Picker("Encoder", selection: $model.settings.encoder) {
                ForEach(VideoEncoder.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()

            qualitySlider

            if !model.settings.encoder.isHardware {
                Picker("Speed", selection: $model.settings.preset) {
                    ForEach(ExportSettings.presets, id: \.self) { Text($0).tag($0) }
                }
            }

            scalePicker
        }
    }

    private var animationSection: some View {
        section(model.settings.format == .gif ? "GIF" : "WebP") {
            Picker("Frame rate", selection: $model.settings.frameRate) {
                ForEach(AnimationFrameRate.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()

            scalePicker

            if let hint = animationSizeHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.settings.format == .gif {
                Picker("Colours", selection: $model.settings.gifColors) {
                    ForEach(GIFColors.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()

                Picker("Dither", selection: $model.settings.gifDither) {
                    ForEach(GIFDither.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()

                Text(model.settings.gifDither.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                if !model.settings.webpLossless { qualitySlider }

                Toggle("Lossless", isOn: $model.settings.webpLossless)
                    .controlSize(.small)
                Text(model.settings.webpLossless
                     ? "Pixel-exact, and much bigger. Worth it for text and flat UI."
                     : "Lossy, like a JPEG per frame. Right for anything photographic.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle("Loop forever", isOn: $model.settings.loopForever)
                .controlSize(.small)

            Text("Neither format carries audio, so the sound is dropped.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Only shown for HLG/PQ sources — there is nothing to decide about an SDR clip.
    @ViewBuilder
    private var colourSection: some View {
        if let info = model.selectedItem?.info, info.isHDR {
            section("Colour") {
                Toggle("Convert HDR to SDR", isOn: $model.settings.toneMapHDR)
                    .onChange(of: model.settings.toneMapHDR) { _, _ in model.refreshPreview() }

                Text(model.settings.toneMapHDR
                     ? "This clip is \(info.hdrLabel ?? "HDR"). Tone-mapped to Rec.709 so it looks right in browsers and on the web, not just in QuickTime."
                     : "Off: the export keeps the source's HDR transfer. QuickTime will look fine; most other players will show it blown out.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if model.settings.toneMapHDR, !model.toneMappingAvailable {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("This ffmpeg has no zscale filter and cannot tone-map. Run "
                             + "brew install ffmpeg-full and relaunch, or turn this off to "
                             + "export the source colours unchanged.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The file is per-clip; the styling is shared, like the blur areas and their style.
    private var subtitleSection: some View {
        section("Subtitles") {
            if let subtitles = model.selectedItem?.subtitles {
                HStack(spacing: 6) {
                    Image(systemName: "captions.bubble")
                        .foregroundStyle(.secondary)
                    Text(subtitles.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(subtitles.path)
                    Spacer()
                    Button("Change…") { model.chooseSubtitles() }
                        .controlSize(.small)
                    Button {
                        model.clearSubtitles()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Export without captions")
                }

                Picker("Placement", selection: $model.settings.subtitlePlacement) {
                    ForEach(SubtitlePlacement.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .onChange(of: model.settings.subtitlePlacement) { _, _ in model.refreshPreview() }

                Text(model.settings.subtitlePlacement.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker("Size", selection: $model.settings.subtitleSize) {
                    ForEach(SubtitleSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.settings.subtitleSize) { _, _ in model.refreshPreview() }

                if !model.subtitlesAvailable {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("This ffmpeg was built without libass and cannot burn subtitles "
                             + "in. Run brew install ffmpeg-full and relaunch, or clear the "
                             + "file to export without them.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Text(model.selectedItem == nil
                         ? "Select a clip to add captions."
                         : "No subtitle file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { model.chooseSubtitles() }
                        .controlSize(.small)
                        .disabled(model.selectedItem == nil)
                }
                Text("Burns an .srt, .vtt or .ass file into the picture. One sitting next to "
                     + "the video under the same name is picked up on its own.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var audioSection: some View {
        section("Audio") {
            Picker("Audio", selection: $model.settings.audio) {
                ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            if model.settings.audio == .copy, let info = model.selectedItem?.info,
               info.hasAudio, !info.audioIsMP4Compatible {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("This clip's audio is \(info.audioCodec ?? "uncompressed"). Copying it into MP4 produces a file QuickTime and Safari cannot play — choose AAC instead.")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if model.settings.audio == .copy {
                Text("Skips audio re-encoding when the source track is already MP4-compatible.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.settings.audio == .normalised {
                Text("Measures the clip, then encodes it to \(Loudness.summary) — what "
                     + "YouTube, Instagram and TikTok normalise toward, so they leave it "
                     + "alone. Costs one extra pass over the audio.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qualitySlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Quality").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.settings.qualityDescription)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $model.settings.quality, in: 0...100, step: 5) {
                EmptyView()
            } minimumValueLabel: {
                Text("small").font(.caption2).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("best").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var scalePicker: some View {
        Picker("Scale", selection: $model.settings.sizeLimit) {
            ForEach(SizeLimit.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
    }

    /// Nudge when the frame is big enough that the animation will be unwieldy — the usual
    /// mistake is exporting a 1080p GIF and wondering why it is 60 MB.
    private var animationSizeHint: String? {
        guard model.settings.format.isAnimation,
              let item = model.selectedItem, let info = item.info
        else { return nil }
        let crop = (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let size = FFmpeg.scaledSize(for: crop.size, limit: model.settings.sizeLimit) ?? crop.size
        guard max(size.width, size.height) > 800 else { return nil }
        return "\(Int(size.width))×\(Int(size.height)) is large for a \(model.settings.format.label.lowercased())"
            + " — capping the long side at 640 px or less keeps the file manageable."
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content()
        }
    }
}
