import CoreGraphics
import Foundation

// MARK: - Commands

/// Who made an edit. Attribution is informational, not proof of which model or person
/// is on the other end of a connection.
enum EditOrigin: Hashable, Codable {
    case human
    case agent(String)

    var label: String {
        switch self {
        case .human: return "You"
        case .agent(let name): return name
        }
    }

    var isHuman: Bool { self == .human }
}

/// One typed change to a project. Every human control and every local agent edits
/// through these, so there is exactly one set of rules for what a valid edit is.
///
/// Times: `splitSection.at` and zoom starts are edited-recording seconds; trim bounds
/// and section ranges are source seconds. Values are never clamped into range — an
/// out-of-range value is an error, so a caller never gets a silently different edit.
/// Times are snapped to the source frame and rectangles to even pixels, the same
/// rounding the export applies; the resulting state reports what was stored.
enum EditCommand: Equatable {
    case splitSection(clip: UUID, at: Double)
    case trimSection(clip: UUID, section: UUID, start: Double?, end: Double?)
    case deleteSection(clip: UUID, section: UUID)
    case moveSection(clip: UUID, section: UUID, to: Int)
    case setSectionSpeed(clip: UUID, section: UUID, speed: Double)
    /// The whole ordered section list at once, as silence removal produces it.
    case replaceSections(clip: UUID, sections: [TimelineSegment])
    case setCrop(clip: UUID, rect: CGRect)
    /// An `AspectPreset` label. Locks future crop drags to that shape; it does not move
    /// the crop by itself.
    case setAspect(clip: UUID, preset: String)
    case addBlurArea(clip: UUID, area: BlurRegion)
    case updateBlurArea(clip: UUID, area: UUID, rect: CGRect)
    case removeBlurArea(clip: UUID, area: UUID)
    case replaceBlurAreas(clip: UUID, areas: [BlurRegion])
    case addZoom(clip: UUID, zoom: ZoomShot)
    /// Replaces the zoom with the same ID.
    case updateZoom(clip: UUID, zoom: ZoomShot)
    case removeZoom(clip: UUID, zoom: UUID)
    case replaceZooms(clip: UUID, zooms: [ZoomShot])
    /// A permutation of every recording's ID.
    case setMovieOrder([UUID])
    case setIncludedInMovie(clip: UUID, included: Bool)
    case setMovieCanvas(MovieCanvas)
    case setExportSettings(ExportSettings)
    case setSubtitles(clip: UUID, url: URL?)
    /// Recordings to append. Agents add probed media; the app's own Add can add a
    /// recording whose probe is still running (no `info`, so nothing can edit it yet).
    case addMedia([ProjectClip])
    case removeMedia(clip: UUID)
    /// Points a recording at a moved copy of the same video, keeping every edit.
    case relinkMedia(clip: UUID, url: URL, info: MediaInfo)
    /// How the recording's colour was recorded. A profile the conversion table does not
    /// belong to removes the table and turns Natural colour off with it.
    case setInputProfile(clip: UUID, profile: ColorInputProfile)
    /// Attaches an imported conversion table, or removes it with nil (turning Natural
    /// colour off). Importing — reading, checking and storing the file — happens before
    /// the command, so the reducer stays free of I/O.
    case setTechnicalLUT(clip: UUID, lut: LUTAssetRef?)
    /// Natural colour: the technical conversion on or off.
    case setColorCorrection(clip: UUID, enabled: Bool)
    /// Any of the four controls, as absolute values; nil leaves a control as it is.
    case setColorAdjustments(clip: UUID, exposureEV: Double?, warmth: Double?, contrast: Double?, saturation: Double?)
    /// The four controls back to neutral. The recorded colour and conversion stay.
    case resetColorAdjustments(clip: UUID)
    /// One recording's adjustments onto others. The recorded colour, table and Natural
    /// colour come too only when asked, and only where the destination file allows them.
    case copyColor(from: UUID, to: [UUID], includeInterpretation: Bool)
    /// A whole-frame blur. Start and end snap to the frame cadence; it may not overlap
    /// another blur on the same recording.
    case addBlurEffect(clip: UUID, effect: VideoBlurEffect)
    /// Replaces the blur with the same ID.
    case updateBlurEffect(clip: UUID, effect: VideoBlurEffect)
    case removeBlurEffect(clip: UUID, effect: UUID)
    case addMarker(clip: UUID, marker: TimelineMarker)
    /// Replaces the marker with the same ID.
    case updateMarker(clip: UUID, marker: TimelineMarker)
    case removeMarker(clip: UUID, marker: UUID)
    case addGraphic(clip: UUID, graphic: Graphic)
    /// Replaces the graphic with the same ID.
    case updateGraphic(clip: UUID, graphic: Graphic)
    case removeGraphic(clip: UUID, graphic: UUID)
    /// Every graphic at once, and the style too when given — what an import produces.
    case replaceGraphics(clip: UUID, graphics: [Graphic], style: GraphicsStyle?)
    /// The look of every graphic on the recording: accent, panel, move aside, edge, look.
    case setGraphicsStyle(clip: UUID, style: GraphicsStyle)
    /// What YouTube needs for the recording; an empty one clears it.
    case setPublishInfo(clip: UUID, info: PublishInfo)
    /// The project's auto edit answers: transcript model and language, cut style,
    /// captions and loudness.
    case setAutoEditOptions(AutoEditOptions)
    /// What was said in the recording, word by word in source seconds, or nil to forget it.
    case setTranscript(clip: UUID, transcript: Transcript?)
    /// Vertical versions of parts of the recording, for YouTube Shorts.
    case addShort(clip: UUID, short: Short)
    case updateShort(clip: UUID, short: Short)
    case removeShort(clip: UUID, short: UUID)

