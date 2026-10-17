import AppKit
import AVFoundation
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

// Shorts in the app: the owner's actions, the Short viewer, finding the speaker for the
// window, and Export Short for YouTube. See Shorts.swift for the data and the layout.

// MARK: - Finding the speaker

enum ShortFraming {
    /// Where the speaker's face is in `image`, top-left origin and in its pixels: the
    /// largest face Apple Vision finds, or else the middle of whatever stands in front.
    static func speaker(in image: CGImage) throws -> CGPoint? {
        let faces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([faces])
        let width = Double(image.width), height = Double(image.height)
        if let face = faces.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            let box = face.boundingBox
            return CGPoint(x: box.midX * width, y: (1 - box.midY) * height)
        }
        if let cut = try SpeakerCutout.cut(image) {
            // The top third of a person is about where the face is.
            return CGPoint(x: cut.box.midX, y: cut.box.minY + cut.box.height / 3)
        }
        return nil
    }

    /// A 9:16 window `height` source pixels tall around the speaker: centred on them across,
    /// with their face about two fifths of the way down.
    static func window(around speaker: CGPoint, height: Double, in frame: CGRect, info: MediaInfo) -> CGRect {
        let h = min(height, frame.height)
        return ShortFormat.window(centre: CGPoint(x: speaker.x, y: speaker.y + h * 0.1), height: h, in: frame, info: info)
    }
}

extension AppModel {
    /// The frame at an edited time of a recording as the source shows it, uncropped.
    func sourceFrame(_ clip: ProjectClip, at time: Double) async throws -> CGImage {
        guard let info = clip.info else { throw FFmpegError(message: "That recording is still loading.") }
        let source = clip.timeline.location(at: time)?.source ?? 0
        let data = try await FFmpeg.thumbnail(url: clip.url, at: source, duration: info.duration, toneMap: info.isHDR && settings.toneMapHDR,
                                              maxWidth: info.width)
        guard let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
            throw FFmpegError(message: "The frame could not be read.")
        }
        return image
    }

    /// A window for `short` centred on the speaker at its middle, as tall as its window is
    /// now; nil when nobody is found.
    func speakerWindow(_ clip: ProjectClip, short: Short) async throws -> CGRect? {
        guard let info = clip.info else { return nil }
        let image = try await sourceFrame(clip, at: (short.start + short.end) / 2)
        guard let found = try ShortFraming.speaker(in: image) else { return nil }
        let k = Double(info.width) / Double(image.width)
        let frame = (clip.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let height = short.frame(info: info, crop: clip.crop).height
        return ShortFraming.window(around: CGPoint(x: found.x * k, y: found.y * k), height: height, in: frame, info: info)
    }
}

// MARK: - Actions

extension AppModel {
    var selectedShort: Short? { selectedItem?.short(selectedShortID) }

    /// What the viewer shows: the edit frame, the 16:9 Preview, or the selected Short.
    enum Viewer: Hashable { case frame, preview, short }

    var viewer: Viewer { showPlayback ? (showsShort ? .short : .preview) : .frame }

    func setViewer(_ viewer: Viewer) {
        switch viewer {
        case .frame: setPlaybackVisible(false)
        case .preview:
            showsShort = false; playback.shortID = nil
            setPlaybackVisible(true)
        case .short:
            guard let item = selectedItem else { return }
            guard let short = item.short(selectedShortID) ?? item.shorts.first else {
                statusMessage = "This recording has no Short yet. Add one in the inspector's Shorts section."
                return
            }
            showShort(short)
        }
    }

    /// Shows a Short in the viewer, with the playhead inside it.
    func showShort(_ short: Short, play: Bool = false) {
        guard let item = selectedItem, item.duration(of: short) != nil else { return }
        selectedShortID = short.id
        showsShort = true
        playback.shortID = short.id
        showPlayback = true
        let time = previewTime >= short.start && previewTime < short.end ? previewTime : short.start
        if item.editedDuration > 0 { items[selectedIndex!].previewFraction = min(1, max(0, time / item.editedDuration)) }
        playback.prepare(item, settings: settings, at: time, play: play)
    }

