import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    /// Shared so files opened from Finder reach the same window.
    static let shared = AppModel()

    @Published var items: [VideoItem] = []
    @Published var selection: VideoItem.ID?
    @Published var settings = ExportSettings()
    @Published var previewImage: NSImage?
    @Published var previewIsLoading = false
    @Published var isConverting = false
    @Published var toolsAvailable = FFmpeg.isAvailable
    /// Whether the located ffmpeg can write WebP at all — libwebp is an optional build flag.
    @Published var webpAvailable = true
    @Published var statusMessage: String?
    @Published var editorMode: EditorMode = .crop
    @Published var selectedRegionID: BlurRegion.ID?

    private var previewTask: Task<Void, Never>?
    private var conversionTask: Task<Void, Never>?
    private var thumbnailCache: [String: NSImage] = [:]

    static let acceptedTypes: [UTType] = [
        .movie, .video, .quickTimeMovie, .mpeg4Movie, .audiovisualContent,
    ]

    private static let acceptedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "flv", "mts", "m2ts", "3gp", "hevc",
    ]

    init() {
        refreshCapabilities()
    }

    /// Asks ffmpeg what it was built with, so the format picker can say up front that a
    /// WebP export is not going to work rather than failing at the end of one.
    private func refreshCapabilities() {
        guard toolsAvailable else { return }
        Task { webpAvailable = await FFmpeg.supportsWebP() }
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

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return items.firstIndex { $0.id == selection }
    }

    // MARK: - Queue management

    func addFiles(_ urls: [URL]) {
        let fresh = urls
            .filter { Self.acceptedExtensions.contains($0.pathExtension.lowercased()) }
            .filter { url in !items.contains { $0.url.path == url.path } }
        guard !fresh.isEmpty else { return }

        let newItems = fresh.map { VideoItem(url: $0) }
        items.append(contentsOf: newItems)
        ensureSelection()
        for item in newItems { probe(item.id) }
    }

    /// Accepts a drop, expanding any folders one level deep.
    func addDropped(_ urls: [URL]) {
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
        items.remove(at: index)
        if selection == id {
            selection = items.indices.contains(index) ? items[index].id : items.last?.id
            refreshPreview()
        }
    }

    func clearFinished() {
        items.removeAll { if case .done = $0.status { return true } else { return false } }
        if let selection, !items.contains(where: { $0.id == selection }) {
            self.selection = items.first?.id
            refreshPreview()
        }
    }

    // MARK: - Probing

    private func probe(_ id: VideoItem.ID) {
        Task {
            do {
                let url = items.first { $0.id == id }?.url
                guard let url else { return }
                let info = try await FFmpeg.probe(url: url)
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].info = info
                items[index].crop = info.fullFrame
                items[index].status = .ready
                ensureSelection()
                if selection == id { refreshPreview() }
            } catch {
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Preview

    func refreshPreview() {
        previewTask?.cancel()
        guard let item = selectedItem, let info = item.info, info.duration >= 0 else {
            previewImage = nil
            previewIsLoading = false
            return
        }

        let seconds = (info.duration > 0 ? info.duration : 0) * item.previewFraction
        // The blur is baked into the preview, so it has to take part in the cache key.
        let regions = item.blurRegions.map { $0.rect }
        let blurKey = regions.isEmpty
            ? "none"
            : "\(settings.blurStyle.rawValue)-\(Int(settings.blurStrength))-"
                + regions.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
                    .joined(separator: "|")
        let key = "\(item.id)-\(Int(seconds * 4))-\(blurKey)"
        if let cached = thumbnailCache[key] {
            previewImage = cached
            previewIsLoading = false
            return
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
                let data = try await FFmpeg.thumbnail(
                    url: url, at: seconds, duration: duration,
                    regions: regions, style: style, strength: strength
                )
                if Task.isCancelled { return }
                guard let image = NSImage(data: data) else { return }
                thumbnailCache[key] = image
                if thumbnailCache.count > 80 { thumbnailCache.removeAll() }
                previewImage = image
                previewIsLoading = false
            } catch {
                if !Task.isCancelled { previewIsLoading = false }
            }
        }
    }

    // MARK: - Crop editing

    func updateCrop(_ rect: CGRect) {
        guard let index = selectedIndex, let info = items[index].info else { return }
        items[index].crop = rect.evenClamped(in: info.fullFrame)
    }

    func applyAspect(_ preset: AspectPreset) {
        guard let index = selectedIndex, let info = items[index].info else { return }
        items[index].aspectLock = preset.ratio
        items[index].aspectLabel = preset.label
        if let ratio = preset.ratio {
            items[index].crop = CGRect
                .centered(aspect: ratio, in: info.fullFrame)
                .evenClamped(in: info.fullFrame)
        }
    }

    func resetCrop() {
        guard let index = selectedIndex, let info = items[index].info else { return }
        items[index].crop = info.fullFrame
        items[index].aspectLock = nil
        items[index].aspectLabel = "Free"
    }

    // MARK: - Blur regions

    var selectedRegion: BlurRegion? {
        guard let selectedRegionID else { return nil }
        return selectedItem?.blurRegions.first { $0.id == selectedRegionID }
    }

    func addRegion(_ rect: CGRect) {
        guard let index = selectedIndex, let info = items[index].info else { return }
        let region = BlurRegion(rect: rect.evenClamped(in: info.fullFrame))
        items[index].blurRegions.append(region)
        selectedRegionID = region.id
    }

    /// `live` is true while a drag is in progress — the preview is only re-rendered on
    /// release, since each render is an ffmpeg round trip.
    func updateRegion(_ id: BlurRegion.ID, rect: CGRect, live: Bool = false) {
        guard let index = selectedIndex, let info = items[index].info,
              let regionIndex = items[index].blurRegions.firstIndex(where: { $0.id == id })
        else { return }
        items[index].blurRegions[regionIndex].rect = rect.evenClamped(in: info.fullFrame)
        if !live { refreshPreview() }
    }

    func removeSelectedRegion() {
        guard let index = selectedIndex, let id = selectedRegionID else { return }
        items[index].blurRegions.removeAll { $0.id == id }
        selectedRegionID = items[index].blurRegions.last?.id
        refreshPreview()
    }

    func clearRegions() {
        guard let index = selectedIndex else { return }
        items[index].blurRegions.removeAll()
        selectedRegionID = nil
        refreshPreview()
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

    @Published var selectedShotID: ZoomShot.ID?
    /// Level used for the next zoom you add.
    @Published var defaultZoomLevel: Double = 2

    var selectedShot: ZoomShot? {
        guard let selectedShotID else { return nil }
        return selectedItem?.zoomShots.first { $0.id == selectedShotID }
    }

    /// Current scrubber position in seconds.
    var previewTime: Double {
        guard let item = selectedItem, let info = item.info else { return 0 }
        return info.duration * item.previewFraction
    }

    /// Adds a zoom starting at the scrubber, targeting `point` (full-frame pixels).
    @discardableResult
    func addZoom(at point: CGPoint) -> Bool {
        guard let index = selectedIndex, let info = items[index].info else { return false }
        let shot = ZoomShot(start: previewTime, level: defaultZoomLevel, target: point)

        guard shot.end <= info.duration + 0.01 else {
            statusMessage = "Not enough clip left for a \(formatDuration(shot.duration)) zoom."
            return false
        }
        guard !items[index].zoomShots.contains(where: { $0.overlaps(shot) }) else {
            statusMessage = "That overlaps an existing zoom — move the playhead clear of it."
            return false
        }

        items[index].zoomShots.append(shot)
        items[index].zoomShots.sort { $0.start < $1.start }
        selectedShotID = shot.id
        statusMessage = "Zoom \(shot.levelLabel) at \(formatDuration(shot.start))."
        return true
    }

    /// Adds a zoom aimed at the middle of the framing, for keyboard use or when the
    /// exact spot does not matter.
    func addZoomAtCentre() {
        guard let item = selectedItem, let info = item.info else { return }
        let frame = item.crop ?? info.fullFrame
        addZoom(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Applies an edit only if it keeps the shot inside the clip and clear of the others.
    private func mutateShot(_ id: ZoomShot.ID, _ transform: (inout ZoomShot) -> Void) {
        guard let index = selectedIndex, let info = items[index].info,
              let shotIndex = items[index].zoomShots.firstIndex(where: { $0.id == id })
        else { return }

        var shot = items[index].zoomShots[shotIndex]
        transform(&shot)
        shot.start = max(0, min(shot.start, max(0, info.duration - shot.duration)))
        shot.hold = max(0.2, shot.hold)
        shot.target.x = min(max(0, shot.target.x), info.fullFrame.maxX)
        shot.target.y = min(max(0, shot.target.y), info.fullFrame.maxY)

        let others = items[index].zoomShots.filter { $0.id != id }
        guard !others.contains(where: { $0.overlaps(shot) }) else {
            statusMessage = "That would overlap another zoom."
            return
        }
        items[index].zoomShots[shotIndex] = shot
        items[index].zoomShots.sort { $0.start < $1.start }
    }

    func moveZoomTarget(_ id: ZoomShot.ID, to point: CGPoint) {
        mutateShot(id) { $0.target = point }
    }

    func setZoomLevel(_ id: ZoomShot.ID, _ level: Double) {
        mutateShot(id) { $0.level = level }
        defaultZoomLevel = level
    }

    func setZoomHold(_ id: ZoomShot.ID, _ hold: Double) {
        mutateShot(id) { $0.hold = hold }
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
        items[index].zoomShots.removeAll { $0.id == id }
        selectedShotID = items[index].zoomShots.last?.id
    }

    func clearZooms() {
        guard let index = selectedIndex else { return }
        items[index].zoomShots.removeAll()
        selectedShotID = nil
    }

    /// Jumps the preview to the middle of a shot's hold, so its framing can be checked.
    func scrubToShot(_ shot: ZoomShot) {
        guard let info = selectedItem?.info, info.duration > 0 else { return }
        setPreviewFraction((shot.start + ZoomShot.ease + shot.hold / 2) / info.duration)
    }

    func setPreviewFraction(_ fraction: Double) {
        guard let index = selectedIndex else { return }
        items[index].previewFraction = min(max(fraction, 0), 1)
        refreshPreview()
    }

    /// Copies the selected item's crop and blur areas onto every other queued clip with the
    /// same dimensions — the coordinates only mean the same thing at the same frame size.
    func applyCropToAll() {
        guard let source = selectedItem, let crop = source.crop, let info = source.info else { return }
        var applied = 0
        for index in items.indices where items[index].id != source.id {
            guard let other = items[index].info, other.width == info.width, other.height == info.height
            else { continue }
            items[index].crop = crop
            items[index].aspectLock = source.aspectLock
            items[index].aspectLabel = source.aspectLabel
            // Fresh ids so each clip owns its own regions.
            items[index].blurRegions = source.blurRegions.map { BlurRegion(rect: $0.rect) }
            items[index].zoomShots = source.zoomShots.map {
                ZoomShot(start: $0.start, hold: $0.hold, level: $0.level, target: $0.target)
            }
            applied += 1
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
        panel.allowedContentTypes = Self.acceptedTypes
        panel.message = "Choose the videos you want to crop and convert."
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            addFiles(panel.urls)
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
            settings.outputFolder = url
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
                let output = FFmpeg.outputURL(for: item.url, settings: settings)

                items[index].status = .converting(0)
                selection = id

                do {
                    try await FFmpeg.export(
                        input: item.url,
                        output: output,
                        info: info,
                        crop: crop,
                        regions: item.blurRegions.map { $0.rect },
                        zoomShots: item.zoomShots,
                        settings: settings
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
        conversionTask?.cancel()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The exact ffmpeg invocation for the selected clip — handy for sanity-checking or
    /// scripting. A GIF export runs two: the palette, then the encode against it.
    var previewCommand: String? {
        guard let item = selectedItem, let info = item.info else { return nil }
        let crop = (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let output = FFmpeg.outputURL(for: item.url, settings: settings)
        return FFmpeg.exportCommands(
            input: item.url, output: output, info: info, crop: crop,
            regions: item.blurRegions.map { $0.rect }, zoomShots: item.zoomShots,
            settings: settings
        ).map { command in
            let args = command.filter { $0 != "-progress" && $0 != "pipe:1" && $0 != "-nostats" }
            return (["ffmpeg"] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }
                .joined(separator: " ")
        }.joined(separator: "\n\n")
    }
}