    /// Undo-menu wording when a caller does not name the transaction itself.
    var defaultLabel: String {
        switch self {
        case .splitSection: return "Split Section"
        case .trimSection: return "Trim Section"
        case .deleteSection: return "Delete Section"
        case .moveSection: return "Move Section"
        case .setSectionSpeed: return "Change Section Speed"
        case .replaceSections: return "Edit Sections"
        case .setCrop: return "Crop"
        case .setAspect: return "Crop Aspect"
        case .addBlurArea: return "Add Blur"
        case .updateBlurArea: return "Move Blur"
        case .removeBlurArea: return "Delete Blur"
        case .replaceBlurAreas: return "Edit Blurs"
        case .addZoom: return "Add Zoom"
        case .updateZoom: return "Adjust Zoom"
        case .removeZoom: return "Delete Zoom"
        case .replaceZooms: return "Edit Zooms"
        case .setMovieOrder: return "Reorder Recordings"
        case .setIncludedInMovie(_, let included): return included ? "Include Recording" : "Exclude Recording"
        case .setMovieCanvas: return "Movie Canvas"
        case .setExportSettings: return "Export Settings"
        case .setSubtitles(_, let url): return url == nil ? "Remove Subtitles" : "Choose Subtitles"
        case .addMedia: return "Add Videos"
        case .removeMedia: return "Remove Video"
        case .relinkMedia: return "Locate Source"
        case .setInputProfile: return "Recorded Colour"
        case .setTechnicalLUT(_, let lut): return lut == nil ? "Remove Conversion" : "Add Conversion"
        case .setColorCorrection(_, let enabled): return enabled ? "Natural Colour" : "Remove Correction"
        case .setColorAdjustments: return "Adjust Colour"
        case .resetColorAdjustments: return "Reset Colour"
        case .copyColor: return "Copy Colour"
        case .addBlurEffect: return "Add Blur Effect"
        case .updateBlurEffect: return "Adjust Blur Effect"
        case .removeBlurEffect: return "Delete Blur Effect"
        case .addMarker: return "Add Marker"
        case .updateMarker: return "Edit Marker"
        case .removeMarker: return "Delete Marker"
        case .addGraphic: return "Add Graphic"
        case .updateGraphic: return "Edit Graphic"
        case .removeGraphic: return "Delete Graphic"
        case .replaceGraphics: return "Edit Graphics"
        case .setGraphicsStyle: return "Graphics Style"
        case .setPublishInfo: return "Publish Details"
        case .setAutoEditOptions: return "Auto Edit Options"
        case .setTranscript(_, let transcript): return transcript == nil ? "Remove Transcript" : "Transcribe"
        case .addShort: return "Add Short"
        case .updateShort: return "Edit Short"
        case .removeShort: return "Delete Short"
        }
    }
}

// MARK: - Errors

/// A refusal with a stable machine-readable code, a sentence a person can act on, and
/// whether simply retrying (after rereading state) can succeed.
struct EditError: Error, Equatable, LocalizedError {
    enum Code: String, Codable {
        case invalidCommand = "invalid_command"
        case notFound = "not_found"
        case revisionConflict = "revision_conflict"
        case wrongSession = "wrong_session"
        case interactionInProgress = "interaction_in_progress"
        case exportInProgress = "export_in_progress"
        case missingMedia = "missing_media"
        case unsupportedCapability = "unsupported_capability"
        case requestIDReused = "request_id_reused"
        case diskConflict = "disk_conflict"
        case resyncRequired = "resync_required"
        case agentsPaused = "agents_paused"
        case historyConflict = "history_conflict"
        case nothingToUndo = "nothing_to_undo"
        case sessionFull = "session_full"
        case invalidRequest = "invalid_request"
        case requestInProgress = "request_in_progress"
    }

    var code: Code
    var message: String
    var errorDescription: String? { message }

    var retryable: Bool {
        switch code {
        case .revisionConflict, .interactionInProgress, .exportInProgress, .agentsPaused,
             .historyConflict, .resyncRequired, .requestInProgress: return true
        default: return false
        }
    }

    static func invalid(_ message: String) -> EditError { EditError(code: .invalidCommand, message: message) }
    static func notFound(_ message: String) -> EditError { EditError(code: .notFound, message: message) }
}

// MARK: - Reducer

extension ProjectClip {
    /// An uncut recording is one section spanning the source, whose ID is the clip's own
    /// — stable, so a section can be named before anything has been cut.
    var timeline: ClipTimeline {
        ClipTimeline(segments: segments ?? [TimelineSegment(id: id, start: 0, end: info?.duration ?? 0)])
    }
}

