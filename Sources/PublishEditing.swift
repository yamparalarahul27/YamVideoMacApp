import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Export for YouTube and the Publish sheet's actions. See Publish.swift for the data and
// YouTube's rules.

// MARK: - Export for YouTube

enum YouTubeExport {
    /// What one Export for YouTube writes into its folder.
    struct Files: Equatable {
        var video: URL
        var captions: URL?
        var thumbnail: URL?
        var text: URL
        var json: URL
        /// The Test & Compare versions' thumbnails, A first, when they are saved.
        var tests: [URL] = []

        var all: [URL] { [video, captions, thumbnail, text, json].compactMap { $0 } + tests }
    }

    /// The names for a recording in `folder`, from its title. With `unique`, a number is
    /// added until none of them exists yet.
    static func files(in folder: URL, publish: PublishInfo, fallback: String, captions: Bool, unique: Bool) -> Files {
        let stem = PublishInfo.fileStem(publish.title, fallback: fallback)
        func named(_ stem: String) -> Files {
            Files(video: folder.appendingPathComponent(stem + ".mp4"),
                  captions: captions ? folder.appendingPathComponent("\(stem).\(publish.language).srt") : nil,
                  thumbnail: publish.thumbnail == nil ? nil : folder.appendingPathComponent(stem + " thumbnail.jpg"),
                  text: folder.appendingPathComponent(stem + " YouTube.txt"),
                  json: folder.appendingPathComponent(stem + ".youtube.json"),
                  tests: (publish.test?.images ?? []).indices.map { folder.appendingPathComponent("\(stem) thumbnail \(ThumbnailTest.letters[$0]).jpg") })
        }
        var files = named(stem)
        var counter = 2
        while unique, files.all.contains(where: { FileManager.default.fileExists(atPath: $0.path) }), counter < 1000 {
            files = named("\(stem) \(counter)")
            counter += 1
        }
        return files
    }

