import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTarget = false
    @State private var exporting: ExportScope?
    @State private var publishing = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.toolsAvailable, model.module == .studio { missingToolsBanner }

            HStack(spacing: 0) {
                ModuleSidebar()
                Divider()
                switch model.module {
                case .library: LibraryPage()
                case .calendar: CalendarView()
                case .studio: studio
                }
            }

            Divider()
            statusBar
        }
        .frame(minWidth: 1140, minHeight: 800)
        .toolbar {
            switch model.module {
            case .library, .calendar: libraryToolbar
            case .studio: studioToolbar
            }
        }
        .sheet(item: $exporting) { scope in ExportSheet(scope: scope).environmentObject(model) }
        .sheet(isPresented: $publishing) { PublishSheet().environmentObject(model) }
        .sheet(isPresented: $model.showingZoomSuggestions) { ZoomSuggestionsView().environmentObject(model) }
        .sheet(isPresented: $model.showingAutoEdit) { AutoEditSheet().environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.libraryScan != nil }, set: { if !$0 { model.libraryScan = nil } })) {
            PastVideosSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showingStyle) { StyleSheet().environmentObject(model) }
        .sheet(isPresented: $model.showingProjectNotes) { ProjectNotesSheet().environmentObject(model) }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            loadDroppedURLs(providers) { urls in model.receiveDropped(urls) }
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

    // MARK: Studio

    /// Media, picture and inspector side by side; the timeline across the bottom at its
    /// natural height, so any extra space goes to the picture.
    private var studio: some View {
        VStack(spacing: 0) {
            HSplitView {
                QueueSidebar()
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

                editorPane
                    .frame(minWidth: 480)
                    .disabled(model.isConverting)

                InspectorPane()
                    .frame(minWidth: 280, idealWidth: 310, maxWidth: 380)
                    .disabled(model.isConverting)
            }
            .frame(minHeight: 320)

            if !model.isMovieMode, let item = model.selectedItem, item.info != nil, item.crop != nil,
               FileManager.default.fileExists(atPath: item.url.path) {
                Divider()
                TimelineView(playback: model.playback, item: item)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(model.isConverting)
            }
        }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.newIdea() } label: { Label("New Idea", systemImage: "plus") }
                .help("New idea (⌥⌘N)")
            Button { model.showingStyle = true } label: { Label("Style", systemImage: "text.book.closed") }
                .help("Your channel's editing rules (Style.md), which every agent reads (⌘3)")
            Button { model.promptForPastVideos() } label: { Label("Scan a Folder…", systemImage: "folder.badge.gearshape") }
                .help("Add videos you already made: YamVideo projects and Export for YouTube folders. Nothing is copied.")
            Button { model.libraryUndo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help(model.libraryUndoTitle + " (⌘Z)")
                .disabled(model.libraryUndoEntries.isEmpty)
            Button { model.libraryRedo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help(model.libraryRedoTitle + " (⇧⌘Z)")
                .disabled(model.libraryRedoEntries.isEmpty)
            Spacer()
            AgentsToolbarButton()
        }
    }

    @ToolbarContentBuilder private var studioToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.promptForFiles()
            } label: {
                Label("Add Videos", systemImage: "plus")
            }
            .help("Add video files (⌘O)")

            Button { model.saveProject() } label: { Label("Save Project", systemImage: "square.and.arrow.down") }
                .help("Save editable project (⌘S)")
            Text((model.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + (model.hasUnsavedChanges ? " •" : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let idea = model.openProjectIdea {
                Button { model.showIdea(idea.id) } label: {
                    Label(idea.title, systemImage: "lightbulb").labelStyle(.titleAndIcon).lineLimit(1)
                }
                .controlSize(.small)
                .frame(maxWidth: 220)
                .help("This project was made from the idea \"\(idea.title)\". Open it on the Library page.")
            }
            Button { model.undoEdit() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help(model.undoTitle + " (⌘Z)")
                .disabled(model.undoEntries.isEmpty || model.isConverting)
            Button { model.redoEdit() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help(model.redoTitle + " (⇧⌘Z)")
                .disabled(model.redoEntries.isEmpty || model.isConverting)
            Picker("Workspace", selection: Binding(get: { model.isMovieMode }, set: { model.setMovieMode($0) })) {
                Text("Recording").tag(false)
                Text("Movie").tag(true)
            }.pickerStyle(.segmented).frame(width: 175).disabled(model.isConverting)
            Spacer()

            AgentsToolbarButton()

            if model.isConverting {
                Button(role: .destructive) {
                    model.cancelConversion()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop the export (⌘.)")
            } else {
                Button { model.showingAutoEdit = true } label: {
                    Label("Auto Edit…", systemImage: "wand.and.stars")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.isMovieMode || model.selectedItem?.info == nil)
                .help("Transcribe, cut pauses and stumbles, and set captions and loudness, the way you chose")
                Button { publishing = true } label: {
                    Label("Publish…", systemImage: "play.rectangle")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.isMovieMode || model.selectedItem?.info == nil)
                .help("Title, description, tags, chapters and thumbnail for YouTube, with a preview, and Export for YouTube")
                Button { exporting = model.isMovieMode ? .movie : .selected } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(model.items.isEmpty || !model.toolsAvailable)
                .help("Choose what to export, the format and where it goes")
            }
        }
    }

    // MARK: Panes

    @ViewBuilder
    private var editorPane: some View {
        if model.isMovieMode {
            MovieView(playback: model.playback)
        } else if let item = model.selectedItem, !FileManager.default.fileExists(atPath: item.url.path) {
            centeredMessage(icon: "exclamationmark.triangle", title: "Source video is missing",
                            detail: item.url.path, action: ("Locate Source…", { model.locateSource() }))
        } else if let item = model.selectedItem, let info = item.info, let crop = item.crop {
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
                title: "Start with a recording",
                detail: "Drop a video or open a saved project. Cut mistakes, arrange zooms, and preview your edit.",
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
                    QueueRow(item: item, agentNote: model.agentHighlight?.clips.contains(item.id) == true ? model.agentHighlight?.origin : nil)
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
    /// Names the agent that just changed this recording, for a moment.
    var agentNote: String?

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

            if let agentNote {
                Label("\(agentNote) edited", systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.orange)
                    .transition(.opacity)
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
            guard item.info != nil, let crop = item.crop else { return "Ready" }
            let out = FFmpeg.scaledSize(for: crop.size, limit: .original) ?? crop.size
            return "\(Int(out.width))×\(Int(out.height)) · \(formatDuration(item.editedDuration))"
        case .converting(let fraction):
            return "Converting \(Int(fraction * 100))%"
        case .done:
            return "Done"
        case .failed(let message):
            return message.split(separator: "\n").first.map(String.init) ?? "Failed"
        }
    }
}

// MARK: - Picture pane

/// The one player. It plays the edit, and the selection decides what the handles on the
/// picture do. The Crop tool, the blur areas, aiming a zoom and the colour comparison open
/// the recording's frame in its place, with a bar under it to finish the edit.
struct CropEditorPane: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let info: MediaInfo
    let crop: CGRect

    /// What decides whether the player has to come back.
    private struct PictureKey: Equatable {
        let item: VideoItem.ID
        let playing: Bool
        let edit: PictureEdit?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            picture
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) { beforeBadge }
            Divider()
            if let edit = model.pictureEdit { editBar(edit) } else { playerBar }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: PictureKey(item: item.id, playing: model.showPlayback, edit: model.pictureEdit)) {
            // One player: whatever hid it without opening an edit on the frame, it comes back.
            if model.pictureEdit == nil, !model.showPlayback, !model.isConverting { model.setPlaybackVisible(true) }
        }
        .onDeleteCommand {
            // A selected section goes with the Timeline menu's ⌫; everything else here.
            guard !model.isConverting, model.inspectorFocus != .section else { return }
            model.deleteSelection()
        }
    }

    // MARK: The picture

    @ViewBuilder
    private var picture: some View {
        if let edit = model.pictureEdit {
            CropCanvas(
                image: model.previewImage,
                info: info,
                crop: edit == .crop ? (model.cropDraft?.rect ?? crop) : crop,
                ratio: edit == .crop ? model.cropDraft?.ratio : item.aspectLock,
                originalImage: model.previewOriginalImage,
                isLoading: model.previewIsLoading,
                mode: edit.mode,
                regions: item.blurRegions,
                selectedRegionID: model.selectedRegionID,
                shots: item.zoomShots,
                selectedShotID: model.selectedShotID,
                onChange: { rect, _ in model.updateCropDraft(rect) },
                onSelectRegion: { model.selectedRegionID = $0 },
                onChangeRegion: { model.updateRegion($0, rect: $1, live: $2) },
                onAddRegion: { model.addRegion($0); model.refreshPreview() },
                onSelectShot: { model.selectedShotID = $0 },
                onMoveShot: { model.moveZoomTarget($0, to: $1) },
                onMoveShotEnded: { model.endGesture() },
                onAddShot: { model.addZoom(at: $0) }
            )
        } else if model.showsShort, let short = item.short(model.playback.shortID) {
            PlaybackCanvas(playback: model.playback,
                           graphics: model.timelineTracks.hidden.contains(.graphics) || !item.isOn(.graphics) ? nil : model.shortOverlay(item, info: info, short: short),
                           editsGraphics: !model.isConverting, short: short.id, furniture: model.shortFurniture,
                           onGraphicBounds: { model.shortGraphicBounds = $0 })
        } else {
            PlaybackCanvas(playback: model.playback, graphics: graphicsOverlay,
                           editsGraphics: !model.isConverting && !model.showsBefore,
                           onGraphicBounds: { model.graphicBounds = $0 })
                .overlay {
                    if item.screen != nil, model.selectedScreenZoom != nil, !model.isConverting, !model.showsBefore {
                        ScreenAimLayer(frame: crop.size) { model.aimScreenZoom(at: $0) }
                    }
                }
        }
    }

    /// Graphics are drawn at the 1920×1080 design size on a 16:9 picture. Other shapes wait
    /// for the vertical layouts of a later phase.
    private var graphicsOverlay: GraphicsOverlayInput? {
        guard !model.timelineTracks.hidden.contains(.graphics), !model.showsBefore, item.isOn(.graphics) else { return nil }
        guard let track = item.placedGraphics, !track.items.isEmpty else { return nil }
        let frame = crop.size
        guard frame.height > 0, abs(frame.width / frame.height - 16.0 / 9.0) < 0.02 else { return nil }
        return GraphicsOverlayInput(clip: item.id, track: track.labellingEndScreen(item.publish?.endScreen), duration: item.editedDuration,
                                    fps: info.fpsExpression, frame: frame, time: model.previewTime)
    }

    @ViewBuilder
    private var beforeBadge: some View {
        if model.showsBefore, model.pictureEdit == nil {
            Text("Before: the recording as it was")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 10)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(verbatim: "\(info.width)×\(info.height) · \(info.fps > 0 ? String(format: "%.0f fps · ", info.fps) : "")\(formatDuration(info.duration))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if case .done(let url) = item.status {
                Button("Show in Finder") { model.reveal(url) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: The player bar

    /// Under the picture, as in Filmora: where the playhead is, playback, then the tools
    /// for the picture.
    private var playerBar: some View {
        HStack(spacing: 2) {
            Text("\(timelineTime(model.previewTime)) / \(timelineTime(item.editedDuration))")
                .font(.system(.callout, design: .monospaced)).monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: 8)
            barButton("backward.frame", "Previous frame (←)", label: "Previous frame") { model.stepFrame(-1) }
            Button { model.togglePlayback() } label: {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 26)
            }
            .help("Play / pause (Space)")
            .accessibilityLabel(model.playback.isPlaying ? "Pause" : "Play")
            barButton("forward.frame", "Next frame (→)", label: "Next frame") { model.stepFrame(1) }
            Spacer(minLength: 8)
            if model.inspectorFocus == .zoom, model.selectedShot != nil, !model.showsShort {
                barButton("scope", "Aim the selected zoom on the picture", label: "Aim zoom") { model.beginZoomAim() }
            }
            barButton("crop", "Crop the frame (⌥C)", label: "Crop") { model.beginCrop() }
                .disabled(model.showsShort)
            Toggle(isOn: Binding(get: { model.showsBefore }, set: { model.setBefore($0) })) {
                Label("Before/After", systemImage: "rectangle.split.2x1")
            }
            .toggleStyle(.button).labelStyle(.iconOnly)
            .disabled(model.showsShort)
            .help(model.showsBefore
                  ? "Showing Before: the recording as it was. Click to show the edit."
                  : "Before/After: show the recording as it was, with the same cuts and no crop, zooms, blur, colour or graphics")
            .accessibilityLabel("Before/After")
            Picker("Shape", selection: Binding(get: { model.showsShort }, set: { model.setPictureTall($0) })) {
                Text("Video").tag(false)
                Text("Short").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(item.shorts.isEmpty ? "Short plays a 9:16 Short. Add one with the + on the Shorts row." : "Video plays the edit; Short plays the selected Short at 9:16")
            .accessibilityLabel("Video or Short")
            if model.showsShort {
                Toggle(isOn: $model.shortFurniture) {
                    Label("Safe zones", systemImage: "rectangle.portrait.inset.filled")
                }
                .toggleStyle(.button).labelStyle(.iconOnly)
                .help("Safe zones: show faintly where YouTube draws its buttons, channel and title over the Short")
                .accessibilityLabel("Safe zones")
            }
            barButton("camera", "Snapshot: save this frame as a PNG", label: "Snapshot") { model.saveSnapshot() }
                .disabled(!model.showPlayback || model.showsBefore)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func barButton(_ symbol: String, _ help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 22) }
            .help(help)
            .accessibilityLabel(label)
    }

    // MARK: The edit bars

    private func editBar(_ edit: PictureEdit) -> some View {
        HStack(spacing: 6) {
            switch edit {
            case .crop: cropBar
            case .blurAreas: blurBar
            case .zoomAim: zoomBar
            case .colourCompare: compareBar
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.accentColor.opacity(0.12))
    }

    private func barTitle(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).labelStyle(.titleAndIcon).font(.callout.weight(.semibold)).fixedSize()
    }

    @ViewBuilder
    private var cropBar: some View {
        barTitle("Crop", "crop")
        // The ratios side by side where they fit, as a menu where the picture is narrow.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ratioPicker.pickerStyle(.segmented)
                cropSize
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ratioPicker.pickerStyle(.segmented)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ratioPicker.pickerStyle(.menu)
                cropSize
                Spacer(minLength: 0)
            }
        }
        Button { model.resetCropDraft() } label: { Image(systemName: "arrow.counterclockwise") }
            .help("Reset: the whole frame, with a free ratio")
            .accessibilityLabel("Reset the crop")
        Button("Cancel") { model.cancelCropDraft() }
            .keyboardShortcut(.cancelAction)
        Button("Apply") { model.applyCropDraft() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }

    private var ratioPicker: some View {
        Picker("Ratio", selection: Binding(get: { model.cropDraft?.preset ?? "Free" },
                                           set: { label in AspectPreset.all.first { $0.label == label }.map(model.setCropDraftAspect) })) {
            ForEach(AspectPreset.all) { Text($0.label).tag($0.label) }
        }
        .labelsHidden()
        .fixedSize()
        .help("The crop's ratio. Free lets the corners move freely.")
        .accessibilityLabel("Crop ratio")
    }

    private var cropSize: some View {
        Text(model.cropDraft?.size ?? "")
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel("Crop size \(model.cropDraft?.size ?? "")")
    }

    @ViewBuilder
    private var blurBar: some View {
        barTitle("Blur areas", "camera.filters")
        Text("Drag on the picture to add an area. Drag an area to move it or change its size.")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 6)
        Button("Delete Area") { model.removeSelectedRegion() }
            .disabled(model.selectedRegionID == nil)
        Button("Done") { model.endPictureEdit() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var zoomBar: some View {
        barTitle(model.selectedShot.map { "Zoom \($0.levelLabel) at \(timelineTime($0.start))" } ?? "Zoom", "plus.magnifyingglass")
        Text("Drag the box to aim the zoom. Click the picture to add a zoom there.")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 6)
        Button("Done") { model.endPictureEdit() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var compareBar: some View {
        barTitle("Colour", "circle.lefthalf.filled")
        Text("Original on the left, corrected on the right, on the same frame.")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 6)
        Button("Done") { model.endPictureEdit() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }
}