/// What a batch did, beyond the new document itself.
struct EditOutcome: Equatable {
    var project: VideoProject
    /// IDs the batch generated, in command order: the right half of a split, new blur
    /// areas and zooms without a caller-supplied ID.
    var createdIDs: [UUID] = []
    /// Zooms dropped because the footage they were anchored to was cut away or no
    /// longer leaves room for them. Undo restores them.
    var removedZooms: [UUID] = []
    var removedEffects: [UUID] = []
    var removedMarkers: [UUID] = []
    /// Graphics dropped for the same reason.
    var removedGraphics: [UUID] = []
    /// Shorts whose footage was all cut away.
    var removedShorts: [UUID] = []
}

/// Applies a batch of commands to a project value. Pure: no UI state, no selection, no
/// playhead, no I/O. Either every command applies and the result validates, or it
/// throws and the caller's document is untouched.
enum ProjectReducer {
    static func apply(_ commands: [EditCommand], to project: VideoProject) throws -> EditOutcome {
        var outcome = EditOutcome(project: project)
        for command in commands {
            try apply(command, to: &outcome)
        }
        do { try outcome.project.validate() } catch {
            throw EditError.invalid(error.localizedDescription)
        }
        return outcome
    }

    private static func apply(_ command: EditCommand, to outcome: inout EditOutcome) throws {
        switch command {
        case .splitSection(let clip, let at):
            var created: UUID?
            try editTimeline(clip, in: &outcome) { timeline, info in
                try requireFinite(at, "split time")
                guard (0...timeline.duration).contains(at) else {
                    throw EditError.invalid("The split time is outside the edited recording (0–\(seconds(timeline.duration))).")
                }
                created = timeline.split(at: at, fps: info.fps)
                guard created != nil else {
                    throw EditError.invalid("Split inside a section, at least one frame from its edges.")
                }
            }
            if let created { outcome.createdIDs.append(created) }

        case .trimSection(let clip, let section, let start, let end):
            try editTimeline(clip, in: &outcome) { timeline, info in
                let index = try sectionIndex(section, in: timeline)
                let rate = max(1, info.fps)
                var segment = timeline.segments[index]
                if let start {
                    try requireFinite(start, "trim start")
                    segment.start = (start * rate).rounded() / rate
                }
                if let end {
                    try requireFinite(end, "trim end")
                    segment.end = (end * rate).rounded() / rate
                }
                guard segment.start >= 0, segment.end <= info.duration + 0.000001 else {
                    throw EditError.invalid("Trim bounds must stay within the source (0–\(seconds(info.duration))).")
                }
                guard segment.end - segment.start >= ceil(max(1, segment.speed)) / rate - 0.000001 else {
                    throw EditError.invalid("A section must keep at least one output frame.")
                }
                let overlaps = timeline.segments.enumerated().contains { other in
                    other.offset != index && segment.start < other.element.end - 0.000001
                        && other.element.start < segment.end - 0.000001
                }
                guard !overlaps else {
                    throw EditError.invalid("Sections cannot share footage; trim stops at the neighbouring section.")
                }
                timeline.segments[index] = segment
            }

        case .deleteSection(let clip, let section):
            try editTimeline(clip, in: &outcome) { timeline, _ in
                let index = try sectionIndex(section, in: timeline)
                guard timeline.segments.count > 1 else {
                    throw EditError.invalid("Keep at least one section. Remove the recording to discard it.")
                }
                timeline.segments.remove(at: index)
            }

        case .moveSection(let clip, let section, let destination):
            try editTimeline(clip, in: &outcome) { timeline, _ in
                let index = try sectionIndex(section, in: timeline)
                guard timeline.segments.indices.contains(destination) else {
                    throw EditError.invalid("Move a section to a position from 0 to \(timeline.segments.count - 1).")
                }
                let moved = timeline.segments.remove(at: index)
                timeline.segments.insert(moved, at: destination)
            }

        case .setSectionSpeed(let clip, let section, let speed):
            try editTimeline(clip, in: &outcome) { timeline, info in
                let index = try sectionIndex(section, in: timeline)
                guard speed.isFinite, (0.25...4).contains(speed) else {
                    throw EditError.invalid("Speed must be between 0.25× and 4×.")
                }
                guard timeline.segments[index].sourceDuration / speed >= 1 / max(1, info.fps) - 0.000001 else {
                    throw EditError.invalid("This section is too short for that speed; keep at least one output frame.")
                }
                timeline.segments[index].speed = speed
            }

        case .replaceSections(let clip, let sections):
            try editTimeline(clip, in: &outcome) { timeline, _ in
                guard !sections.isEmpty else { throw EditError.invalid("Keep at least one section.") }
                timeline.segments = sections
            }

        case .setCrop(let clip, let rect):
            try editClip(clip, in: &outcome) { record, info in
                try requireRect(rect, in: info, minimumSide: 16, what: "crop")
                record.crop = rect.evenClamped(in: info.fullFrame)
            }

        case .setAspect(let clip, let preset):
            try editClip(clip, in: &outcome) { record, _ in
                guard let match = AspectPreset.all.first(where: { $0.label == preset }) else {
                    throw EditError.invalid("Unknown aspect \"\(preset)\". Use one of: "
                        + AspectPreset.all.map(\.label).joined(separator: ", ") + ".")
                }
                record.aspectLock = match.ratio
                record.aspectLabel = match.label
            }

        case .addBlurArea(let clip, let area):
            try editClip(clip, in: &outcome) { record, info in
                guard !record.blurRegions.contains(where: { $0.id == area.id }) else {
                    throw EditError.invalid("A blur area with that ID already exists.")
                }
                try requireRect(area.rect, in: info, minimumSide: 1, what: "blur area")
                record.blurRegions.append(BlurRegion(id: area.id, rect: area.rect.evenClamped(in: info.fullFrame)))
            }
            outcome.createdIDs.append(area.id)

        case .updateBlurArea(let clip, let id, let rect):
            try editClip(clip, in: &outcome) { record, info in
                guard let index = record.blurRegions.firstIndex(where: { $0.id == id }) else {
                    throw EditError.notFound("No blur area with that ID on this recording.")
                }
                try requireRect(rect, in: info, minimumSide: 1, what: "blur area")
                record.blurRegions[index].rect = rect.evenClamped(in: info.fullFrame)
            }

        case .removeBlurArea(let clip, let id):
            try editClip(clip, in: &outcome) { record, _ in
                guard record.blurRegions.contains(where: { $0.id == id }) else {
                    throw EditError.notFound("No blur area with that ID on this recording.")
                }
                record.blurRegions.removeAll { $0.id == id }
            }

        case .replaceBlurAreas(let clip, let areas):
            try editClip(clip, in: &outcome) { record, info in
                for area in areas { try requireRect(area.rect, in: info, minimumSide: 1, what: "blur area") }
                record.blurRegions = areas.map { BlurRegion(id: $0.id, rect: $0.rect.evenClamped(in: info.fullFrame)) }
            }

        case .addZoom(let clip, let zoom):
            try editClip(clip, in: &outcome) { record, info in
                guard !record.zoomShots.contains(where: { $0.id == zoom.id }) else {
                    throw EditError.invalid("A zoom with that ID already exists.")
                }
                try requireZoom(zoom, in: record, info: info, excluding: nil)
                record.zoomShots.append(zoom)
                record.zoomShots.sort { $0.start < $1.start }
            }
            outcome.createdIDs.append(zoom.id)

        case .updateZoom(let clip, let zoom):
            try editClip(clip, in: &outcome) { record, info in
                guard let index = record.zoomShots.firstIndex(where: { $0.id == zoom.id }) else {
                    throw EditError.notFound("No zoom with that ID on this recording.")
                }
                try requireZoom(zoom, in: record, info: info, excluding: zoom.id)
                record.zoomShots[index] = zoom
                record.zoomShots.sort { $0.start < $1.start }
            }

        case .removeZoom(let clip, let id):
            try editClip(clip, in: &outcome) { record, _ in
                guard record.zoomShots.contains(where: { $0.id == id }) else {
                    throw EditError.notFound("No zoom with that ID on this recording.")
                }
                record.zoomShots.removeAll { $0.id == id }
            }

        case .replaceZooms(let clip, let zooms):
            try editClip(clip, in: &outcome) { record, info in
                record.zoomShots = []
                for zoom in zooms.sorted(by: { $0.start < $1.start }) {
                    try requireZoom(zoom, in: record, info: info, excluding: nil)
                    record.zoomShots.append(zoom)
                }
            }

        case .setMovieOrder(let order):
            let current = outcome.project.clips.map(\.id)
            guard order.count == current.count, Set(order) == Set(current) else {
                throw EditError.invalid("The movie order must list every recording exactly once.")
            }
            let byID = Dictionary(uniqueKeysWithValues: outcome.project.clips.map { ($0.id, $0) })
            outcome.project.clips = order.compactMap { byID[$0] }

        case .setIncludedInMovie(let clip, let included):
            let index = try clipIndex(clip, in: outcome.project)
            outcome.project.clips[index].includedInMovie = included

        case .setMovieCanvas(let canvas):
            var movie = outcome.project.movieSettings ?? MovieSettings()
            movie.canvas = canvas
            outcome.project.movieSettings = movie

        case .setExportSettings(let settings):
            guard settings.quality.isFinite, (0...100).contains(settings.quality),
                  settings.blurStrength.isFinite, (1...100).contains(settings.blurStrength),
                  ExportSettings.presets.contains(settings.preset) else {
                throw EditError.invalid("Quality must be 0–100, blur strength 1–100, and the speed preset one of "
                    + ExportSettings.presets.joined(separator: ", ") + ".")
            }
            guard settings.outputFolder?.isFileURL ?? true else {
                throw EditError.invalid("The output folder must be a local folder.")
            }
            outcome.project.settings = settings

        case .setSubtitles(let clip, let url):
            let index = try clipIndex(clip, in: outcome.project)
            guard url?.isFileURL ?? true else { throw EditError.invalid("Subtitle files must be local.") }
            if let url, !FFmpeg.subtitleExtensions.contains(url.pathExtension.lowercased()) {
                throw EditError.invalid("Subtitles must be one of: " + FFmpeg.subtitleExtensions.joined(separator: ", ") + ".")
            }
            outcome.project.clips[index].subtitles = url

        case .addMedia(let clips):
            var paths = Set(outcome.project.clips.map { $0.url.standardizedFileURL.path })
            for var clip in clips {
                guard clip.url.isFileURL else { throw EditError.invalid("Recordings must be local files.") }
                guard paths.insert(clip.url.standardizedFileURL.path).inserted else {
                    throw EditError.invalid("\(clip.url.lastPathComponent) is already in the project.")
                }
                guard !outcome.project.clips.contains(where: { $0.id == clip.id }) else {
                    throw EditError.invalid("A recording with that ID already exists.")
                }
                if let info = clip.info, clip.crop == nil { clip.crop = info.fullFrame }
                outcome.project.clips.append(clip)
                outcome.createdIDs.append(clip.id)
            }

        case .removeMedia(let clip):
            let index = try clipIndex(clip, in: outcome.project)
            outcome.project.clips.remove(at: index)

        case .relinkMedia(let clip, let url, let info):
            let index = try clipIndex(clip, in: outcome.project)
            guard url.isFileURL else { throw EditError.invalid("Recordings must be local files.") }
            if let original = outcome.project.clips[index].info {
                guard info.width == original.width, info.height == original.height,
                      abs(info.duration - original.duration) < 0.1, abs(info.fps - original.fps) < 0.01 else {
                    throw EditError.invalid("Choose the original video with matching dimensions and duration.")
                }
            }
            outcome.project.clips[index].url = url
            outcome.project.clips[index].info = info
            if outcome.project.clips[index].crop == nil { outcome.project.clips[index].crop = info.fullFrame }

        case .setInputProfile(let clip, let profile):
            try editColor(clip, in: &outcome) { color, _ in
                color.inputProfile = profile
                if profile != .pocket3DLogM { color.technicalLUT = nil; color.correctionEnabled = false }
            }

        case .setTechnicalLUT(let clip, let lut):
            try editColor(clip, in: &outcome) { color, _ in
                if let lut {
                    guard color.inputProfile == .pocket3DLogM else {
                        throw EditError.invalid("Set the recording's colour to Pocket 3 D-Log M before adding its conversion.")
                    }
                    color.technicalLUT = lut
                } else {
                    color.technicalLUT = nil; color.correctionEnabled = false
                }
            }

        case .setColorCorrection(let clip, let enabled):
            try editColor(clip, in: &outcome) { color, _ in
                guard !enabled || (color.inputProfile == .pocket3DLogM && color.technicalLUT != nil) else {
                    throw EditError.invalid("Natural colour needs the recording set to Pocket 3 D-Log M and DJI's conversion added.")
                }
                color.correctionEnabled = enabled
            }

        case .setColorAdjustments(let clip, let exposureEV, let warmth, let contrast, let saturation):
            guard exposureEV != nil || warmth != nil || contrast != nil || saturation != nil else {
                throw EditError.invalid("Give at least one of exposureEV, warmth, contrast or saturation.")
            }
            try editColor(clip, in: &outcome) { color, _ in
                let changes: [(String, Double?, ClosedRange<Double>, WritableKeyPath<ClipColorSettings, Double>)] = [
                    ("Brightness (exposureEV)", exposureEV, ColorAdjustments.exposureRange, \.exposureEV),
                    ("Warmth", warmth, ColorAdjustments.warmthRange, \.warmth),
                    ("Contrast", contrast, ColorAdjustments.contrastRange, \.contrast),
                    ("Colour strength (saturation)", saturation, ColorAdjustments.saturationRange, \.saturation),
                ]
                for (name, value, range, path) in changes {
                    guard let value else { continue }
                    guard value.isFinite, range.contains(value) else {
                        throw EditError.invalid("\(name) must be from \(range.lowerBound.formatted()) to \(range.upperBound.formatted()).")
                    }
                    color[keyPath: path] = value
                }
            }

        case .resetColorAdjustments(let clip):
            try editColor(clip, in: &outcome) { color, _ in color.adjustments = .neutral }

        case .addGraphic(let clip, let graphic):
            try editGraphics(clip, in: &outcome) { track in
                guard !track.items.contains(where: { $0.id == graphic.id }) else {
                    throw EditError.invalid("A graphic with that ID already exists.")
                }
                track.items.append(graphic)
            }
            outcome.createdIDs.append(graphic.id)

        case .updateGraphic(let clip, let graphic):
            try editGraphics(clip, in: &outcome) { track in
                guard let index = track.items.firstIndex(where: { $0.id == graphic.id }) else {
                    throw EditError.notFound("No graphic with that ID on this recording.")
                }
                track.items[index] = graphic
            }

        case .removeGraphic(let clip, let id):
            try editGraphics(clip, in: &outcome) { track in
                guard track.items.contains(where: { $0.id == id }) else {
                    throw EditError.notFound("No graphic with that ID on this recording.")
                }
                track.items.removeAll { $0.id == id }
            }

        case .replaceGraphics(let clip, let graphics, let style):
            try editGraphics(clip, in: &outcome) { track in
                track.items = graphics
                if let style { track.style = style }
            }

        case .setGraphicsStyle(let clip, let style):
            try editGraphics(clip, in: &outcome) { track in track.style = style }

        case .setPublishInfo(let clip, var info):
            try editClip(clip, in: &outcome) { record, _ in
                if let problem = info.problem { throw EditError.invalid(problem) }
                let duration = record.timeline.duration
                if let design = info.design, design.time > duration + 0.0005 {
                    throw EditError.invalid("The thumbnail's frame must be within the edited recording (0–\(PublishInfo.timestamp(duration))).")
                }
                if let late = info.chapters.first(where: { $0.time > duration + 0.0005 }) {
                    throw EditError.invalid("A chapter at \(PublishInfo.timestamp(late.time)) is after the end of the edited recording (\(PublishInfo.timestamp(duration))).")
                }
                info.chapters.sort { $0.time < $1.time }
                record.publish = info.isEmpty ? nil : info
            }

        case .setAutoEditOptions(let options):
            if let problem = options.problem { throw EditError.invalid(problem) }
            outcome.project.autoEdit = options

        case .setTranscript(let clip, let transcript):
            try editClip(clip, in: &outcome) { record, info in
                if let problem = transcript?.problem(duration: info.duration) { throw EditError.invalid(problem) }
                record.transcript = transcript
            }

        case .addShort(let clip, let short):
            try editShorts(clip, in: &outcome) { shorts in
                guard !shorts.contains(where: { $0.id == short.id }) else { throw EditError.invalid("A Short with that ID already exists.") }
                shorts.append(short)
            } placing: { short }
            outcome.createdIDs.append(short.id)

        case .updateShort(let clip, let short):
            try editShorts(clip, in: &outcome) { shorts in
                guard let index = shorts.firstIndex(where: { $0.id == short.id }) else {
                    throw EditError.notFound("No Short with that ID on this recording.")
                }
                shorts[index] = short
            } placing: { short }

        case .removeShort(let clip, let id):
            try editShorts(clip, in: &outcome) { shorts in
                guard shorts.contains(where: { $0.id == id }) else { throw EditError.notFound("No Short with that ID on this recording.") }
                shorts.removeAll { $0.id == id }
            } placing: { nil }

        case .copyColor(let source, let targets, let includeInterpretation):
            let from = outcome.project.clips[try clipIndex(source, in: outcome.project)].color ?? ClipColorSettings()
            guard !targets.isEmpty else { throw EditError.invalid("Choose at least one recording to copy the colour to.") }
            guard !targets.contains(source), Set(targets).count == targets.count else {
                throw EditError.invalid("Copy to other recordings, each named once.")
            }
            for target in targets {
                try editColor(target, in: &outcome) { color, info in
                    color.adjustments = from.adjustments
                    guard includeInterpretation else { return }
                    color.inputProfile = from.inputProfile
                    color.technicalLUT = from.technicalLUT
                    color.correctionEnabled = from.correctionEnabled
                }
            }

        case .addBlurEffect(let clip, let effect):
            try editEffects(clip, in: &outcome) { effects, _ in
                guard !effects.contains(where: { $0.id == effect.id }) else {
                    throw EditError.invalid("A blur effect with that ID already exists.")
                }
                effects.append(effect)
            } placing: { effect }
            outcome.createdIDs.append(effect.id)

        case .updateBlurEffect(let clip, let effect):
            try editEffects(clip, in: &outcome) { effects, _ in
                guard let index = effects.firstIndex(where: { $0.id == effect.id }) else {
                    throw EditError.notFound("No blur effect with that ID on this recording.")
                }
                effects[index] = effect
            } placing: { effect }

        case .removeBlurEffect(let clip, let id):
            try editEffects(clip, in: &outcome) { effects, _ in
                guard effects.contains(where: { $0.id == id }) else {
                    throw EditError.notFound("No blur effect with that ID on this recording.")
                }
                effects.removeAll { $0.id == id }
            } placing: { nil }

        case .addMarker(let clip, let marker):
            try editMarkers(clip, in: &outcome) { markers in
                guard !markers.contains(where: { $0.id == marker.id }) else {
                    throw EditError.invalid("A marker with that ID already exists.")
                }
                markers.append(marker)
            }
            outcome.createdIDs.append(marker.id)

        case .updateMarker(let clip, let marker):
            try editMarkers(clip, in: &outcome) { markers in
                guard let index = markers.firstIndex(where: { $0.id == marker.id }) else {
                    throw EditError.notFound("No marker with that ID on this recording.")
                }
                markers[index] = marker
            }

        case .removeMarker(let clip, let id):
            try editMarkers(clip, in: &outcome) { markers in
                guard markers.contains(where: { $0.id == id }) else {
                    throw EditError.notFound("No marker with that ID on this recording.")
                }
                markers.removeAll { $0.id == id }
            }
        }
    }

