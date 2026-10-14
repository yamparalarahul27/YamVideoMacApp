import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTarget = false
    @State private var exporting: ExportScope?

    var body: some View {
        VStack(spacing: 0) {
            if !model.toolsAvailable { missingToolsBanner }

            // Media, picture and inspector side by side; the timeline across the bottom at
            // its natural height, so any extra space goes to the picture.
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

            Divider()
            statusBar
        }
        .frame(minWidth: 1140, minHeight: 800)
        .toolbar {
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
        .sheet(item: $exporting) { scope in ExportSheet(scope: scope).environmentObject(model) }
        .sheet(isPresented: $model.showingZoomSuggestions) { ZoomSuggestionsView().environmentObject(model) }
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

            if model.showPlayback {
                PlaybackCanvas(playback: model.playback).frame(maxHeight: .infinity)
            } else {
            CropCanvas(
                image: model.previewImage,
                info: info,
                crop: crop,
                ratio: item.aspectLock,
                originalImage: model.previewOriginalImage,
                isLoading: model.previewIsLoading,
                mode: model.editorMode,
                regions: item.blurRegions,
                selectedRegionID: model.selectedRegionID,
                shots: item.zoomShots,
                selectedShotID: model.selectedShotID,
                onChange: { model.updateCrop($0, live: $1) },
                onSelectRegion: { model.selectedRegionID = $0 },
                onChangeRegion: { model.updateRegion($0, rect: $1, live: $2) },
                onAddRegion: { model.addRegion($0); model.refreshPreview() },
                onSelectShot: { model.selectedShotID = $0 },
                onMoveShot: { model.moveZoomTarget($0, to: $1) },
                onMoveShotEnded: { model.endGesture() },
                onAddShot: { model.addZoom(at: $0) }
            )
            .frame(maxHeight: .infinity)

            }
        }
        .overlay(alignment: .bottom) { comparison }
        .background(Color(nsColor: .windowBackgroundColor))
        // Effects can only be judged in the composed picture, so Effects mode shows it.
        .onChange(of: model.editorMode) { _, mode in model.setPlaybackVisible(mode == .effects) }
        .onDeleteCommand {
            guard !model.isConverting else { return }
            switch model.editorMode {
            case .blur: model.removeSelectedRegion()
            case .zoom: model.removeSelectedZoom()
            case .effects: model.removeSelectedEffect()
            case .crop: break
            }
        }
    }

    /// Original / Corrected / Compare, under the picture while the recording has a colour
    /// stage to compare. Playback can show either version but not both halves.
    @ViewBuilder
    private var comparison: some View {
        if item.colorStage(model.settings).render != nil {
            Picker("Colour", selection: $model.colorComparison) {
                ForEach(model.showPlayback ? [ColorComparison.corrected, .original] : ColorComparison.allCases) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .controlSize(.small)
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .padding(.bottom, 8)
            .help("Original shows the recording without colour correction; Compare shows both halves of the same frame.")
            .accessibilityLabel("Colour comparison")
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

            Picker("Viewer", selection: Binding(get: { model.showPlayback }, set: { model.setPlaybackVisible($0) })) {
                Text("Edit frame").tag(false)
                Text("Preview").tag(true)
            }.pickerStyle(.segmented).frame(width: 165).labelsHidden()
            Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                .help("\(info.width)×\(info.height) · \(info.videoCodec.uppercased()) · \(formatDuration(info.duration))")
            Spacer(minLength: 0)
            if case .done(let url) = item.status {
                Button("Show in Finder") { model.reveal(url) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