    /// Selects a Short; in the Short viewer, it shows that one.
    func selectShort(_ id: UUID) {
        selectedShortID = id
        if showsShort, showPlayback, let short = selectedItem?.short(id), playback.shortID != id { showShort(short) }
    }

    /// The Short viewer's overlay: the Short's graphics on its canvas and its captions, in
    /// recording time, over its 9:16 window.
    func shortOverlay(_ item: VideoItem, info: MediaInfo, short: Short) -> GraphicsOverlayInput {
        let key = item.shortCaptionKey(short, settings: settings)
        let captions: CaptionOverlay?
        if let cached = shortCaptionCache, cached.key == key { captions = cached.value }
        else {
            captions = item.shortCaptionOverlay(short, settings: settings)
            shortCaptionCache = (key, captions)
        }
        let track = item.shortGraphics(short, recordingTime: true) ?? GraphicsTrack(canvas: .short(short.panels, zoom: short.zoomLevel))
        return GraphicsOverlayInput(clip: item.id, track: track, duration: item.editedDuration, fps: info.fpsExpression,
                                    frame: short.frame(info: info, crop: item.crop).size, time: previewTime, captions: captions)
    }

    /// A new Short: the whole recording when it is under 3:00, else a minute from the
    /// playhead (or up to the next Short), centred on the speaker once Vision has looked.
    func addShortAtPlayhead() {
        guard let index = selectedIndex, items[index].info != nil else { statusMessage = "Select a recording first."; return }
        let item = items[index]
        guard let span = item.newShortSpan(at: previewTime) else {
            statusMessage = "There is no room for a Short here: move the playhead to footage no other Short covers."
            return
        }
        let short = Short(start: span.start, end: span.end)
        switch perform([.addShort(clip: item.id, short: short)], label: "Add Short") {
        case .success:
            selectedShortID = short.id
            statusMessage = "Added a \(PublishInfo.timestamp(span.end - span.start)) Short from \(PublishInfo.timestamp(span.start)). Looking for the speaker…"
            centreShortOnSpeaker(short.id, label: "Centre Short on Speaker", quiet: true)
        case .failure(let error):
            statusMessage = error.message
        }
    }

    /// Changes one Short. `live` while a drag or slider moves: shown at once and committed
    /// as one undo step when it ends.
    func updateShort(_ id: UUID, label: String = "Edit Short", live: Bool = false, _ change: (inout Short) -> Void) {
        guard let index = selectedIndex, let original = items[index].short(id) else { return }
        var short = original
        change(&short)
        guard short != original else { return }
        let command = EditCommand.updateShort(clip: items[index].id, short: short)
        let key = "short-\(id)-\(label)"
        if live || isGestureOpen(key) {
            if let error = updateGesture(key, label: label, [command]) { statusMessage = error.message }
            if !live { endGesture() }
            return
        }
        if case .failure(let error) = perform([command], label: label) { statusMessage = error.message }
    }