    /// Makes `source` a 1280×720 JPEG under 2 MB: the middle of the image at 16:9, scaled,
    /// with the quality lowered only as far as the size needs.
    static func writeThumbnail(_ source: URL, to target: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
            throw FFmpegError(message: "The thumbnail \(source.lastPathComponent) is not an image this Mac can read.")
        }
        let size = PublishInfo.thumbnailSize
        let width = Double(image.width), height = Double(image.height)
        let crop: CGRect = width / height > 16.0 / 9.0
            ? CGRect(x: (width - height * 16 / 9) / 2, y: 0, width: height * 16 / 9, height: height)
            : CGRect(x: 0, y: (height - width * 9 / 16) / 2, width: width, height: width * 9 / 16)
        guard let piece = image.cropping(to: crop.integral),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FFmpegError(message: "The thumbnail could not be resized.")
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.draw(piece, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let resized = context.makeImage() else { throw FFmpegError(message: "The thumbnail could not be resized.") }
        for quality in [0.92, 0.85, 0.75, 0.65, 0.5, 0.35] {
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(output, resized, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { break }
            if data.length < PublishInfo.thumbnailBytes {
                try (data as Data).write(to: target, options: .atomic)
                return
            }
        }
        throw FFmpegError(message: "The thumbnail could not be made smaller than 2 MB.")
    }

    /// The structured version of the text file, for an agent filling in YouTube Studio.
    /// `project` and `recording` say what it was made from, so the Library can find it.
    static func json(_ publish: PublishInfo, files: Files, endScreen plan: EndScreenPlan? = nil,
                     project: UUID? = nil, recording: UUID? = nil) throws -> Data {
        let chapters: [JSONValue] = publish.chapters.sorted { $0.time < $1.time }.map {
            .object(["time": .number($0.time), "timestamp": .string(PublishInfo.timestamp($0.time)), "title": .string($0.title)])
        }
        var fileNames: [String: JSONValue] = ["video": .string(files.video.lastPathComponent),
                                              "text": .string(files.text.lastPathComponent)]
        if let captions = files.captions { fileNames["captions"] = .string(captions.lastPathComponent) }
        if let thumbnail = files.thumbnail { fileNames["thumbnail"] = .string(thumbnail.lastPathComponent) }
        var test: JSONValue?
        if let tested = publish.test, !files.tests.isEmpty {
            var object: [String: JSONValue] = ["versions": .array(files.tests.enumerated().map {
                .object(["version": .string(ThumbnailTest.letters[$0.offset]), "file": .string($0.element.lastPathComponent)])
            })]
            if let winner = tested.winner { object["winner"] = .string(ThumbnailTest.letters[winner]) }
            test = .object(object)
        }
        var root: [String: JSONValue] = [
            "title": .string(publish.title), "description": .string(publish.fullDescription),
            "tags": .array(publish.tags.map(JSONValue.string)),
            "category": .object(["name": .string(publish.category.label), "id": .number(Double(publish.category.youtubeID))]),
            "language": .string(publish.language), "chapters": .array(chapters), "files": .object(fileNames),
        ]
        if let plan { root["endScreen"] = plan.json }
        if let test { root["thumbnailTest"] = test }
        if let project { root["projectID"] = .string(project.uuidString) }
        if let recording { root["recordingID"] = .string(recording.uuidString) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(root))
    }

    /// Writes the video (MP4, whatever the export format is set to), the captions on the
    /// edited timeline, the thumbnail, and the text and JSON files into `files`' folder.
    /// The video is written under a temporary name and moved into place only when done,
    /// so a cancelled export leaves no half-written video.
    static func run(_ item: VideoItem, info: MediaInfo, publish: PublishInfo, settings: ExportSettings, files: Files,
                    project: UUID? = nil, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let item = item.effective
        if let blocking = publish.issues(duration: item.editedDuration, graphics: item.graphics).first(where: { $0.severity == .blocking }) {
            throw FFmpegError(message: blocking.message)
        }
        var videoSettings = settings
        videoSettings.format = .mp4
        let folder = files.video.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".yamvideo-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await FFmpeg.export(input: item.url, output: temporary, info: info,
                                crop: (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame),
                                regions: item.blurRegions.map(\.rect), zoomShots: item.zoomShots, segments: item.segments,
                                settings: videoSettings, subtitles: item.burnedCaptions(videoSettings), color: item.colorStage(videoSettings),
                                effects: item.blurEffects, graphics: item.exportGraphics(videoSettings), screen: item.screen, onProgress: onProgress)
        try Task.checkCancellation()
        let manager = FileManager.default
        if manager.fileExists(atPath: files.video.path) { _ = try manager.replaceItemAt(files.video, withItemAt: temporary) }
        else { try manager.moveItem(at: temporary, to: files.video) }
        if let captions = files.captions, let srt = item.uploadCaptionsSRT(settings) {
            try Data(srt.utf8).write(to: captions, options: .atomic)
        }
        if let thumbnail = files.thumbnail, let source = publish.thumbnail {
            try writeThumbnail(source, to: thumbnail)
        }
        for (target, source) in zip(files.tests, publish.test?.images ?? []) { try writeThumbnail(source, to: target) }
        let names = files.all.filter { $0 != files.text && ($0 == files.json || manager.fileExists(atPath: $0.path)) }.map(\.lastPathComponent)
        let plan = EndScreenPlan(graphics: item.graphics, publish: publish, duration: item.editedDuration)
        try Data(publish.uploadText(files: names, endScreen: plan, tests: files.tests.map(\.lastPathComponent)).utf8)
            .write(to: files.text, options: .atomic)
        try json(publish, files: files, endScreen: plan, project: project, recording: item.id).write(to: files.json, options: .atomic)
    }
}

// MARK: - Actions

extension AppModel {
    var selectedPublish: PublishInfo { selectedItem?.publish ?? PublishInfo() }

    /// Marks the version that won YouTube's Test & Compare: its picture becomes the
    /// thumbnail, as one undo step. The project's idea in the Library gets a line in its
    /// notes (a Library step), so later videos can learn from it. Nil clears the mark.
    func markThumbnailWinner(_ index: Int?) {
        guard let test = selectedPublish.test else { return }
        setPublish(label: "Thumbnail Winner") { $0.markWinner(index) }
        guard let index, selectedPublish.test?.winner == index, let idea = openProjectIdea else { return }
        let words = selectedPublish.versions[index].title.replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        let line = "Thumbnail test, \(formatter.string(from: Date())): \(ThumbnailTest.letters[index]) won of \(test.count) (“\(words)”)."
        editIdea(idea.id, notes: idea.notes.isEmpty ? line : idea.notes + "\n" + line)
    }

    /// A loaded recording is selected, in Recording mode, and nothing is exporting.
    var canMakeThumbnail: Bool { selectedItem?.info != nil && !isMovieMode && !isConverting }

