import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// What the inspector is showing: the last thing selected, or the recording itself.
enum InspectorFocus: Equatable {
    case recording, section, zoom, blurArea, effect, marker, graphic, short
}

@MainActor
final class AppModel: ObservableObject {
    /// Shared so files opened from Finder reach the same window.
    static let shared = AppModel()

    @Published var items: [VideoItem] = []
    @Published var selection: VideoItem.ID?
    @Published var settings = ExportSettings()
    @Published var previewImage: NSImage?
    /// The same frame without its colour stage, while comparing side by side.
    @Published var previewOriginalImage: NSImage?
    @Published var previewIsLoading = false
    /// How the picture shows colour correction. View state: never saved, never exported.
    @Published var colorComparison: ColorComparison = .corrected {
        didSet {
            guard colorComparison != oldValue else { return }
            refreshPreview()
            if showPlayback, let item = selectedItem, !isMovieMode {
                playback.prepare(item, settings: settings, at: previewTime, play: false, original: colorComparison == .original)
            }
        }
    }
    @Published var isConverting = false
    @Published var toolsAvailable = FFmpeg.isAvailable
    /// Whether the located ffmpeg can write WebP at all — libwebp is an optional build flag.
    @Published var webpAvailable = true
    /// Whether it has zscale, without which HDR clips cannot be tone-mapped to SDR.
    @Published var toneMappingAvailable = true
    /// Whether it has libass, without which subtitles cannot be burned in.
    @Published var subtitlesAvailable = true
    /// Whether exports can draw graphics on this Mac (Node.js and HyperFrames); nil until checked.
    @Published var graphicsRenderer: HyperFrames.Status?
    /// What the owner's HyperFrames download is doing, while it runs.
    @Published var graphicsDownload: String?
    @Published var graphicsDownloadError: String?
    @Published var statusMessage: String?
    @Published var editorMode: EditorMode = .crop
    @Published var selectedRegionID: BlurRegion.ID? { didSet { focusInspector(selectedRegionID, .blurArea) } }
    /// The whole-frame effect and the marker the inspector shows, when one is selected.
    @Published var selectedEffectID: VideoBlurEffect.ID? { didSet { focusInspector(selectedEffectID, .effect) } }
    @Published var selectedMarkerID: TimelineMarker.ID? { didSet { focusInspector(selectedMarkerID, .marker) } }
    /// ⇧M asks the marker inspector to put the cursor in the name field.
    @Published var renamingMarker = false
    /// What the inspector shows: whatever was selected last, or the recording.
    @Published var inspectorFocus: InspectorFocus = .recording