    /// Moves a Short so it starts at `start`, keeping its length, inside the recording and
    /// clear of the other Shorts.
    func moveShort(_ id: UUID, to start: Double, live: Bool = false) {
        guard let item = selectedItem, let short = item.short(id) else { return }
        let others = item.shorts.filter { $0.id != id }
        let lower = others.filter { $0.end <= short.start + 0.000001 }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= short.end - 0.000001 }.map(\.start).min() ?? item.editedDuration
        let length = short.length
        let placed = min(max(start, lower), max(lower, upper - length))
        updateShort(id, label: "Move Short", live: live) { $0.start = placed; $0.end = placed + min(length, upper - placed) }
    }

    /// Moves one edge of a Short; it stays 1 s to 3:00 long and clear of its neighbours.
    func setShortEdge(_ id: UUID, start: Double? = nil, end: Double? = nil, live: Bool = false) {
        guard let item = selectedItem, let short = item.short(id) else { return }
        let others = item.shorts.filter { $0.id != id }
        let lower = others.filter { $0.end <= short.start + 0.000001 }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= short.end - 0.000001 }.map(\.start).min() ?? item.editedDuration
        let lengths = ShortFormat.lengths
        updateShort(id, label: "Change Short Length", live: live) { short in
            if let start { short.start = min(max(start, lower, short.end - lengths.upperBound), short.end - lengths.lowerBound) }
            if let end { short.end = max(min(end, upper, short.start + lengths.upperBound), short.start + lengths.lowerBound) }
        }
    }

    func removeSelectedShort() {
        guard let index = selectedIndex, let id = selectedShortID else { return }
        if case .success = perform([.removeShort(clip: items[index].id, short: id)]) { selectedShortID = nil }
    }

    /// Centres the Short's window on the speaker, found by Apple Vision at its middle.
    func centreShortOnSpeaker(_ id: UUID, label: String = "Centre on Speaker", quiet: Bool = false) {
        guard let index = selectedIndex, let short = items[index].short(id) else { return }
        let clip = ProjectClip(items[index])
        Task {
            do {
                guard let window = try await speakerWindow(clip, short: short) else {
                    if !quiet { statusMessage = "No face or person was found in the middle of this Short; the window stays where it is." }
                    else { statusMessage = "Added a Short; no speaker was found, so its window is centred." }
                    return
                }
                updateShort(id, label: label) { $0.window = window }
                statusMessage = "The Short's window is centred on the speaker."
            } catch {
                statusMessage = "Could not look for the speaker: \(error.localizedDescription)"
            }
        }
    }

    /// Moves the window across (0 left – 1 right) and down, and sets how tight it is
    /// (1 = the full height of the picture, up to 3 times closer).
    func setShortWindow(_ id: UUID, across: Double? = nil, down: Double? = nil, size: Double? = nil, live: Bool = false) {
        guard let item = selectedItem, let info = item.info, let short = item.short(id) else { return }
        let frame = (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let current = short.frame(info: info, crop: item.crop)
        let place = ShortWindowPlace(window: current, in: frame)
        let height = frame.height / min(3, max(1, size ?? place.size))
        let width = height * ShortFormat.aspect
        let a = across ?? place.across, d = down ?? place.down
        let centre = CGPoint(x: frame.minX + width / 2 + a * max(0, frame.width - width),
                             y: frame.minY + height / 2 + d * max(0, frame.height - height))
        let window = ShortFormat.window(centre: centre, height: height, in: frame, info: info)
        updateShort(id, label: "Frame Short", live: live) { $0.window = window }
    }

    func setShortCoverToPlayhead(_ id: UUID) {
        guard let short = selectedItem?.short(id) else { return }
        let time = min(max(0, previewTime - short.start), short.length)
        updateShort(id, label: "Short Cover") { $0.cover = time }
    }

    func setShortGraphic(_ id: UUID, graphic: UUID, shown: Bool) {
        updateShort(id, label: shown ? "Show Graphic in Short" : "Hide Graphic in Short") { short in
            short.hidden.removeAll { $0 == graphic }
            if !shown { short.hidden.append(graphic) }
        }
    }

    /// Moves or resizes a graphic on a Short's canvas; nil puts it back in its zone.
    func placeGraphicInShort(_ id: UUID, graphic: UUID, _ transform: GraphicTransform?, live: Bool = false, label: String = "Move Graphic in Short") {
        updateShort(id, label: label, live: live) { short in
            if let transform, !transform.isIdentity { short.placements[graphic] = transform } else { short.placements.removeValue(forKey: graphic) }
        }
    }
}

/// A Short window's place in the picture, as the inspector's sliders show it.
struct ShortWindowPlace: Equatable {
    /// 0 at the left edge of the picture, 1 at the right.
    var across: Double
    /// 0 at the top, 1 at the bottom; only moves a window tighter than the full height.
    var down: Double
    /// 1 is the full height of the picture; 2 is twice as close.
    var size: Double

    init(window: CGRect, in frame: CGRect) {
        let spareX = frame.width - window.width, spareY = frame.height - window.height
        across = spareX > 1 ? min(1, max(0, (window.minX - frame.minX) / spareX)) : 0.5
        down = spareY > 1 ? min(1, max(0, (window.minY - frame.minY) / spareY)) : 0.5
        size = frame.height / max(16, window.height)
    }
}