    // MARK: Helpers

    private static func clipIndex(_ id: UUID, in project: VideoProject) throws -> Int {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else {
            throw EditError.notFound("No recording with that ID in this project.")
        }
        return index
    }

    /// Runs `body` on one recording that has finished probing.
    private static func editClip(_ id: UUID, in outcome: inout EditOutcome,
                                 _ body: (inout ProjectClip, MediaInfo) throws -> Void) throws {
        let index = try clipIndex(id, in: outcome.project)
        guard let info = outcome.project.clips[index].info else {
            throw EditError(code: .missingMedia, message: "That recording is still loading; edit it once it has been probed.")
        }
        try body(&outcome.project.clips[index], info)
    }

    /// Edits a recording's sections, then carries its zooms, blur effects, markers and
    /// graphics across: each follows the frame it began on, and is dropped when that
    /// footage is gone.
    private static func editTimeline(_ id: UUID, in outcome: inout EditOutcome,
                                     _ body: (inout ClipTimeline, MediaInfo) throws -> Void) throws {
        var removed: (zooms: [UUID], effects: [UUID], markers: [UUID], graphics: [UUID], shorts: [UUID]) = ([], [], [], [], [])
        try editClip(id, in: &outcome) { record, info in
            let old = record.timeline
            var timeline = old
            try body(&timeline, info)
            guard timeline != old else { return }
            let kept = timeline.remap(record.zoomShots, from: old)
            removed.zooms = record.zoomShots.map(\.id).filter { id in !kept.contains { $0.id == id } }
            record.zoomShots = kept
            let effects = record.blurEffects ?? []
            let keptEffects = timeline.remap(effects, from: old, fps: info.fps)
            removed.effects = effects.map(\.id).filter { id in !keptEffects.contains { $0.id == id } }
            record.blurEffects = keptEffects.isEmpty ? nil : keptEffects
            let markers = record.markers ?? []
            let keptMarkers = timeline.remap(markers, from: old)
            removed.markers = markers.map(\.id).filter { id in !keptMarkers.contains { $0.id == id } }
            record.markers = keptMarkers.isEmpty ? nil : keptMarkers
            if let graphics = record.graphics {
                let remapped = timeline.remap(graphics, from: old)
                record.graphics = remapped.track
                removed.graphics = remapped.removed
            }
            if let shorts = record.shorts {
                let remapped = timeline.remap(shorts, from: old, fps: info.fps)
                record.shorts = remapped.shorts.isEmpty ? nil : Self.pruned(remapped.shorts, graphics: record.graphics)
                removed.shorts = remapped.removed
            }
            if var publish = record.publish {
                publish.chapters = timeline.remap(publish.chapters, from: old)
                // The thumbnail's frame follows its footage, or stays inside the recording.
                if let time = publish.design?.time {
                    publish.design?.time = timeline.carry(time, from: old) ?? min(time, timeline.duration)
                }
                record.publish = publish
            }
            record.segments = timeline.segments
        }
        outcome.removedZooms += removed.zooms
        outcome.removedEffects += removed.effects
        outcome.removedMarkers += removed.markers
        outcome.removedGraphics += removed.graphics
        outcome.removedShorts += removed.shorts
    }

