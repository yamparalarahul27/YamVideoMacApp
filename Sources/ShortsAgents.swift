import AppKit
import Foundation

// Shorts for local agents: the addShort, updateShort and removeShort commands, Shorts in
// state, a Short's composed preview, and exporting a Short (for YouTube or alone).

extension AppModel {
    static let shortKeys = ["id", "start", "end", "window", "title", "description", "tags", "hidden", "placements", "cover", "panels", "captions", "zoom", "screen"]

    /// A Short from an agent's keys over `old` (or a new one on `clip`): only the keys
    /// given change. `speaker` is the window Vision found, for `window: "speaker"`.
    static func mergedShort(_ patch: [String: JSONValue], onto old: Short?, clip: ProjectClip, speaker: CGRect?) throws -> Short {
        if let unknown = patch.keys.sorted().first(where: { !shortKeys.contains($0) }) {
            throw EditError.invalid("Unknown Short key \"\(unknown)\". Keys: \(shortKeys.joined(separator: ", ")).")
        }
        guard clip.info != nil else { throw EditError(code: .missingMedia, message: "That recording is still loading.") }
        func number(_ key: String) throws -> Double? {
            guard let value = patch[key], value != .null else { return nil }
            guard let number = value.number, number.isFinite else { throw EditError.invalid("\(key) is a number of seconds.") }
            return number
        }
        func text(_ key: String) throws -> String? {
            guard let value = patch[key] else { return nil }
            guard let text = value.string else { throw EditError.invalid("\(key) is text.") }
            return text
        }
        func graphic(_ text: String, _ key: String) throws -> UUID {
            guard let id = UUID(uuidString: text) else { throw EditError.invalid("\(key) names graphics by their id from state.clips[].graphics.items[].id.") }
            guard clip.graphics?.items.contains(where: { $0.id == id }) == true else {
                throw EditError.notFound("No graphic \(id) on recording \(clip.id); \(key) names graphics from state.clips[].graphics.items[].id.")
            }
            return id
        }

        var short: Short
        if let old {
            short = old
            let start = try number("start"), end = try number("end")
            // Moving the start alone keeps the length, as a graphic's does.
            if let start, end == nil { short.end = start + old.length }
            if let start { short.start = start }
            if let end { short.end = end }
        } else {
            let id: UUID
            if let text = patch["id"]?.string {
                guard let parsed = UUID(uuidString: text) else { throw EditError.invalid("id is a UUID you choose for the new Short.") }
                id = parsed
            } else { id = UUID() }
            let item = clip.item()
            let duration = clip.timeline.duration
            let start = try number("start"), end = try number("end")
            let span: (start: Double, end: Double)
            switch (start, end) {
            case let (start?, end?): span = (start, end)
            case let (start?, nil):
                let next = item.shorts.filter { $0.start >= start - 0.000001 }.map(\.start).min() ?? duration
                span = (start, min(start + ShortFormat.defaultLength, next, duration))
            case let (nil, end?): span = (max(0, end - ShortFormat.defaultLength), end)
            case (nil, nil):
                guard let found = item.newShortSpan(at: 0) else {
                    throw EditError.invalid("There is no room for another Short: give start and end on footage no other Short covers.")
                }
                span = found
            }
            short = Short(id: id, start: span.start, end: span.end)
        }
        if let value = patch["window"] {
            switch value {
            case .null, .string("centre"), .string("center"): short.window = nil
            case .string("speaker"):
                guard let speaker else {
                    throw EditError.invalid("No face or person was found in the middle of the Short. Give window as {x, y, width, height} (9:16, source pixels), or \"centre\".")
                }
                short.window = speaker
            case .object(let rect):
                guard let x = rect["x"]?.number, let y = rect["y"]?.number, let width = rect["width"]?.number, let height = rect["height"]?.number else {
                    throw EditError.invalid("window is {x, y, width, height} in source pixels (9:16), \"speaker\" or \"centre\".")
                }
                short.window = CGRect(x: x, y: y, width: width, height: height)
            default:
                throw EditError.invalid("window is {x, y, width, height} in source pixels (9:16), \"speaker\" or \"centre\".")
            }
        }
        if let title = try text("title") { short.title = title }
        if let description = try text("description") { short.description = description }
        if let value = patch["tags"] {
            guard let list = value.array, list.allSatisfy({ $0.string != nil }) else { throw EditError.invalid("tags is a list of text.") }
            short.tags = list.compactMap(\.string)
        }
        if let value = patch["hidden"] {
            guard let list = value.array, list.allSatisfy({ $0.string != nil }) else { throw EditError.invalid("hidden is a list of graphic ids.") }
            short.hidden = try list.compactMap(\.string).map { try graphic($0, "hidden") }
        }
        if let value = patch["placements"] {
            guard let places = value.object else { throw EditError.invalid("placements is {graphicID: {x, y, scale}}; null puts one back.") }
            for (key, place) in places {
                let id = try graphic(key, "placements")
                if place == .null { short.placements.removeValue(forKey: id); continue }
                guard let fields = place.object else { throw EditError.invalid("A placement is {x, y, scale}, or null.") }
                var transform = short.placements[id] ?? GraphicTransform()
                if let x = fields["x"]?.number { transform.x = x }
                if let y = fields["y"]?.number { transform.y = y }
                if let scale = fields["scale"]?.number { transform.scale = scale }
                if transform.isIdentity { short.placements.removeValue(forKey: id) } else { short.placements[id] = transform }
            }
        }
        if let value = patch["cover"] {
            if value == .null { short.cover = nil }
            else { short.cover = try number("cover") }
        }
        if let value = patch["panels"] {
            guard let name = value.string, let panels = ShortPanels(rawValue: name) else {
                throw EditError.invalid("panels is one of: \(ShortPanels.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            short.panels = panels
        }
        if let value = patch["captions"] {
            guard let name = value.string, let captions = ShortCaptions(rawValue: name) else {
                throw EditError.invalid("captions is one of: \(ShortCaptions.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            short.captions = captions
        }
        if let value = patch["zoom"] {
            if value == .null { short.zoom = nil }
            else {
                guard let zoom = value.number, zoom.isFinite else {
                    throw EditError.invalid("zoom is a number from \(ShortFormat.zooms.lowerBound.formatted()) (a square at the top) to 1 (fills the frame), or null.")
                }
                short.zoom = zoom == 1 ? nil : zoom
            }
        }
        if let value = patch["screen"] {
            guard let name = value.string, let screen = ShortScreen(rawValue: name) else {
                throw EditError.invalid("screen is one of: \(ShortScreen.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            if screen == .top, clip.screen == nil {
                throw EditError.invalid("Recording \(clip.id) has no screen recording, so its Shorts cannot show one. Add one with setScreen first.")
            }
            short.screen = screen
        }
        return short
    }

    /// The window around the speaker for a command's Short (`window: "speaker"`), or nil
    /// when Vision finds no one.
    func speakerWindow(for command: WireCommand, in document: VideoProject) async throws -> CGRect? {
        guard let clipID = command.clipID, let clip = document.clips.first(where: { $0.id == clipID }), clip.info != nil else { return nil }
        var patch = command.short ?? [:]
        patch["window"] = nil
        let old = command.type == "updateShort" ? clip.shorts?.first { $0.id == command.shortID } : nil
        guard command.type == "addShort" || old != nil else { return nil }
        let short = try Self.mergedShort(patch, onto: old, clip: clip, speaker: nil)
        return try await speakerWindow(clip, short: short)
    }

    /// The Shorts of a recording as state shows them.
    static func shortStates(_ clip: ProjectClip, settings: ExportSettings) -> [AgentState.ShortState] {
        guard let info = clip.info else { return [] }
        let item = clip.item()
        return item.shorts.map { short in
            let track = item.graphics?.forShort(short)
            let burned = settings.shortCaptionUse(hasFile: item.subtitles != nil).burns
            let captions = item.shortCaptions(short, settings: settings)
            return AgentState.ShortState(
                id: short.id, start: short.start, end: short.end, length: short.length,
                window: WireRect(short.frame(info: info, crop: clip.crop)), windowSet: short.window != nil,
                title: short.title, description: short.description, tags: short.tags,
                panels: short.panels.rawValue, captions: short.captions.rawValue, zoom: short.zoomLevel, screen: short.screen.rawValue,
                picture: WireRect(short.picture(info: info, crop: clip.crop)), cover: short.cover,
                hidden: short.hidden, placements: Dictionary(uniqueKeysWithValues: short.placements.map { ($0.key.uuidString, $0.value) }),
                graphics: (track?.items ?? []).map { .init(id: $0.id, kind: $0.kind.rawValue, start: $0.start, end: $0.end, placed: $0.transform != nil) },
                captionsBurned: burned && !captions.isEmpty,
                captionCount: burned ? ShortCaptionLayout.layout(captions, graphics: track, option: short.captions, size: settings.subtitleSize,
                                                                 bottom: item.shortCaptionBottom(short)).count : captions.count,
                issues: item.shortIssues(short))
        }
    }

    /// A Short's frame as its viewer shows it, 1080×1920, at `time` seconds into the Short.
    func agentShortPreview(_ request: AgentRequest, short id: UUID, document: VideoProject, revision requested: Int) async -> Result<AgentPreview, EditError> {
        do {
            guard let clipID = request.clip, let clip = document.clips.first(where: { $0.id == clipID }) else {
                throw EditError.invalid("A Short's preview needs clip, the recording's id.")
            }
            guard clip.info != nil else { throw EditError(code: .missingMedia, message: "That recording is still loading.") }
            guard let short = clip.shorts?.first(where: { $0.id == id }) else {
                throw EditError.notFound("No Short \(id) on recording \(clipID). state.clips[].shorts lists them.")
            }
            let time = request.time ?? 0
            guard time.isFinite, time >= 0, time <= short.length + 0.0005 else {
                throw EditError.invalid(String(format: "For a Short, time is seconds into it (0–%.2f s).", short.length))
            }
            let frame = try await composedShortFrame(clip, short: short, at: time, settings: document.settings, original: request.original ?? false)
            let local = short.start + time
            let image = request.furniture == true ? (ShortFurnitureDrawing.draw(over: frame.image) ?? frame.image) : frame.image
            var preview = try writePreview(image, clipID: clipID, local: local, source: clip.timeline.location(at: local)?.source ?? 0,
                                           revision: requested, cropped: true, original: request.original ?? false, composed: true)
            preview.time = time
            preview.graphics = frame.graphics
            preview.short = id
            return .success(preview)
        } catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid("The Short's frame could not be rendered: \(error.localizedDescription)")) }
    }

    /// Exports a Short as a job: for YouTube into a folder (video, captions, cover, upload
    /// text and JSON), or alone to an MP4 path.
    func agentShortExport(_ request: AgentRequest, short id: UUID, path: String, origin: EditOrigin) -> Result<AgentJob, EditError> {
        guard let clipID = request.clip, let index = items.firstIndex(where: { $0.id == clipID }), let info = items[index].info,
              FileManager.default.fileExists(atPath: items[index].url.path) else {
            return .failure(EditError(code: .missingMedia, message: "Exporting a Short needs clip, a loaded recording whose source is present."))
        }
        let item = items[index]
        guard let short = item.short(id), let position = item.shorts.firstIndex(where: { $0.id == id }) else {
            return .failure(.notFound("No Short \(id) on recording \(clipID). state.clips[].shorts lists them."))
        }
        let project = projectID
        let exportSettings = settings
        // Graphics that still need drawing need HyperFrames, which only the owner can download.
        let cut = item.shortItem(short)
        if let graphics = cut.exportGraphics(exportSettings), !graphics.items.isEmpty, let renderer = graphicsRenderer, renderer != .ready,
           FFmpeg.graphicsPlan(graphics, info: info, crop: (cut.crop ?? info.fullFrame).evenClamped(in: info.fullFrame), segments: cut.segments,
                               settings: exportSettings, converted: true, canvas: ShortFormat.size).jobs.contains(where: { !$0.isRendered }) {
            let why: String
            if case .needsNode(let detail) = renderer { why = detail } else { why = HyperFrames.missingMessage }
            return .failure(EditError(code: .unsupportedCapability, message: why
                + " Ask the owner, hide the Short's graphics (updateShort hidden), or send setExportSettings with {\"graphics\": false}."))
        }
        let files: YouTubeExport.Files
        let output: URL
        if request.youtube == true {
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(.invalid("For a YouTube export, path is an existing folder; \(folder.path) is not one."))
            }
            if let blocking = item.shortIssues(short).first(where: { $0.severity == .blocking }) {
                return .failure(.invalid(blocking.message + " (state.clips[].shorts[].issues lists everything; updateShort changes it.)"))
            }
            files = ShortExport.files(in: folder, short: short, index: position, recording: item, settings: exportSettings, unique: false)
            if request.overwrite != true, let existing = files.all.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return .failure(.invalid("\(existing.lastPathComponent) already exists. Pass overwrite: true to replace it."))
            }
            output = files.video
        } else {
            output = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard output.pathExtension.lowercased() == "mp4" else { return .failure(.invalid("A Short exports as MP4; use a .mp4 path.")) }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(.invalid("The folder \(output.deletingLastPathComponent().path) does not exist."))
            }
            if FileManager.default.fileExists(atPath: output.path), request.overwrite != true {
                return .failure(.invalid("\(output.lastPathComponent) already exists. Pass overwrite: true to replace it."))
            }
            files = YouTubeExport.Files(video: output, captions: nil, thumbnail: nil, text: output, json: output)
        }
        let youtube = request.youtube == true
        let clip = ProjectClip(item)
        playback.pause()
        isConverting = true
        items[index].status = .converting(0)
        statusMessage = "\(origin.label) is exporting the Short \(output.lastPathComponent)…"
        let jobID = UUID()
        let job = startJob(id: jobID, kind: "export", clip: clipID, origin: origin) { [weak self] in
            defer { self?.isConverting = false }
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    guard let self else { return }
                    self.agentJobs[jobID]?.progress = value
                    if let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .converting(value) }
                }
            }
            do {
                if youtube {
                    try await ShortExport.run(item, info: info, short: short, settings: exportSettings, files: files,
                                              cover: { [weak self] time in
                                                  guard let self else { throw CancellationError() }
                                                  return try await self.composedShortFrame(clip, short: short, at: time, settings: exportSettings).image
                                              }, project: project, onProgress: progress)
                } else {
                    var videoSettings = exportSettings
                    videoSettings.format = .mp4
                    let temporary = output.deletingLastPathComponent().appendingPathComponent(".yamvideo-\(UUID().uuidString).mp4")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try await ShortExport.export(item, info: info, short: short, settings: videoSettings, output: temporary, onProgress: progress)
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary) }
                    else { try FileManager.default.moveItem(at: temporary, to: output) }
                }
            } catch {
                if let self, let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .ready }
                self?.statusMessage = error is CancellationError ? "Export cancelled." : "\(origin.label)'s Short export failed."
                throw error
            }
            if let self {
                if let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .done(output) }
                if youtube { self.noteExport(files.json, origin: origin) }
                self.statusMessage = "\(origin.label) exported the Short \(output.lastPathComponent)."
            }
            var result: [String: JSONValue] = ["path": .string(output.path), "format": .string("mp4"), "short": .string(id.uuidString),
                                               "width": .number(1080), "height": .number(1920)]
            if youtube {
                result["text"] = .string(files.text.path); result["json"] = .string(files.json.path)
                if let captions = files.captions, FileManager.default.fileExists(atPath: captions.path) { result["captions"] = .string(captions.path) }
                if let cover = files.thumbnail, FileManager.default.fileExists(atPath: cover.path) { result["cover"] = .string(cover.path) }
            }
            return .object(result)
        }
        return .success(job)
    }
}