extension VideoItem {
    /// The Short's length when it is one of this recording's, else nil.
    func duration(of short: Short) -> Double? { shorts.contains { $0.id == short.id } ? short.length : nil }

    /// Where a new Short goes: the whole recording when it is under 3:00 and has no Short
    /// yet; else a minute from `time` (or the start of the Short it falls in, moved past
    /// it), shortened to stop at the next Short. Nil when there is less than a second.
    func newShortSpan(at time: Double) -> (start: Double, end: Double)? {
        let duration = editedDuration
        if shorts.isEmpty, duration <= ShortFormat.lengths.upperBound { return (0, duration) }
        var start = min(max(0, time), duration)
        for short in shorts.sorted(by: { $0.start < $1.start }) where start >= short.start - 0.000001 && start < short.end - 0.000001 {
            start = short.end
        }
        let next = shorts.filter { $0.start >= start - 0.000001 }.map(\.start).min() ?? duration
        let end = min(start + ShortFormat.defaultLength, next, duration)
        guard end - start >= ShortFormat.lengths.lowerBound - 0.000001 else { return nil }
        return (start, end)
    }
}

// MARK: - Export Short for YouTube

enum ShortExport {
    /// What one Export Short for YouTube writes into its folder: the cover takes the
    /// thumbnail's place.
    static func files(in folder: URL, short: Short, index: Int, recording: VideoItem, settings: ExportSettings, unique: Bool) -> YouTubeExport.Files {
        let publish = short.publishInfo(recording: recording.publish)
        let fallback = recording.url.deletingPathExtension().lastPathComponent + " Short \(index + 1)"
        let captions = !recording.shortCaptions(short, settings: settings).isEmpty
        let stem = PublishInfo.fileStem(publish.title, fallback: fallback)
        func named(_ stem: String) -> YouTubeExport.Files {
            YouTubeExport.Files(video: folder.appendingPathComponent(stem + ".mp4"),
                                captions: captions ? folder.appendingPathComponent("\(stem).\(publish.language).srt") : nil,
                                thumbnail: folder.appendingPathComponent(stem + " cover.jpg"),
                                text: folder.appendingPathComponent(stem + " YouTube.txt"),
                                json: folder.appendingPathComponent(stem + ".youtube.json"))
        }
        var files = named(stem)
        var counter = 2
        while unique, files.all.contains(where: { FileManager.default.fileExists(atPath: $0.path) }), counter < 1000 {
            files = named("\(stem) \(counter)")
            counter += 1
        }
        return files
    }

    /// The Short's burned-in captions as an ASS file, laid out with its graphics, or nil.
    static func burnedCaptions(_ item: VideoItem, short: Short, settings: ExportSettings) -> URL? {
        guard settings.shortCaptionUse(hasFile: item.subtitles != nil).burns else { return nil }
        let captions = item.shortCaptions(short, settings: settings)
        guard !captions.isEmpty else { return nil }
        let placed = ShortCaptionLayout.layout(captions, graphics: item.graphics?.forShort(short), option: short.captions, size: settings.subtitleSize,
                                               bottom: item.shortCaptionBottom(short))
        return ShortCaptionLayout.assFile(placed, size: settings.subtitleSize)
    }

    /// Exports the Short alone to `output`: 1080×1920 MP4 (or the export format given),
    /// its graphics laid out for 9:16 and its captions burned in when they are.
    static func export(_ item: VideoItem, info: MediaInfo, short: Short, settings: ExportSettings, output: URL,
                       drawGraphics: ((GraphicsRender.Job, URL, URL) async throws -> Void)? = nil,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let cut = item.shortItem(short)
        // With the screen on top, the layout stage reads the recording's whole picture and
        // draws the 1080×1920 canvas itself, from the Short's window and the screen.
        let stack = item.stacksScreen(short) ? short.frame(info: info, crop: item.crop) : nil
        let crop = stack == nil ? (cut.crop ?? info.fullFrame) : (item.crop ?? info.fullFrame)
        try await FFmpeg.export(input: item.url, output: output, info: info,
                                crop: crop.evenClamped(in: info.fullFrame),
                                regions: cut.blurRegions.map(\.rect), zoomShots: cut.zoomShots, segments: cut.segments,
                                settings: settings, subtitles: nil, color: item.colorStage(settings),
                                effects: cut.blurEffects, graphics: cut.exportGraphics(settings),
                                canvas: ShortFormat.size, captionsASS: burnedCaptions(item, short: short, settings: settings),
                                screen: cut.screen, stack: stack, drawGraphics: drawGraphics, onProgress: onProgress)
    }