    /// Opens the thumbnail maker for the selected recording without the Publish window
    /// (Thumbnail under Studio in the left bar, or Make Thumbnail…, ⇧⌘T), on the Studio
    /// page. False when it cannot open.
    @discardableResult
    func openThumbnailMaker() -> Bool {
        guard canMakeThumbnail else {
            statusMessage = isMovieMode ? "Make Thumbnail works in Recording mode." : "Select a recording to make its thumbnail."
            return false
        }
        showModule(.studio)
        showingThumbnailMaker = true
        return true
    }

    /// Changes what YouTube gets for the selected recording, as one undo step.
    func setPublish(label: String = "Publish Details", _ change: (inout PublishInfo) -> Void) {
        guard let index = selectedIndex, items[index].info != nil else { return }
        var info = items[index].publish ?? PublishInfo()
        let before = info
        change(&info)
        guard info != before else { return }
        if case .failure(let error) = perform([.setPublishInfo(clip: items[index].id, info: info)], label: label) {
            statusMessage = error.message
        }
    }

    var suggestedChapters: [Chapter] {
        guard let item = selectedItem else { return [] }
        return PublishInfo.suggestedChapters(markers: item.markers, graphics: item.graphics, duration: item.editedDuration)
    }

    func useSuggestedChapters() {
        let chapters = suggestedChapters
        guard !chapters.isEmpty else {
            statusMessage = "Name some markers, or add panel or title graphics, to suggest chapters from."
            return
        }
        setPublish(label: "Suggest Chapters") { $0.chapters = chapters }
    }

    func chooseThumbnail() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp]
        panel.message = "Choose a thumbnail image. It is made 1280×720 for YouTube when you export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setPublish(label: "Choose Thumbnail") { $0.thumbnail = url }
    }

    /// Saves the picture at the playhead, graphics and all, as the thumbnail: a PNG in the
    /// video's Files/ folder, or next to the recording outside the footage layout.
    func useFrameAsThumbnail() {
        guard let index = selectedIndex, items[index].info != nil else { return }
        let clip = ProjectClip(items[index])
        let time = previewTime
        Task {
            do {
                let frame = try await composedFrame(clip, at: time, settings: settings, guides: false).image
                let folder = FootageLayout.filesFolder(for: clip.url)
                let stem = clip.url.deletingPathExtension().lastPathComponent + " thumbnail"
                var target = folder.appendingPathComponent(stem + ".png")
                var counter = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(stem) \(counter).png"); counter += 1
                }
                guard let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
                    throw FFmpegError(message: "The frame could not be saved.")
                }
                try png.write(to: target, options: .atomic)
                setPublish(label: "Use Frame as Thumbnail") { $0.thumbnail = target }
                statusMessage = "Saved the frame at \(PublishInfo.timestamp(time)) as \(target.lastPathComponent)."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Asks for a folder, then writes the video, captions, thumbnail and upload text there.
    func promptForYouTubeExport() {
        guard let item = selectedItem, item.info != nil else { return }
        if let blocking = (item.publish ?? PublishInfo()).issues(duration: item.editedDuration, graphics: item.graphics)
            .first(where: { $0.severity == .blocking }) {
            statusMessage = blocking.message
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose the folder for the video, its captions, thumbnail and upload text."
        panel.directoryURL = settings.outputFolder ?? FootageLayout.editedFolder(for: item.url)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        exportForYouTube(to: folder)
    }

    func exportForYouTube(to folder: URL) {
        guard !isConverting, let index = selectedIndex, let info = items[index].info else { return }
        let item = items[index]
        let publish = item.publish ?? PublishInfo()
        let files = YouTubeExport.files(in: folder, publish: publish, fallback: item.url.deletingPathExtension().lastPathComponent,
                                        captions: item.uploadsCaptions(settings),
                                        unique: true)
        let exportSettings = settings
        let project = projectID
        let id = item.id
        playback.pause()
        isConverting = true
        statusMessage = nil
        items[index].status = .converting(0)
        conversionTask = Task {
            do {
                try await YouTubeExport.run(item, info: info, publish: publish, settings: exportSettings, files: files, project: project) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                        if case .converting = self.items[i].status { self.items[i].status = .converting(fraction) }
                    }
                }
                if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = .done(files.video) }
                finishedExport(files.json, title: files.video.deletingPathExtension().lastPathComponent, origin: .human)
                statusMessage = "Exported for YouTube: \(files.video.lastPathComponent) and its upload files."
            } catch is CancellationError {
                if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = .ready }
                statusMessage = "Export cancelled."
            } catch {
                if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = .failed(error.localizedDescription) }
                statusMessage = error.localizedDescription
            }
            isConverting = false
        }
    }
}