    /// Edits one probed recording's graphics and checks the whole track against its
    /// edited length. An empty track with the default style is stored as nothing.
    private static func editGraphics(_ id: UUID, in outcome: inout EditOutcome,
                                     _ body: (inout GraphicsTrack) throws -> Void) throws {
        try editClip(id, in: &outcome) { record, _ in
            var track = record.graphics ?? GraphicsTrack()
            try body(&track)
            track.items.sort { $0.start < $1.start }
            if let problem = track.problem(duration: record.timeline.duration) { throw EditError.invalid(problem) }
            record.graphics = track.isEmpty ? nil : track
            if let shorts = record.shorts { record.shorts = Self.pruned(shorts, graphics: record.graphics) }
        }
    }

    /// Shorts forget graphics that are gone: none is hidden or placed that does not exist.
    private static func pruned(_ shorts: [Short], graphics: GraphicsTrack?) -> [Short] {
        let present = Set(graphics?.items.map(\.id) ?? [])
        return shorts.map { short in
            var kept = short
            kept.hidden = short.hidden.filter(present.contains)
            kept.placements = short.placements.filter { present.contains($0.key) }
            return kept
        }
    }

    /// Edits a recording's Shorts. `placing` names the Short being placed, whose times are
    /// snapped to frames and whose window to even pixels; then all of them are checked.
    private static func editShorts(_ id: UUID, in outcome: inout EditOutcome,
                                   _ body: (inout [Short]) throws -> Void, placing: () -> Short?) throws {
        try editClip(id, in: &outcome) { record, info in
            var shorts = record.shorts ?? []
            try body(&shorts)
            if let placed = placing(), let index = shorts.firstIndex(where: { $0.id == placed.id }) {
                var short = placed
                guard short.start.isFinite, short.end.isFinite else { throw EditError.invalid("A Short's start and end must be finite numbers.") }
                short.start = snapToFrame(short.start, fps: info.fps)
                short.end = snapToFrame(short.end, fps: info.fps)
                if let window = short.window {
                    guard window.minX.isFinite, window.minY.isFinite, window.width.isFinite, window.height.isFinite else {
                        throw EditError.invalid("The Short's window must be finite numbers.")
                    }
                    short.window = window.evenClamped(in: info.fullFrame)
                    if window.width > 0, window.height > 0, !info.fullFrame.insetBy(dx: -1, dy: -1).contains(window) {
                        throw EditError.invalid("The Short's window must lie inside the \(info.width)×\(info.height) picture.")
                    }
                }
                short.tags = short.tags.map { $0.trimmingCharacters(in: .whitespaces) }
                short.hidden = Array(Set(short.hidden)).sorted { $0.uuidString < $1.uuidString }
                shorts[index] = short
            }
            let duration = record.timeline.duration
            if let problem = shortsProblem(shorts, duration: duration, info: info) { throw EditError.invalid(problem) }
            shorts.sort { $0.start < $1.start }
            record.shorts = shorts.isEmpty ? nil : Self.pruned(shorts, graphics: record.graphics)
        }
    }