    /// The upload text's SHORT section.
    static func shortLines(_ short: Short, recording: VideoItem, cover: String?) -> [String] {
        var lines = ["SHORT",
                     "A vertical 1080×1920 Short of \(PublishInfo.timestamp(short.length)) (\(String(format: "%.1f", short.length)) s), from "
                        + "\(PublishInfo.timestamp(short.start)) to \(PublishInfo.timestamp(short.end)) of \(recording.name). "
                        + "YouTube treats a vertical video of up to 3 minutes as a Short; no hashtag is needed."]
        if let cover {
            lines.append("COVER: \(cover) is the frame at \(PublishInfo.timestamp(short.cover ?? 0)) with its graphics. Upload it in YouTube Studio where custom Shorts thumbnails are offered, or pick the nearest suggested frame.")
        }
        let long = recording.publish?.title.trimmingCharacters(in: .whitespaces) ?? ""
        lines.append("RELATED VIDEO: " + ShortFormat.relatedVideoNote + (long.isEmpty ? "" : " The long video: \(long)."))
        return lines
    }

    static func json(_ short: Short, publish: PublishInfo, recording: VideoItem, files: YouTubeExport.Files, coverWritten: Bool,
                     project: UUID? = nil) throws -> Data {
        var fileNames: [String: JSONValue] = ["video": .string(files.video.lastPathComponent), "text": .string(files.text.lastPathComponent)]
        if let captions = files.captions, FileManager.default.fileExists(atPath: captions.path) { fileNames["captions"] = .string(captions.lastPathComponent) }
        if coverWritten, let cover = files.thumbnail { fileNames["cover"] = .string(cover.lastPathComponent) }
        var root: [String: JSONValue] = [
            "short": .bool(true), "shortID": .string(short.id.uuidString),
            "title": .string(publish.title), "description": .string(publish.fullDescription),
            "tags": .array(publish.tags.map(JSONValue.string)),
            "category": .object(["name": .string(publish.category.label), "id": .number(Double(publish.category.youtubeID))]),
            "language": .string(publish.language), "files": .object(fileNames),
            "size": .object(["width": .number(1080), "height": .number(1920)]),
            "length": .number(short.length), "from": .number(short.start), "to": .number(short.end),
            "relatedVideo": .object(["setIn": .string(ShortFormat.relatedVideoStep), "uploadAPICanSet": .bool(false),
                                     "note": .string(ShortFormat.relatedVideoNote),
                                     "longVideoTitle": .string(recording.publish?.title ?? "")]),
        ]
        if let cover = short.cover { root["cover"] = .object(["time": .number(cover), "timestamp": .string(PublishInfo.timestamp(cover))]) }
        // What it was made from, so the Library can find it.
        if let project { root["projectID"] = .string(project.uuidString) }
        root["recordingID"] = .string(recording.id.uuidString)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(root))
    }

    /// Makes `image` a 1080×1920 JPEG under 2 MB.
    static func writeCover(_ image: CGImage, to target: URL) throws {
        let size = (width: 1080, height: 1920)
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FFmpegError(message: "The cover could not be made.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let resized = context.makeImage() else { throw FFmpegError(message: "The cover could not be made.") }
        for quality in [0.9, 0.8, 0.7, 0.55, 0.4] {
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(output, resized, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { break }
            if data.length < PublishInfo.thumbnailBytes { try (data as Data).write(to: target, options: .atomic); return }
        }
        throw FFmpegError(message: "The cover could not be made smaller than 2 MB.")
    }

    /// Writes the Short's MP4, its captions, its cover, and the upload text and JSON into
    /// `files`' folder. The video is written under a temporary name and moved into place
    /// when done. `cover` draws the cover frame (seconds into the Short).
    static func run(_ item: VideoItem, info: MediaInfo, short: Short, settings: ExportSettings, files: YouTubeExport.Files,
                    cover: (Double) async throws -> CGImage,
                    drawGraphics: ((GraphicsRender.Job, URL, URL) async throws -> Void)? = nil,
                    project: UUID? = nil,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if let blocking = item.shortIssues(short).first(where: { $0.severity == .blocking }) {
            throw FFmpegError(message: blocking.message)
        }
        var videoSettings = settings
        videoSettings.format = .mp4
        let folder = files.video.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".yamvideo-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await export(item, info: info, short: short, settings: videoSettings, output: temporary, drawGraphics: drawGraphics, onProgress: onProgress)
        try Task.checkCancellation()
        let manager = FileManager.default
        if manager.fileExists(atPath: files.video.path) { _ = try manager.replaceItemAt(files.video, withItemAt: temporary) }
        else { try manager.moveItem(at: temporary, to: files.video) }
        let captions = item.shortCaptions(short, settings: settings)
        if let target = files.captions, !captions.isEmpty {
            try Data(Captions.srt(captions).utf8).write(to: target, options: .atomic)
        }
        var coverWritten = false
        if let target = files.thumbnail {
            try writeCover(try await cover(short.cover ?? min(1, short.length / 2)), to: target)
            coverWritten = true
        }
        let publish = short.publishInfo(recording: item.publish)
        let names = files.all.filter { $0 != files.text && ($0 == files.json || manager.fileExists(atPath: $0.path)) }.map(\.lastPathComponent)
        var text = publish.uploadText(files: [])
        text += "\n" + shortLines(short, recording: item, cover: coverWritten ? files.thumbnail?.lastPathComponent : nil).joined(separator: "\n") + "\n"
        text += "\nFILES\n" + names.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: files.text, options: .atomic)
        try json(short, publish: publish, recording: item, files: files, coverWritten: coverWritten, project: project).write(to: files.json, options: .atomic)
    }
}