    let playback = PlaybackController()
    @Published var showPlayback = false
    @Published var isMovieMode = false
    @Published var movieSettings = MovieSettings()
    /// The project's auto edit answers; nil until saved once. See `autoEditOptions`.
    @Published var autoEdit: AutoEditOptions?
    @Published var showingAutoEdit = false
    /// What the owner's auto edit is doing while it runs: transcribing, finding cuts.
    @Published var autoEditRun: AutoEditRun?
    /// Cuts waiting for the owner when the cut style is Review each cut.
    @Published var autoEditReview: AutoEditPlan?
    /// The last auto edit's outcome, or why it stopped.
    @Published var autoEditMessage: String?
    @Published var autoEditError: String?
    /// The owner's model download while it runs, 0–1.
    @Published var modelDownload: (model: TranscriptModel, fraction: Double)?
    @Published var modelDownloadError: String?
    var autoEditTask: Task<Void, Never>?
    var modelDownloadTask: Task<Void, Never>?
    /// Transcripts by recording, model and language, so undoing one, or an edit refused
    /// mid-export, never means waiting for whisper again.
    var transcriptCache: [String: Transcript] = [:]
    @Published var movieTime = 0.0
    @Published var movieProgress: Double?
    @Published var movieOutput: URL?
    @Published var isAnalyzingZooms = false
    @Published var showingZoomSuggestions = false
    @Published var zoomSuggestions: [ZoomSuggestion] = []
    /// The sections `zoomSuggestions` were timed against.
    var zoomSuggestionTimeline: ClipTimeline?
    var zoomAnalysisTask: Task<Void, Never>?
    var movieExportTask: Task<Void, Never>?
    /// The selected sections of the selected recording.
    @Published var sectionSelection = SectionSelection() { didSet { focusInspector(sectionSelection.anchor, .section) } }
    /// One section: the anchor of the selection. Setting it selects that section alone.
    var selectedSegmentID: UUID? {
        get { sectionSelection.anchor }
        set { sectionSelection = .single(newValue) }
    }
    /// The slice of the edited timeline on screen. It lives here rather than in the
    /// timeline view so the zoom menu commands can reach it and so it survives the view
    /// being rebuilt; `syncViewport` keeps its length matching the selected clip.
    @Published var viewport = TimelineViewport(total: 0)
    /// Whether timeline drags line up with the playhead, section boundaries and zoom
    /// edges. A preference rather than an edit: it is remembered, never undone.
    @Published var timelineSnapping = UserDefaults.standard.object(forKey: AppModel.snappingKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(timelineSnapping, forKey: Self.snappingKey) }
    }
    static let snappingKey = "timelineSnapping"
    @Published var projectURL: URL?
    @Published var hasUnsavedChanges = false
    @Published var undoEntries: [EditHistory] = []
    @Published var redoEntries: [EditHistory] = []
    /// Revision, session identity, change feed and any open gesture; see
    /// `ProjectCommandDispatcher.swift`.
    var editSession = EditSessionState()
    /// While true, local agents can read but every agent edit is refused.
    @Published var agentsPaused = false
    /// Recent changes by anyone, newest first, for the activity list.
    @Published var recentActivity: [EditEvent] = []
    /// What an agent just changed, shown briefly on the timeline.
    @Published var agentHighlight: AgentHighlight?
    /// Local clients heard from since launch, most recent first.
    @Published var agentClients: [AgentClient] = []
    /// Finished agent requests by request ID, for idempotent retries within a session.
    var agentRequests: [String: AgentRequestRecord] = [:]
    /// Request IDs currently being answered, so a duplicate sent meanwhile is not run twice.
    var agentPendingRequests: Set<String> = []
    /// Preview, analysis and export work requested by agents, by job ID.
    var agentJobs: [UUID: AgentJob] = [:]
    var agentJobTasks: [UUID: Task<Void, Never>] = [:]
    /// Fingerprint of the named project file as last opened or saved.
    var savedFingerprint: Data?
    /// Where this instance writes preview frames for agents; one folder per running app.
    var agentArtifactsDirectory = AppModel.artifactsDirectory.appendingPathComponent("default", isDirectory: true)
    var autosaveTask: Task<Void, Never>?
    var savedProject: VideoProject?
    /// The open document's persistent identity; see `VideoProject.projectID`.
    var projectID = UUID()

    private var previewTask: Task<Void, Never>?
    var conversionTask: Task<Void, Never>?
    private var thumbnailCache: [String: NSImage] = [:]

    static let acceptedTypes: [UTType] = [
        .movie, .video, .quickTimeMovie, .mpeg4Movie, .audiovisualContent,
    ]

    private static let acceptedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "flv", "mts", "m2ts", "3gp", "hevc",
    ]

    let sessionRecoveryURL: URL?

    init(recoveryURL: URL? = AppModel.recoveryURL) {
        sessionRecoveryURL = recoveryURL
        refreshCapabilities()
        playback.onTime = { [weak self] seconds in
            guard let self else { return }
            if self.isMovieMode { self.movieTime = seconds; return }
            guard let index = self.selectedIndex else { return }
            let duration = self.items[index].editedDuration
            if duration > 0 { self.items[index].previewFraction = min(1, seconds / duration) }
        }
        recoverSession()
        editSession.projectID = projectID
    }

    /// Asks ffmpeg what it was built with, so the format picker can say up front that a
    /// WebP export is not going to work rather than failing at the end of one.
    private func refreshCapabilities() {
        guard toolsAvailable else { return }
        Task { webpAvailable = await FFmpeg.supportsWebP() }
        Task { toneMappingAvailable = await FFmpeg.supportsToneMapping() }
        Task { subtitlesAvailable = await FFmpeg.supportsSubtitles() }
        refreshGraphicsRenderer()
    }

    func refreshGraphicsRenderer() {
        Task { graphicsRenderer = await HyperFrames.status() }
    }

    /// The one-time HyperFrames download, started only by the owner's click.
    func downloadGraphicsRenderer() {
        guard graphicsDownload == nil else { return }
        graphicsDownloadError = nil
        graphicsDownload = "Starting the download…"
        Task {
            do {
                try await HyperFrames.install { message in Task { @MainActor [weak self] in self?.graphicsDownload = message } }
                statusMessage = "HyperFrames is ready: exports now draw graphics."
            } catch {
                graphicsDownloadError = error.localizedDescription
            }
            graphicsDownload = nil
            graphicsRenderer = await HyperFrames.status()
        }
    }

    var selectedItem: VideoItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    /// `List` pushes a nil selection while it re-validates its rows. Adopting that would
    /// clear the editor and cancel the in-flight preview, so nil is only honoured when the
    /// queue is genuinely empty.
    var listSelection: Binding<VideoItem.ID?> {
        Binding(
            get: { [weak self] in self?.selection },
            set: { [weak self] newValue in
                guard let self else { return }
                if newValue == nil, !self.items.isEmpty { return }
                guard newValue != self.selection else { return }
                self.cancelZoomAnalysis()
                self.playback.clear()
                self.showPlayback = false
                self.showsShort = false; self.playback.shortID = nil; self.selectedShortID = nil
                self.isMovieMode = false
                self.selectedSegmentID = nil
                self.selection = newValue
                self.refreshPreview()
            }
        )
    }

    private func ensureSelection() {
        if selection == nil || !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        }
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return items.firstIndex { $0.id == selection }
    }

    // MARK: - Queue management

    func addFiles(_ urls: [URL]) {
        let fresh = urls
            .filter { Self.acceptedExtensions.contains($0.pathExtension.lowercased()) }
            .filter { url in !items.contains { $0.url.path == url.path } }
        guard !fresh.isEmpty else { return }
        // Added at once and probed in the background: each probe's result is a fact about
        // the file, recorded by `resolveMedia`, not a separate undo step.
        if case .failure(let error) = perform([.addMedia(fresh.map { ProjectClip(VideoItem(url: $0)) })]) {
            statusMessage = error.message
        }
        ensureSelection()
    }

    /// Accepts a drop, expanding any folders one level deep.
    func addDropped(_ urls: [URL]) {
        if let project = urls.first(where: { $0.pathExtension.lowercased() == "yamvideo" }) {
            openProject(at: project)
            return
        }
        var expanded: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                expanded.append(contentsOf: contents)
            } else {
                expanded.append(url)
            }
        }
        addFiles(expanded)
    }

    func remove(_ id: VideoItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].status.isBusy, isConverting { return }
        perform([.removeMedia(clip: id)])
    }

    func clearFinished() {
        let finished = items.filter { if case .done = $0.status { return true } else { return false } }.map(\.id)
        guard !finished.isEmpty else { return }
        perform(finished.map { .removeMedia(clip: $0) }, label: "Clear Finished")
    }

    // MARK: - Probing

    private func probe(_ id: VideoItem.ID) {
        Task {
            do {
                let url = items.first { $0.id == id }?.url
                guard let url else { return }
                let info = try await FFmpeg.probe(url: url)
                guard items.contains(where: { $0.id == id }) else { return }
                // A project can carry its own subtitle choice; only a missing one is filled in.
                resolveMedia(id, info: info, subtitles: Self.siblingSubtitles(for: url))
                ensureSelection()
                scheduleAutosave()
                if selection == id { refreshPreview() }
            } catch {
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].status = .failed(error.localizedDescription)
            }
        }
    }

    /// A subtitle file sitting next to the video under the same name — the shape every
    /// transcription tool writes, so it is worth finding rather than making the user do it.
    static func siblingSubtitles(for video: URL) -> URL? {
        let base = video.deletingPathExtension()
        for ext in FFmpeg.subtitleExtensions {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func chooseSubtitles() {
        guard let id = selection else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = FFmpeg.subtitleExtensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.message = "Choose a subtitle file to burn into this clip."
        panel.prompt = "Use"
        panel.directoryURL = selectedItem?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSubtitles(url, for: id)
    }

    func clearSubtitles() {
        guard let id = selection else { return }
        setSubtitles(nil, for: id)
    }

    /// The subtitle file is part of the project, so choosing or clearing it is an edit:
    /// it can be undone, marks the project changed and reaches the recovery file.
    func setSubtitles(_ url: URL?, for id: VideoItem.ID) {
        if case .failure(let error) = perform([.setSubtitles(clip: id, url: url)]) { statusMessage = error.message }
    }

    // MARK: - Preview

    func refreshPreview() {
        previewTask?.cancel()
        guard let item = selectedItem, let info = item.info, info.duration >= 0 else {
            previewImage = nil
            previewOriginalImage = nil
            previewIsLoading = false
            return
        }

        let seconds = item.timeline.location(at: item.editedDuration * item.previewFraction)?.source ?? 0
        // The blur is baked into the preview, so it has to take part in the cache key.
        let regions = item.blurRegions.map { $0.rect }
        let blurKey = regions.isEmpty
            ? "none"
            : "\(settings.blurStyle.rawValue)-\(Int(settings.blurStrength))-"
                + regions.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
                    .joined(separator: "|")
        // Tone mapping changes every pixel, so it belongs in the key too, and so does
        // anything that changes how the captions are drawn.
        let toneMap = info.isHDR && settings.toneMapHDR
        let subtitles = item.burnedCaptions(settings)
        let subtitleStyle = settings.subtitleForceStyle
        let subtitleKey = subtitles.map { "\($0.path)-\(subtitleStyle)" } ?? "none"
        let frameKey = "\(item.id)-\(Int((seconds * max(1, info.fps)).rounded()))-\(blurKey)-\(toneMap)-\(subtitleKey)"
        // The colour stage changes every pixel too. Original is the frame without it;
        // with no stage to compare there is only one picture to show.
        let stage = item.colorStage(settings)
        let compared = stage.render == nil ? ColorComparison.corrected : colorComparison
        let corrected = (key: "\(frameKey)-\(stage.render?.key ?? "none")", filters: item.colorFilters(settings))
        let original = (key: "\(frameKey)-none", filters: [String]())
        let wanted = compared == .original ? [original] : compared == .split ? [corrected, original] : [corrected]
        func show(_ images: [NSImage]) {
            previewImage = images[0]
            previewOriginalImage = compared == .split ? images[1] : nil
            previewIsLoading = false
        }
        let cached = wanted.compactMap { thumbnailCache[$0.key] }
        if cached.count == wanted.count { show(cached); return }
        // A colour change on a frame already seen: Core Image grades the uncorrected
        // frame at once, and ffmpeg's exact frame replaces it when it arrives.
        if compared != .original, let render = stage.render, let base = thumbnailCache[original.key],
           let quick = ColorPipeline.quickPreview(base, render) {
            previewImage = quick
            previewOriginalImage = compared == .split ? base : nil
        }

        previewIsLoading = true
        let url = item.url
        let duration = info.duration
        let style = settings.blurStyle
        let strength = settings.blurStrength
        previewTask = Task {
            // Debounce so dragging the scrubber does not spawn a process per frame.
            try? await Task.sleep(nanoseconds: 130_000_000)
            if Task.isCancelled { return }
            do {
                var images: [NSImage] = []
                for request in wanted {
                    if let image = thumbnailCache[request.key] { images.append(image); continue }
                    let data = try await FFmpeg.thumbnail(
                        url: url, at: seconds, duration: duration,
                        regions: regions, style: style, strength: strength, toneMap: toneMap,
                        color: request.filters, subtitles: subtitles, subtitleStyle: subtitleStyle
                    )
                    if Task.isCancelled { return }
                    guard let image = NSImage(data: data) else { return }
                    thumbnailCache[request.key] = image
                    if thumbnailCache.count > 80 { thumbnailCache.removeAll() }
                    images.append(image)
                }
                show(images)
                // Keep the uncorrected frame to hand, so the next colour change on this
                // frame can be shown without waiting for ffmpeg.
                if stage.render != nil, thumbnailCache[original.key] == nil {
                    let data = try await FFmpeg.thumbnail(
                        url: url, at: seconds, duration: duration, regions: regions, style: style, strength: strength,
                        toneMap: toneMap, subtitles: subtitles, subtitleStyle: subtitleStyle)
                    if Task.isCancelled { return }
                    if let image = NSImage(data: data) { thumbnailCache[original.key] = image }
                }
            } catch {
                if !Task.isCancelled { previewIsLoading = false }
            }
        }
    }

    // MARK: - Crop editing

    /// `live` while the crop is being dragged. A drag ends with `live` false; a `.null`
    /// rect there means "the drag ended where the last update left it".
    func updateCrop(_ rect: CGRect, live: Bool = false) {
        guard let index = selectedIndex, let info = items[index].info else { return }
        let id = items[index].id, key = "crop-\(id)"
        if !live, rect.isNull { endGesture(); return }
        let command = EditCommand.setCrop(clip: id, rect: rect.evenClamped(in: info.fullFrame))
        if live || isGestureOpen(key) {
            updateGesture(key, label: "Crop", [command])
            if !live { endGesture() }
            return
        }
        perform([command])
    }

    func applyAspect(_ preset: AspectPreset) {
        guard let index = selectedIndex, let info = items[index].info else { return }
        let id = items[index].id
        var commands: [EditCommand] = [.setAspect(clip: id, preset: preset.label)]
        if let ratio = preset.ratio {
            commands.append(.setCrop(clip: id, rect: CGRect.centered(aspect: ratio, in: info.fullFrame).evenClamped(in: info.fullFrame)))
        }
        perform(commands, label: "Crop Aspect")
    }

    func resetCrop() {
        guard let index = selectedIndex, let info = items[index].info else { return }
        let id = items[index].id
        perform([.setCrop(clip: id, rect: info.fullFrame), .setAspect(clip: id, preset: "Free")], label: "Reset Crop")
    }

    // MARK: - Blur regions

    var selectedRegion: BlurRegion? {
        guard let selectedRegionID else { return nil }
        return selectedItem?.blurRegions.first { $0.id == selectedRegionID }
    }

    func addRegion(_ rect: CGRect) {
        guard let index = selectedIndex, let info = items[index].info else { return }
        let region = BlurRegion(rect: rect.evenClamped(in: info.fullFrame))
        if case .success = perform([.addBlurArea(clip: items[index].id, area: region)]) { selectedRegionID = region.id }
    }

    /// `live` is true while a drag is in progress. The drag is one gesture, and the
    /// preview is only re-rendered on release, since each render is an ffmpeg round trip.
    func updateRegion(_ id: BlurRegion.ID, rect: CGRect, live: Bool = false) {
        guard let index = selectedIndex, let info = items[index].info,
              items[index].blurRegions.contains(where: { $0.id == id }) else { return }
        let key = "blur-\(id)"
        let command = EditCommand.updateBlurArea(clip: items[index].id, area: id, rect: rect.evenClamped(in: info.fullFrame))
        if live || isGestureOpen(key) {
            updateGesture(key, label: "Move Blur", [command])
            if !live { endGesture() }
            return
        }
        perform([command])
    }

    func removeSelectedRegion() {
        guard let index = selectedIndex, let id = selectedRegionID else { return }
        let clip = items[index].id
        if case .success = perform([.removeBlurArea(clip: clip, area: id)]) {
            selectedRegionID = selectedItem?.blurRegions.last?.id
        }
    }

    func clearRegions() {
        guard let index = selectedIndex, !items[index].blurRegions.isEmpty else { return }
        perform([.replaceBlurAreas(clip: items[index].id, areas: [])], label: "Clear Blurs")
    }

    /// Adds a region covering the middle of the frame, for people who would rather not drag.
    func addDefaultRegion() {
        guard let index = selectedIndex, let info = items[index].info else { return }
        let size = CGSize(width: info.fullFrame.width / 4, height: info.fullFrame.height / 4)
        addRegion(CGRect(x: info.fullFrame.midX - size.width / 2,
                         y: info.fullFrame.midY - size.height / 2,
                         width: size.width, height: size.height))
        refreshPreview()
    }

    // MARK: - Zoom shots

    @Published var selectedShotID: ZoomShot.ID? { didSet { focusInspector(selectedShotID, .zoom) } }
    @Published var selectedGraphicID: UUID? { didSet { focusInspector(selectedGraphicID, .graphic) } }
    /// Each graphic's box on the picture, as the Preview's engine measured it.
    @Published var graphicBounds: [UUID: GraphicBounds] = [:]
    /// The Short the inspector shows and the Short viewer plays.
    @Published var selectedShortID: UUID? { didSet { focusInspector(selectedShortID, .short) } }
    /// The viewer shows the selected Short, 9:16, with its graphics and captions.
    @Published var showsShort = false
    /// Faint marks where YouTube draws its buttons over a Short. A preference, never undone.
    @Published var shortFurniture = UserDefaults.standard.object(forKey: AppModel.furnitureKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(shortFurniture, forKey: Self.furnitureKey) }
    }
    static let furnitureKey = "shortFurniture"
    /// Each graphic's box on the Short's canvas, as the Short viewer's engine measured it.
    @Published var shortGraphicBounds: [UUID: GraphicBounds] = [:]
    /// The selected Short's captions as laid out, kept while nothing they depend on changes.
    var shortCaptionCache: (key: ShortCaptionKey, value: CaptionOverlay?)?

    /// Selecting something shows it in the inspector; clearing the thing shown falls
    /// back to the recording.
    func focusInspector(_ id: UUID?, _ kind: InspectorFocus) {
        if id != nil {
            if inspectorFocus != kind { inspectorFocus = kind }
        } else if inspectorFocus == kind {
            inspectorFocus = .recording
        }
    }
    /// Level used for the next zoom you add.
    @Published var defaultZoomLevel: Double = 2

    var selectedShot: ZoomShot? {
        guard let selectedShotID else { return nil }
        return selectedItem?.zoomShots.first { $0.id == selectedShotID }
    }

    /// Current scrubber position in seconds.
    var previewTime: Double {
        guard let item = selectedItem, item.info != nil else { return 0 }
        return item.editedDuration * item.previewFraction
    }

    /// Adds a zoom starting at the scrubber, targeting `point` (full-frame pixels).
    @discardableResult
    func addZoom(at point: CGPoint) -> Bool {
        guard let index = selectedIndex, items[index].info != nil else { return false }
        let shot = ZoomShot(start: previewTime, level: defaultZoomLevel, target: point)

        guard shot.end <= items[index].editedDuration + 0.001 else {
            statusMessage = "Not enough clip left for a \(formatDuration(shot.duration)) zoom."
            return false
        }
        guard !items[index].zoomShots.contains(where: { $0.overlaps(shot) }) else {
            statusMessage = "That overlaps an existing zoom — move the playhead clear of it."
            return false
        }

        switch perform([.addZoom(clip: items[index].id, zoom: shot)]) {
        case .success:
            selectedShotID = shot.id
            statusMessage = "Zoom \(shot.levelLabel) at \(formatDuration(shot.start))."
            return true
        case .failure(let error):
            statusMessage = error.message
            return false
        }
    }

    /// Adds a zoom aimed at the middle of the framing, for keyboard use or when the
    /// exact spot does not matter.
    func addZoomAtCentre() {
        guard let item = selectedItem, let info = item.info else { return }
        let frame = item.crop ?? info.fullFrame
        addZoom(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Applies an edit only if it keeps the shot inside the clip and clear of the others.
    /// With a `gesture` key the change is shown live and committed when the gesture ends.
    private func mutateShot(_ id: ZoomShot.ID, gesture: String? = nil, _ transform: (inout ZoomShot) -> Void) {
        guard let index = selectedIndex, let info = items[index].info,
              let shotIndex = items[index].zoomShots.firstIndex(where: { $0.id == id })
        else { return }

        var shot = items[index].zoomShots[shotIndex]
        transform(&shot)
        shot.start = max(0, min(shot.start, max(0, items[index].editedDuration - shot.duration)))
        shot.hold = max(0.2, shot.hold)
        guard shot.end <= items[index].editedDuration + 0.001 else {
            statusMessage = "There is not enough video left for that zoom duration."
            return
        }
        shot.target.x = min(max(0, shot.target.x), info.fullFrame.maxX)
        shot.target.y = min(max(0, shot.target.y), info.fullFrame.maxY)

        let others = items[index].zoomShots.filter { $0.id != id }
        guard !others.contains(where: { $0.overlaps(shot) }) else {
            statusMessage = "That would overlap another zoom."
            return
        }
        let command = EditCommand.updateZoom(clip: items[index].id, zoom: shot)
        if let gesture {
            updateGesture(gesture, label: "Adjust Zoom", [command])
            return
        }
        guard shot != items[index].zoomShots[shotIndex] else { return }
        if case .failure(let error) = perform([command]) { statusMessage = error.message }
    }

    /// Dragging a zoom's target on the canvas. The view ends the gesture on release.
    func moveZoomTarget(_ id: ZoomShot.ID, to point: CGPoint) {
        mutateShot(id, gesture: "zoom-target-\(id)") { $0.target = point }
    }

    func setZoomLevel(_ id: ZoomShot.ID, _ level: Double) {
        mutateShot(id) { $0.level = level }
        defaultZoomLevel = level
    }

    /// `live` while the hold slider is being dragged; the slider ends the gesture.
    func setZoomHold(_ id: ZoomShot.ID, _ hold: Double, live: Bool = false) {
        let duration = selectedItem?.editedDuration ?? 0
        mutateShot(id, gesture: live ? "zoom-hold-\(id)" : nil) { shot in
            shot.hold = min(max(0.2, hold), max(0.2, duration - shot.start - 2 * ZoomShot.ease))
        }
    }

    func setZoomStart(_ id: ZoomShot.ID, _ start: Double) {
        mutateShot(id) { $0.start = start }
    }

    /// Moves the shot's start to wherever the playhead is.
    func retimeSelectedZoomToPlayhead() {
        guard let id = selectedShotID else { return }
        setZoomStart(id, previewTime)
    }

    func removeSelectedZoom() {
        guard let index = selectedIndex, let id = selectedShotID else { return }
        if case .success = perform([.removeZoom(clip: items[index].id, zoom: id)]) {
            selectedShotID = selectedItem?.zoomShots.last?.id
        }
    }

    func clearZooms() {
        guard let index = selectedIndex, !items[index].zoomShots.isEmpty else { return }
        perform([.replaceZooms(clip: items[index].id, zooms: [])], label: "Clear Zooms")
    }

    /// Jumps the preview to the middle of a shot's hold, so its framing can be checked.
    func scrubToShot(_ shot: ZoomShot) {
        guard let info = selectedItem?.info, info.duration > 0 else { return }
        setPreviewFraction((shot.start + ZoomShot.ease + shot.hold / 2) / max(0.001, selectedItem?.editedDuration ?? 0))
    }

    func setPreviewFraction(_ fraction: Double) {
        guard let index = selectedIndex else { return }
        items[index].previewFraction = min(max(fraction, 0), 1)
        if showPlayback { playback.seek(to: previewTime) } else { refreshPreview() }
    }

    /// Copies the selected item's crop and blur areas onto every other queued clip with the
    /// same dimensions — the coordinates only mean the same thing at the same frame size.
    func applyCropToAll() {
        guard let source = selectedItem, let crop = source.crop, let info = source.info else { return }
        var commands: [EditCommand] = []
        var applied = 0
        for item in items where item.id != source.id {
            guard let other = item.info, other.width == info.width, other.height == info.height else { continue }
            commands += [
                .setCrop(clip: item.id, rect: crop),
                .setAspect(clip: item.id, preset: source.aspectLabel),
                // Fresh ids so each clip owns its own regions and zooms.
                .replaceBlurAreas(clip: item.id, areas: source.blurRegions.map { BlurRegion(rect: $0.rect) }),
                .replaceZooms(clip: item.id, zooms: source.zoomShots.filter { $0.end <= item.editedDuration }.map {
                    ZoomShot(start: $0.start, hold: $0.hold, level: $0.level, target: $0.target)
                }),
            ]
            applied += 1
        }
        if !commands.isEmpty, case .failure(let error) = perform(commands, label: "Apply to All") {
            statusMessage = error.message; return
        }
        let what = source.blurRegions.isEmpty ? "crop" : "crop and blur areas"
        statusMessage = applied == 0
            ? "No other clips share these dimensions."
            : "Applied \(what) to \(applied) other clip\(applied == 1 ? "" : "s")."
    }

    // MARK: - Panels

    func promptForFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.acceptedTypes + [.yamVideoProject]
        panel.message = "Choose the videos you want to crop and convert."
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            addDropped(panel.urls)
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should converted MP4 files be saved?"
        if panel.runModal() == .OK, let url = panel.url {
            var updated = settings
            updated.outputFolder = url
            updateSettings(updated)
        }
    }

    func locateFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Select the folder that contains ffmpeg and ffprobe (for example /opt/homebrew/bin)."
        panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            FFmpeg.setOverrideFolder(url)
            toolsAvailable = FFmpeg.isAvailable
            refreshCapabilities()
            if toolsAvailable {
                statusMessage = "Found ffmpeg."
                for item in items where item.info == nil { probe(item.id) }
            } else {
                statusMessage = "ffmpeg and ffprobe were not in that folder."
            }
        }
    }

    // MARK: - Conversion

    var convertibleCount: Int {
        items.filter { item in
            guard item.info != nil else { return false }
            if case .done = item.status { return false }
            if case .failed = item.status { return false }
            return true
        }.count
    }

    func convertAll() {
        guard !isConverting, toolsAvailable else { return }
        let targets = items.compactMap { item -> VideoItem.ID? in
            guard item.info != nil else { return nil }
            if case .done = item.status { return nil }
            if case .failed = item.status { return nil }
            return item.id
        }
        guard !targets.isEmpty else { return }
        run(targets)
    }

    func convertSelected() {
        guard !isConverting, toolsAvailable, let id = selection,
              let item = selectedItem, item.info != nil else { return }
        run([id])
    }

    func retry(_ id: VideoItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].info == nil {
            items[index].status = .probing
            probe(id)
        } else {
            items[index].status = .ready
        }
    }

    private func run(_ ids: [VideoItem.ID]) {
        playback.pause()
        let exportSettings = settings
        isConverting = true
        statusMessage = nil
        conversionTask = Task {
            var succeeded = 0
            var failed = 0

            for id in ids {
                if Task.isCancelled { break }
                guard let index = items.firstIndex(where: { $0.id == id }),
                      let info = items[index].info else { continue }
                let item = items[index]
                let crop = (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
                let output = FFmpeg.outputURL(for: item.url, settings: exportSettings)

                items[index].status = .converting(0)

                do {
                    try await FFmpeg.export(
                        input: item.url,
                        output: output,
                        info: info,
                        crop: crop,
                        regions: item.blurRegions.map { $0.rect },
                        zoomShots: item.zoomShots,
                        segments: item.segments,
                        settings: exportSettings,
                        subtitles: item.burnedCaptions(exportSettings),
                        color: item.colorStage(exportSettings),
                        effects: item.blurEffects,
                        graphics: item.exportGraphics(exportSettings)
                    ) { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                            if case .converting = self.items[i].status {
                                self.items[i].status = .converting(fraction)
                            }
                        }
                    }
                    if let i = items.firstIndex(where: { $0.id == id }) {
                        items[i].status = .done(output)
                    }
                    succeeded += 1
                } catch is CancellationError {
                    if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = .ready }
                    break
                } catch {
                    if let i = items.firstIndex(where: { $0.id == id }) {
                        items[i].status = .failed(error.localizedDescription)
                    }
                    failed += 1
                }
            }

            isConverting = false
            if Task.isCancelled {
                statusMessage = "Conversion cancelled."
            } else if failed == 0 {
                statusMessage = succeeded == 1
                    ? "Converted 1 file."
                    : "Converted \(succeeded) files."
            } else {
                statusMessage = "Converted \(succeeded), \(failed) failed."
            }
        }
    }

    func cancelConversion() {
        movieExportTask?.cancel()
        conversionTask?.cancel()
        // Stop also stops an export a local agent started; the owner stays in charge.
        for (id, job) in agentJobs where job.kind == "export" { agentJobTasks[id]?.cancel() }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The exact ffmpeg invocation for the selected clip — handy for sanity-checking or
    /// scripting. A GIF export runs two: the palette, then the encode against it.
    var previewCommand: String? {
        if isMovieMode {
            guard let plan = try? moviePlan() else { return nil }
            let output = (settings.outputFolder ?? plan.clips[0].url.deletingLastPathComponent())
                .appendingPathComponent("YamVideo-Movie.\(settings.format.fileExtension)")
            let commands: [[String]]
            if settings.format == .gif {
                let palette = FFmpeg.paletteURL(for: output)
                commands = [FFmpeg.movieArguments(plan: plan, settings: settings, output: palette, palettePass: true),
                            FFmpeg.movieArguments(plan: plan, settings: settings, output: output, palette: palette)]
            } else { commands = [FFmpeg.movieArguments(plan: plan, settings: settings, output: output)] }
            return commands.map(Self.displayCommand).joined(separator: "\n\n")
        }
        guard let item = selectedItem, let info = item.info else { return nil }
        let crop = (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let output = FFmpeg.outputURL(for: item.url, settings: settings)
        return FFmpeg.exportCommands(
            input: item.url, output: output, info: info, crop: crop,
            regions: item.blurRegions.map { $0.rect }, zoomShots: item.zoomShots,
            segments: item.segments, settings: settings, subtitles: item.burnedCaptions(settings),
            color: item.colorFilters(settings), effects: item.blurEffects, graphics: item.exportGraphics(settings)
        ).map(Self.displayCommand).joined(separator: "\n\n")
    }

    private static func displayCommand(_ command: [String]) -> String {
        let args = command.filter { $0 != "-progress" && $0 != "pipe:1" && $0 != "-nostats" }
        return (["ffmpeg"] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }
}