    /// Edits a recording's blur effects. `placing` names the block being placed, whose
    /// timing is snapped to frames and checked against the timeline and its neighbours.
    private static func editEffects(_ id: UUID, in outcome: inout EditOutcome,
                                    _ body: (inout [VideoBlurEffect], MediaInfo) throws -> Void,
                                    placing: () -> VideoBlurEffect?) throws {
        try editClip(id, in: &outcome) { record, info in
            var effects = record.blurEffects ?? []
            try body(&effects, info)
            if let placed = placing(), let index = effects.firstIndex(where: { $0.id == placed.id }) {
                let effect = placed.snapped(fps: info.fps)
                if let problem = effect.problem(duration: record.timeline.duration, fps: info.fps) {
                    throw EditError.invalid(problem)
                }
                if let other = effects.first(where: { $0.id != effect.id && $0.overlaps(effect) }) {
                    throw EditError.invalid(String(format: "That overlaps the blur effect at %.2f–%.2f s. Effects on one recording may touch but not overlap.",
                                                   other.start, other.end))
                }
                effects[index] = effect
            }
            effects.sort { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
            record.blurEffects = effects.isEmpty ? nil : effects
        }
    }

    private static func editMarkers(_ id: UUID, in outcome: inout EditOutcome,
                                    _ body: (inout [TimelineMarker]) throws -> Void) throws {
        try editClip(id, in: &outcome) { record, _ in
            var markers = record.markers ?? []
            try body(&markers)
            let duration = record.timeline.duration
            if let problem = markers.lazy.compactMap({ $0.problem(duration: duration) }).first {
                throw EditError.invalid(problem)
            }
            markers.sort { $0.time < $1.time }
            record.markers = markers.isEmpty ? nil : markers
        }
    }

    /// Edits one probed recording's colour settings, checks them against its file, and
    /// stores them only when they differ from the untouched default.
    private static func editColor(_ id: UUID, in outcome: inout EditOutcome,
                                  _ body: (inout ClipColorSettings, MediaInfo) throws -> Void) throws {
        try editClip(id, in: &outcome) { record, info in
            var color = record.color ?? ClipColorSettings()
            try body(&color, info)
            do {
                try color.validate()
                try color.validate(against: info)
            } catch {
                throw EditError.invalid("\(record.url.lastPathComponent): \(error.localizedDescription)")
            }
            record.color = color.isDefault ? nil : color
        }
    }

    private static func sectionIndex(_ id: UUID, in timeline: ClipTimeline) throws -> Int {
        guard let index = timeline.segments.firstIndex(where: { $0.id == id }) else {
            throw EditError.notFound("No section with that ID on this recording.")
        }
        return index
    }

    private static func requireFinite(_ value: Double, _ what: String) throws {
        guard value.isFinite else { throw EditError.invalid("The \(what) must be a finite number.") }
    }

    private static func requireRect(_ rect: CGRect, in info: MediaInfo, minimumSide: CGFloat, what: String) throws {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= minimumSide, rect.height >= minimumSide else {
            throw EditError.invalid("The \(what) needs a finite size of at least \(Int(minimumSide)) pixels.")
        }
        guard info.fullFrame.contains(rect) else {
            throw EditError.invalid("The \(what) must lie inside the \(info.width)×\(info.height) frame.")
        }
    }

    private static func requireZoom(_ zoom: ZoomShot, in record: ProjectClip, info: MediaInfo,
                                    excluding: UUID?) throws {
        let duration = record.timeline.duration
        guard zoom.start.isFinite, zoom.hold.isFinite, zoom.level.isFinite,
              zoom.target.x.isFinite, zoom.target.y.isFinite else {
            throw EditError.invalid("Zoom values must be finite numbers.")
        }
        guard zoom.start >= 0, zoom.end <= duration + 0.001 else {
            throw EditError.invalid("The zoom must fit inside the edited recording (\(seconds(duration))), "
                + "including its \(seconds(ZoomShot.ease)) ease in and out.")
        }
        guard zoom.hold >= 0.2 else { throw EditError.invalid("A zoom must hold for at least 0.2 s.") }
        guard (1...10).contains(zoom.level) else { throw EditError.invalid("Zoom level must be between 1× and 10×.") }
        // Inclusive of the far edges: the app clamps a dragged target onto the edge.
        guard (0...CGFloat(info.width)).contains(zoom.target.x), (0...CGFloat(info.height)).contains(zoom.target.y) else {
            throw EditError.invalid("The zoom target must be inside the \(info.width)×\(info.height) frame.")
        }
        guard !record.zoomShots.contains(where: { $0.id != excluding && $0.overlaps(zoom) }) else {
            throw EditError.invalid("That overlaps an existing zoom.")
        }
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
}