extension AppModel {
    /// The picture of a Short at `local` seconds into it, as its viewer shows it: the 9:16
    /// window at 1080×1920 with its graphics and, when burned in, its captions.
    func composedShortFrame(_ clip: ProjectClip, short: Short, at local: Double, settings: ExportSettings,
                            original: Bool = false, captions: Bool = true) async throws -> (image: CGImage, graphics: [PreviewGraphic]) {
        guard let info = clip.info else { throw EditError(code: .missingMedia, message: "That recording is still loading.") }
        let item = clip.item()
        let time = min(short.start + max(0, local), max(short.start, short.end - 1 / max(1, info.fps)))
        let player = try await PlaybackController.makeItem(item, settings: settings, original: original, short: short)
        let generator = AVAssetImageGenerator(asset: player.asset)
        generator.videoComposition = player.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600_000)).image
        // Up (or down) to the Short's own size, as the export delivers it.
        let size = ShortFormat.size
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FFmpegError(message: "The Short's frame could not be drawn.")
        }
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(origin: .zero, size: size))
        guard let picture = context.makeImage() else { throw FFmpegError(message: "The Short's frame could not be drawn.") }
        let track = item.shortGraphics(short, recordingTime: true) ?? GraphicsTrack(canvas: .short(short.panels, zoom: short.zoomLevel))
        let overlay = captions ? item.shortCaptionOverlay(short, settings: settings) : nil
        guard !track.items.isEmpty || overlay != nil else { return (picture, []) }
        let snapshot = try await GraphicsSnapshot.draw(track, duration: clip.timeline.duration, fps: info.fpsExpression, time: time,
                                                       over: picture, captions: overlay)
        let drawn = track.items.compactMap { graphic in
            snapshot.boxes[graphic.id].map { PreviewGraphic(id: graphic.id, kind: graphic.kind.rawValue, rect: WireRect($0)) }
        }
        return (snapshot.image, drawn)
    }

    /// Asks for a folder, then writes the selected Short's video, captions, cover and upload text there.
    func promptForShortExport(_ id: UUID? = nil) {
        guard let item = selectedItem, item.info != nil, let short = item.short(id ?? selectedShortID) else { return }
        if let blocking = item.shortIssues(short).first(where: { $0.severity == .blocking }) {
            statusMessage = blocking.message
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose the folder for the Short, its captions, cover and upload text."
        panel.directoryURL = settings.outputFolder ?? item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        exportShortForYouTube(short.id, to: folder)
    }

    func exportShortForYouTube(_ id: UUID, to folder: URL) {
        guard !isConverting, let index = selectedIndex, let info = items[index].info, let short = items[index].short(id),
              let position = items[index].shorts.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        let files = ShortExport.files(in: folder, short: short, index: position, recording: item, settings: settings, unique: true)
        let exportSettings = settings
        let project = projectID
        let clipID = item.id
        let clip = ProjectClip(item)
        playback.pause()
        isConverting = true
        statusMessage = nil
        items[index].status = .converting(0)
        conversionTask = Task {
            do {
                try await ShortExport.run(item, info: info, short: short, settings: exportSettings, files: files,
                                          cover: { [weak self] time in
                                              guard let self else { throw CancellationError() }
                                              return try await self.composedShortFrame(clip, short: short, at: time, settings: exportSettings).image
                                          }, project: project) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, let i = self.items.firstIndex(where: { $0.id == clipID }) else { return }
                        if case .converting = self.items[i].status { self.items[i].status = .converting(fraction) }
                    }
                }
                if let i = items.firstIndex(where: { $0.id == clipID }) { items[i].status = .done(files.video) }
                finishedExport(files.json, title: files.video.deletingPathExtension().lastPathComponent, origin: .human)
                statusMessage = "Exported the Short for YouTube: \(files.video.lastPathComponent) and its upload files."
            } catch is CancellationError {
                if let i = items.firstIndex(where: { $0.id == clipID }) { items[i].status = .ready }
                statusMessage = "Export cancelled."
            } catch {
                if let i = items.firstIndex(where: { $0.id == clipID }) { items[i].status = .failed(error.localizedDescription) }
                statusMessage = error.localizedDescription
            }
            isConverting = false
        }
    }
}

// MARK: - YouTube's furniture

/// YouTube's Shorts player drawn over a 1080×1920 frame, as the viewer's overlay
/// (`ShortFurniture`) shows it: the shading at the top and the bottom, the icons, the like
/// and share rail, the channel and title, and the clear area dashed. For agents, so a
/// preview shows what a viewer's phone covers.
enum ShortFurnitureDrawing {
    static func draw(over image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Top-left coordinates in design pixels of the 1080×1920 canvas.
        let k = Double(width) / Double(ShortFormat.size.width)
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: k, y: -k)
        let w = Double(ShortFormat.size.width), h = Double(ShortFormat.size.height)
        let f = ShortFormat.furniture, clear = ShortFormat.clearArea
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func shade(_ rect: CGRect, from: Double, to: Double) {
            let colours = [CGColor(gray: 0, alpha: from), CGColor(gray: 0, alpha: to)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1]) else { return }
            context.saveGState(); context.clip(to: rect)
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            context.restoreGState()
        }
        shade(CGRect(x: 0, y: 0, width: w, height: f.top), from: 0.3, to: 0)
        shade(CGRect(x: 0, y: h - f.bottom - 120, width: w, height: f.bottom + 120), from: 0, to: 0.4)
        let ink = CGColor(gray: 1, alpha: 0.75)
        context.setFillColor(ink); context.setStrokeColor(ink)
        // The icons at the top right: search and more.
        for x in [w - 60 - 58 - 48 - 58, w - 60 - 58] { context.fillEllipse(in: CGRect(x: x, y: 90, width: 58, height: 58)) }
        // The rail down the lower right: like, dislike, comment, share, remix, and the sound's square.
        let railX = w - f.right / 2
        var y = h - 80 - 76
        context.setLineWidth(5)
        context.stroke(CGRect(x: railX - 38, y: y, width: 76, height: 76))
        for _ in 0..<5 {
            y -= 36 + 94
            context.fillEllipse(in: CGRect(x: railX - 29, y: y, width: 58, height: 58))
            context.fill(CGRect(x: railX - 34, y: y + 66, width: 68, height: 20))
        }
        // The channel, title and sound along the bottom left.
        let left = f.left, base = h - 96
        context.fill(CGRect(x: left, y: base - 38, width: 380, height: 30))
        context.fill(CGRect(x: left, y: base - 38 - 22 - 40, width: 560, height: 34))
        context.fillEllipse(in: CGRect(x: left, y: base - 38 - 22 - 40 - 22 - 72, width: 72, height: 72))
        context.fill(CGRect(x: left + 90, y: base - 38 - 22 - 40 - 22 - 54, width: 260, height: 36))
        // The clear area, dashed.
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.6)); context.setLineWidth(3); context.setLineDash(phase: 0, lengths: [12, 10])
        context.stroke(clear)
        return context.makeImage()
    }
}

/// YouTube's Shorts player as a viewer sees it over the Short, faintly: the icons along the
/// top, the like, comment and share rail down the lower right, and the channel, title and
/// sound along the bottom, each over YouTube's own shading. The clear area is dashed.
struct ShortFurniture: View {
    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / ShortFormat.size.width
            let f = ShortFormat.furniture
            let clear = ShortFormat.clearArea
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(width: geo.size.width, height: f.top * k)
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                    .frame(width: geo.size.width, height: (f.bottom + 120) * k)
                    .offset(y: geo.size.height - (f.bottom + 120) * k)
                Rectangle()
                    .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: clear.width * k, height: clear.height * k)
                    .offset(x: clear.minX * k, y: clear.minY * k)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 48 * k) {
                    symbol("magnifyingglass", k: k)
                    symbol("ellipsis", k: k).rotationEffect(.degrees(90))
                }
                .padding(.top, 90 * k).padding(.trailing, 60 * k)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 36 * k) {
                    ForEach([("hand.thumbsup.fill", "Like"), ("hand.thumbsdown.fill", "Dislike"), ("text.bubble.fill", "Comment"),
                             ("arrowshape.turn.up.right.fill", "Share"), ("arrow.triangle.2.circlepath", "Remix")], id: \.0) { icon, label in
                        VStack(spacing: 8 * k) {
                            symbol(icon, k: k)
                            Text(label).font(.system(size: max(6, 28 * k), weight: .medium))
                        }
                    }
                    RoundedRectangle(cornerRadius: 14 * k).stroke(Color.white.opacity(0.8), lineWidth: max(1, 5 * k))
                        .frame(width: 76 * k, height: 76 * k)
                }
                .frame(width: f.right * k, height: (ShortFormat.size.height - ShortFormat.railTop - 80) * k, alignment: .bottom)
                .padding(.bottom, 80 * k)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 22 * k) {
                    HStack(spacing: 18 * k) {
                        Circle().fill(Color.white.opacity(0.35)).frame(width: 72 * k, height: 72 * k)
                        Text("@yourchannel").font(.system(size: max(7, 36 * k), weight: .semibold))
                        Text("Subscribe").font(.system(size: max(6, 30 * k), weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 22 * k).padding(.vertical, 10 * k).background(Color.white.opacity(0.85), in: Capsule())
                    }
                    Text("Your Short's title").font(.system(size: max(7, 38 * k)))
                    Label("Original sound", systemImage: "music.note").font(.system(size: max(6, 30 * k)))
                }
                .lineLimit(1)
                .frame(width: clear.width * k, alignment: .leading)
                .padding(.leading, f.left * k).padding(.bottom, 96 * k)
            }
            .foregroundStyle(.white.opacity(0.75))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String, k: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: max(9, 58 * k)))
    }
}
