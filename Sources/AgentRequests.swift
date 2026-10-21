import AppKit
import AVFoundation
import CryptoKit
import Foundation

// How the app answers local agents: decoding a request, turning wire commands into
// `EditCommand`s, and every method of the protocol. All of it runs on the main actor,
// and every edit goes through the same dispatcher as the owner's own.

// MARK: - Requests

/// A request as the app reads it. Only `method` is always required; each method checks
/// the fields it needs and names any that are missing.
struct AgentRequest: Codable {
    var protocolVersion: Int?
    var requestID: String?
    var method: String
    /// The client's name for attribution — "Codex", "Claude". Informational only.
    var client: String?
    var sessionID: UUID?
    var projectID: UUID?
    var expectedRevision: Int?
    var label: String?
    var dryRun: Bool?
    var commands: [WireCommand]?
    var transactionID: UUID?
    var after: Int?
    var limit: Int?
    var clip: UUID?
    var section: UUID?
    var zoom: UUID?
    var graphic: UUID?
    var time: Double?
    /// "recording" (the default) or "movie". Movie time is never assumed.
    var timeSpace: String?
    var path: String?
    var overwrite: Bool?
    /// export: write the YouTube files (video, captions, thumbnail, upload text) into the folder `path`.
    var youtube: Bool?
    /// thumbnail: changes to try over the stored design, without storing them.
    var design: [String: JSONValue]?
    /// thumbnail: also save the PNG next to the recording.
    var save: Bool?
    /// thumbnail: also run the phone check (what does not read on a phone in 0.5 s) and
    /// compare the thumbnail's words with the video's title.
    var check: Bool?
    /// thumbnail with check: a video title to compare with, in place of the stored one; not stored.
    var videoTitle: String?
    /// thumbnail: which version of a Test & Compare to draw: A (the design, the default), B or C.
    var version: String?
    var scope: String?
    var kind: String?
    var job: UUID?
    var cropped: Bool?
    /// A preview without the recording's colour stage, to pair with a corrected one.
    var original: Bool?
    /// A preview as the owner's Preview plays it: cropped, zoomed, coloured, with blur
    /// areas and whole-frame effects, at the export's frame size.
    var composed: Bool?
    /// With short: draw YouTube's Shorts player over the frame (`ShortFurnitureDrawing`).
    var furniture: Bool?
    var effect: UUID?
    var marker: UUID?
    var threshold: Double?
    var minimum: Double?
    var padding: Double?
    /// transcribe: the whisper model and language, when not the project's own answers.
    var model: String?
    var language: String?
    /// analyze kind autoEdit and autoEdit: a cut style other than the project's own.
    var style: String?
    /// preview, export and reveal: one of the recording's Shorts (then `time` is seconds into it).
    var short: UUID?
    /// reveal: one of the recording's screen layouts.
    var layout: UUID?
    /// reveal: an idea in the Library; shows it on the Library page.
    var idea: UUID?
    /// setLogo and removeLogo: the brand; setLogo: what the speaker says for it. setSound
    /// and removeSound: the sound's name.
    var name: String?
    var words: [String]?
    /// setSound: where the sound comes from: {licence, title, artist, source, line}.
    var credit: [String: JSONValue]?
    /// preview: graphics drawn in this preview only, never stored ({kind, start, end,
    /// props, look?, transform?, id?}, as in addGraphic), to show the owner a plan.
    var draft: [JSONValue]?
}

struct WireRect: Codable, Equatable {
    var x: Double, y: Double, width: Double, height: Double
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct WirePoint: Codable, Equatable {
    var x: Double, y: Double
    init(_ point: CGPoint) { x = point.x; y = point.y }
    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct WireSection: Codable, Equatable {
    var id: UUID?
    var start: Double
    var end: Double
    var speed: Double?
}

struct WireArea: Codable, Equatable {
    var id: UUID?
    var rect: WireRect
    /// Source seconds; without them the area covers the whole recording.
    var start: Double?
    var end: Double?
}

struct WireZoom: Codable, Equatable {
    var id: UUID?
    var start: Double
    var hold: Double?
    var level: Double?
    var target: WirePoint
}

/// A graphic as JSON. In `updateGraphic` every field is optional and replaces only
/// itself; `props`, when given, replaces all of the graphic's props.
struct WireGraphic: Codable, Equatable {
    var id: UUID?
    var kind: String?
    var start: Double?
    var end: Double?
    var props: [String: JSONValue]?
    /// "glass" or "ink"; "" clears it back to the style's choice.
    var look: String?
    /// Moved and scaled on the picture; in `updateGraphic` only the keys given change.
    var transform: WireTransform?
}

/// A screen layout span as JSON. In `updateLayout` every field is optional and replaces
/// only itself; moving start alone keeps the length.
struct WireLayout: Codable, Equatable {
    var id: UUID?
    var start: Double?
    var end: Double?
    /// speaker, screen or split.
    var layout: String?
    /// The part's own bubble: {corner, size, shape, corners}, each key optional. null (kept
    /// apart from a missing key) removes it.
    var bubble: JSONValue?

    init(id: UUID? = nil, start: Double? = nil, end: Double? = nil, layout: String? = nil, bubble: JSONValue? = nil) {
        self.id = id; self.start = start; self.end = end; self.layout = layout; self.bubble = bubble
    }

    enum CodingKeys: String, CodingKey { case id, start, end, layout, bubble }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id)
        start = try values.decodeIfPresent(Double.self, forKey: .start)
        end = try values.decodeIfPresent(Double.self, forKey: .end)
        layout = try values.decodeIfPresent(String.self, forKey: .layout)
        bubble = values.contains(.bubble) ? try values.decode(JSONValue.self, forKey: .bubble) : nil
    }
}

/// A graphic's move (design pixels of a 1920×1080 frame) and scale on the picture.
struct WireTransform: Codable, Equatable {
    var x: Double?
    var y: Double?
    var scale: Double?
}

/// One command as JSON: a `type` plus the fields that type uses. Unused fields are
/// ignored; missing required ones are named in the error.
struct WireCommand: Codable, Equatable {
    var type: String
    var clipID: UUID?
    var sectionID: UUID?
    var areaID: UUID?
    var zoomID: UUID?
    var at: Double?
    var start: Double?
    var end: Double?
    var speed: Double?
    var index: Int?
    var timeSpace: String?
    var rect: WireRect?
    var preset: String?
    /// setChange: which change, and whether it is on.
    var change: String?
    var on: Bool?
    /// updateBlurArea: true removes the area's start and end.
    var whole: Bool?
    var hold: Double?
    var level: Double?
    var target: WirePoint?
    var sections: [WireSection]?
    var areas: [WireArea]?
    var zooms: [WireZoom]?
    var order: [UUID]?
    var included: Bool?
    var canvas: String?
    var settings: [String: JSONValue]?
    var path: String?
    var paths: [String]?
    var profile: String?
    var enabled: Bool?
    var exposureEV: Double?
    var warmth: Double?
    var contrast: Double?
    var saturation: Double?
    var targets: [UUID]?
    var includeInterpretation: Bool?
    var effectID: UUID?
    var markerID: UUID?
    var time: Double?
    var duration: Double?
    var amount: Double?
    var mix: Double?
    var fadeIn: Double?
    var fadeOut: Double?
    var label: String?
    var color: String?
    var graphicID: UUID?
    var graphic: WireGraphic?
    var graphics: [WireGraphic]?
    /// Only the keys to change: accent, panel, moveVideo, edge, look, size.
    var graphicsStyle: [String: JSONValue]?
    /// Only the keys to change: title, description, tags, category, chapters, thumbnail, language, channel.
    var publish: [String: JSONValue]?
    /// Only the keys to change: model, language, cutStyle, captions, normaliseAudio.
    var autoEdit: [String: JSONValue]?
    var shortID: UUID?
    /// A Short's keys to set: start, end, window, title, description, tags, hidden,
    /// placements, cover, panels, captions (and id for a new one).
    var short: [String: JSONValue]?
    /// setScreen: the screen recording's time at the recording's source time 0.
    var offset: Double?
    /// updateScreen: only the keys to change: offset, crop, layout, bubble.
    var screen: [String: JSONValue]?
    var layoutID: UUID?
    var layout: WireLayout?
    var layouts: [WireLayout]?
    /// setProjectNotes: the whole Why notes ("" clears them).
    var notes: String?
    /// addProjectNote: one line added to the Why notes, with who and when.
    var note: String?
    /// updateMusic and removeMusic: the piece; addMusic: the new piece's id, when you choose it.
    var musicID: UUID?
    /// addMusic and updateMusic: the piece's keys to set: start, end (null: to the end), from,
    /// level, fadeIn, fadeOut, loop, credit, and path (updateMusic: another file).
    var music: [String: JSONValue]?
    /// setSounds: {on, level, cues}.
    var sounds: [String: JSONValue]?

    static let types = [
        "splitSection", "trimSection", "deleteSection", "moveSection", "setSectionSpeed", "replaceSections",
        "closeGaps", "setGap",
        "setCrop", "setAspect", "addBlurArea", "updateBlurArea", "removeBlurArea", "replaceBlurAreas",
        "addZoom", "updateZoom", "removeZoom", "replaceZooms", "setMovieOrder", "setIncludedInMovie",
        "setMovieCanvas", "setExportSettings", "setSubtitles", "clearSubtitles", "addMedia", "removeMedia",
        "relinkMedia", "setInputProfile", "importTechnicalLUT", "clearTechnicalLUT", "setColorCorrection",
        "setColorAdjustments", "resetColorAdjustments", "copyColorAdjustments",
        "addBlurEffect", "updateBlurEffect", "removeBlurEffect", "addMarker", "updateMarker", "removeMarker",
        "addGraphic", "updateGraphic", "removeGraphic", "replaceGraphics", "setGraphicsStyle", "importGraphics",
        "setPublishInfo", "setAutoEditOptions", "importTranscript", "clearTranscript",
        "addShort", "updateShort", "removeShort",
        "setScreen", "updateScreen", "removeScreen", "addLayout", "updateLayout", "removeLayout", "replaceLayouts",
        "addScreenZoom", "updateScreenZoom", "removeScreenZoom", "replaceScreenZooms",
        "setChange", "setProjectNotes", "addProjectNote",
        "addMusic", "updateMusic", "removeMusic", "setMusicDuck", "setSounds",
    ]

    /// Files that must be probed before this command can be resolved.
    var mediaPaths: [String] {
        switch type {
        case "addMedia": return paths ?? []
        case "relinkMedia", "setScreen": return path.map { [$0] } ?? []
        default: return []
        }
    }

    /// Music files that must be measured (length and loudness) before this command can be resolved.
    var musicPaths: [String] {
        switch type {
        case "addMusic": return path.map { [$0] } ?? []
        case "updateMusic": return music?["path"]?.string.map { [$0] } ?? []
        default: return []
        }
    }

    /// Conversion tables that must be read and checked before this command can be resolved.
    var lutPaths: [String] { type == "importTechnicalLUT" ? path.map { [$0] } ?? [] : [] }
}

// MARK: - Results

struct AgentReceipt: Encodable {
    var revision: Int
    var transactionID: UUID?
    var changed: Bool
    var dryRun: Bool
    var createdIDs: [UUID]
    var removedZooms: [UUID]
    var removedGraphics: [UUID] = []
    var removedShorts: [UUID] = []
    var removedLayouts: [UUID] = []
    var affectedClips: [UUID]
}

struct AgentSessions: Encodable { var sessions: [AgentSessionInfo] }

struct AgentSessionInfo: Encodable {
    var protocolVersion = AgentProtocol.version
    var instanceID: UUID
    var processID: Int32
    var sessionID: UUID
    var projectID: UUID
    var revision: Int
    var title: String
    var file: String?
    var unsaved: Bool
    var agentsPaused: Bool
    var exportInProgress: Bool
    var interactionInProgress: Bool
    var methods: [String]
    var commands: [String]
    var analyzeKinds = AgentSessionInfo.analyzeKinds
    static let analyzeKinds = ["silence", "zooms", "screenZooms", "autoEdit", "thumbnailFrames", "logos", "music"]
    var exportScopes = ["recording", "movie"]
    var timeSpaces = ["recording", "movie"]
}

struct AgentHistoryStep: Encodable {
    var transactionID: UUID
    var label: String
    var origin: String
    var originKind: String
}

struct AgentState: Encodable {
    struct Media: Encodable {
        var width: Int, height: Int, duration: Double, fps: Double, fpsExpression: String
        var hasAudio: Bool, hdr: String?
    }
    struct Section: Encodable {
        var id: UUID, start: Double, end: Double, speed: Double, editedStart: Double, editedDuration: Double
        /// Space the timeline shows in front of it, in seconds; absent when there is none.
        /// Only the timeline has it: playback and exports join the sections.
        var gapBefore: Double? = nil
    }
    struct Area: Encodable { var id: UUID; var rect: WireRect; var start: Double?; var end: Double? }
    struct Zoom: Encodable {
        var id: UUID, start: Double, hold: Double, level: Double, end: Double
        var target: WirePoint
    }
    struct Clip: Encodable {
        var id: UUID
        var name: String
        var path: String
        var status: String
        var statusDetail: String?
        var media: Media?
        var editedDuration: Double
        var includedInMovie: Bool
        var crop: WireRect?
        var aspect: String
        var subtitles: String?
        var sections: [Section]
        var blurAreas: [Area]
        var zooms: [Zoom]
        var color: Color?
        var blurEffects: [Effect]
        var markers: [Marker]
        var graphics: GraphicsTrack?
        /// What YouTube gets, what it would refuse or ignore, and chapters the edit suggests.
        var publish: PublishInfo?
        var publishIssues: [PublishInfo.Issue]
        var suggestedChapters: [Chapter]
        /// The end screen, when the recording has one: when it shows, the speaker's frame,
        /// and each box with the YouTube element chosen for it, to place in YouTube Studio.
        var endScreen: JSONValue?
        /// What was transcribed, when it has been; the words themselves come from `transcript`.
        var transcript: TranscriptSummary?
        /// What exports do with its captions, and where they come from.
        var captions: CaptionsState
        /// Its Shorts: vertical 1080×1920 versions of parts of it.
        var shorts: [ShortState]
        /// The screen recording shown with it, and the layouts; nil when it has none.
        var screen: ScreenState?
        /// The music under its voice; nil when it has none.
        var music: MusicState?
        /// The sound effects on its graphics; nil when it has none.
        var sounds: SoundsState?
        /// Changes switched off in the inspector: kept, but out of the player and exports.
        var switchedOff: [String]
    }
    /// A Short as an agent needs it. Times are edited-recording seconds; `graphics` are the
    /// ones that show in it, in its own time from 0, and `window` is the 9:16 part of the
    /// picture it shows (source pixels), set or the default.
    struct ShortState: Encodable {
        struct Shown: Encodable { var id: UUID; var kind: String; var start: Double; var end: Double; var placed: Bool }
        var id: UUID
        var start: Double, end: Double, length: Double
        var window: WireRect
        var windowSet: Bool
        var width = 1080, height = 1920
        var title: String, description: String, tags: [String]
        var panels: String, captions: String
        /// 1 fills the frame; lower is zoomed out, with `picture` (the window widened) at the top.
        var zoom: Double
        /// "top": the screen across the top and the speaker below; "off": only the speaker.
        var screen: String
        var picture: WireRect
        var cover: Double?
        var hidden: [UUID]
        var placements: [String: GraphicTransform]
        var graphics: [Shown]
        /// Whether its captions are burned in, and how many show.
        var captionsBurned: Bool
        var captionCount: Int
        var issues: [PublishInfo.Issue]
    }
    struct TranscriptSummary: Encodable {
        var model: String, language: String, words: Int
        /// Words still in the edit.
        var keptWords: Int
    }
    /// use: burnIn, upload or off; source: file (its caption file), transcript, or nil (none).
    struct CaptionsState: Encodable { var use: String; var source: String? }
    /// The project's auto edit answers (the defaults until `saved`), whether this Mac can
    /// transcribe (whisper: ready or needsWhisper), and which models it has.
    struct AutoEdit: Encodable {
        struct Model: Encodable { var id: String; var label: String; var size: String; var downloaded: Bool; var englishOnly: Bool }
        var options: AutoEditOptions
        var saved: Bool
        var whisper: String
        var whisperDetail: String?
        var models: [Model]
    }
    /// Edited-recording seconds; `weight` follows `VideoBlurEffect.weight`.
    struct Effect: Encodable {
        var id: UUID, start: Double, end: Double, duration: Double
        var amount: Double, mix: Double, fadeIn: Double, fadeOut: Double, enabled: Bool
    }
    struct Marker: Encodable { var id: UUID; var time: Double; var label: String; var color: String }
    /// A recording's colour as stored, plus what the app makes of it: the profile in
    /// effect and whether that was chosen or inferred, the conversion table and whether
    /// this Mac has it, and why a requested correction cannot run.
    struct Color: Encodable {
        struct Conversion: Encodable { var sha256: String; var name: String; var official: Bool; var available: Bool }
        var inputProfile: String
        var profileInEffect: String?
        var profileChosen: Bool
        var evidence: String
        var conversion: Conversion?
        var correctionEnabled: Bool
        var exposureEV: Double, warmth: Double, contrast: Double, saturation: Double
        var algorithmVersion: Int
        var problem: String?
    }
    struct MovieEntry: Encodable { var clip: UUID; var offset: Double; var duration: Double }
    struct Movie: Encodable { var canvas: String; var duration: Double; var clips: [MovieEntry] }
    struct Selection: Encodable {
        /// `section` is the one last clicked; `sections` is everything selected, in
        /// timeline order.
        var clip: UUID?, section: UUID?, sections: [UUID], zoom: UUID?, blurArea: UUID?, effect: UUID?, marker: UUID?, graphic: UUID?
        var short: UUID?
        /// frame (the edit frame), preview (the 16:9 edit playing) or short (the selected Short, 9:16).
        var viewer: String
        var playhead: Double, movieMode: Bool, movieTime: Double
        /// The part of the window showing: library or studio. `idea` is the idea selected on the Library page.
        var module: String
        var idea: UUID?
    }
    /// The project's Why notes, Video.md beside it once saved, and how many steps its
    /// history holds.
    struct Notes: Encodable { var why: String?; var videoNotes: String?; var changes: Int; var recent: [ChangeLogEntry] }
    /// The Library idea the open project was made from (method library has the rest).
    struct Idea: Encodable { var id: UUID; var title: String; var topic: String? }
    struct Busy: Encodable {
        var exporting: Bool, interactionInProgress: Bool, agentsPaused: Bool, runningJobs: [UUID]
    }
    struct History: Encodable { var undo: AgentHistoryStep?; var redo: AgentHistoryStep? }
    /// Whether exports can draw graphics here: ready, needsNode, needsDownload (the owner
    /// downloads HyperFrames from the Export sheet), or unknown until the app has checked.
    struct GraphicsRenderer: Encodable { var status: String; var detail: String?; var version: String }

    var sessionID: UUID
    var projectID: UUID
    var revision: Int
    var title: String
    var file: String?
    var unsaved: Bool
    var busy: Busy
    var history: History
    var selection: Selection
    var idea: Idea?
    var notes: Notes
    var settings: JSONValue
    var graphicsRenderer: GraphicsRenderer
    var autoEdit: AutoEdit
    var movie: Movie
    var clips: [Clip]
}

struct AgentEventRecord: Encodable {
    var sequence: Int
    var revision: Int
    var kind: String
    var origin: String
    var originKind: String
    var label: String
    var transactionID: UUID?
    var clips: [UUID]
}

struct AgentEventsPage: Encodable {
    var events: [AgentEventRecord]
    /// Pass as `after` to continue.
    var next: Int
    var latest: Int
    var revision: Int
    var more: Bool
}

/// Long-running work an agent asked for. Polled with `job`; finishing also lands in the
/// event feed.
struct AgentJob: Encodable {
    var id: UUID
    var kind: String
    var status: String
    var progress: Double?
    /// The document revision the job read. A result is about that revision only.
    var sourceRevision: Int
    var clip: UUID?
    var origin: String
    var createdAt: Date
    var finishedAt: Date?
    var result: JSONValue?
    var error: AgentErrorBody?
}

struct AgentPreview: Encodable {
    var path: String
    var revision: Int
    var clip: UUID
    var time: Double
    var sourceTime: Double
    var width: Int
    var height: Int
    var cropped: Bool
    /// True when the colour stage was left out on request.
    var original: Bool
    /// True when rendered as Preview plays it, effects and zooms included.
    var composed: Bool
    /// In a composed preview, the graphics showing at that time and where each is drawn,
    /// in this image's pixels.
    var graphics: [PreviewGraphic]?
    /// A Short's preview: its id. `time` is then seconds into the Short and the picture 1080×1920.
    var short: UUID?
}

struct PreviewGraphic: Encodable {
    var id: UUID
    var kind: String
    var rect: WireRect
}

/// A recording's words, captions and stumbles, for `transcript`.
struct AgentTranscript: Encodable {
    struct Word: Encodable {
        var text: String; var start: Double; var end: Double; var editedStart: Double?
        enum CodingKeys: String, CodingKey { case text, start, end, editedStart }
        /// editedStart is written as null for a cut word, not left out.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text); try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end); try container.encode(editedStart, forKey: .editedStart)
        }
    }
    struct Line: Encodable { var start: Double; var end: Double; var text: String }
    struct Found: Encodable {
        var kind: String; var text: String; var start: Double; var end: Double; var editedStart: Double?
        enum CodingKeys: String, CodingKey { case kind, text, start, end, editedStart }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind); try container.encode(text, forKey: .text)
            try container.encode(start, forKey: .start); try container.encode(end, forKey: .end)
            try container.encode(editedStart, forKey: .editedStart)
        }
    }
    var clip: UUID
    var model: String
    var language: String
    var text: String
    /// Source seconds; editedStart is where the word now plays, null when it was cut.
    var words: [Word]
    /// Edited seconds, as uploaded or burned in when captions come from the transcript.
    var captions: [Line]
    var stumbles: [Found]
}

/// What an auto edit found, and did.
struct AutoEditResult: Encodable {
    struct Cut: Encodable {
        var sectionID: UUID, start: Double, end: Double, editedStart: Double, duration: Double
        /// pause, filler, repeat, restart, fragment.
        var reasons: [String]
        var removes: String
    }
    struct Section: Encodable { var id: UUID; var start: Double; var end: Double; var speed: Double }
    struct Settings: Encodable { var captions: String; var audio: String }
    var kind = "autoEdit"
    var style: String
    var applied: Bool
    var transcribed: Bool
    var hasTranscript: Bool
    var cuts: [Cut]
    var proposedSections: [Section]
    var savedSeconds: Double
    /// What exports do once applied: captions (burnIn, upload, off) and audio.
    var settings: Settings
    var note: String?
    var transactionID: UUID?
    var revision: Int?
    var removedZooms: [UUID]?
    var removedEffects: [UUID]?
    var removedMarkers: [UUID]?
    var removedGraphics: [UUID]?

    init(_ plan: AutoEditPlan, applied: Bool, transcribed: Bool, note: String?) {
        style = plan.style.rawValue
        self.applied = applied; self.transcribed = transcribed; self.note = note
        hasTranscript = plan.hasTranscript || transcribed
        cuts = plan.includedCuts.map {
            Cut(sectionID: $0.segmentID, start: $0.start, end: $0.end, editedStart: $0.timelineStart, duration: $0.duration,
                reasons: $0.kinds, removes: $0.reason)
        }
        proposedSections = plan.sections.map { Section(id: $0.id, start: $0.start, end: $0.end, speed: $0.speed) }
        savedSeconds = plan.savedSeconds
        settings = Settings(captions: (plan.settings.captions ?? .off).rawValue, audio: plan.settings.audio.rawValue)
    }
}

struct AgentSaveResult: Encodable {
    var path: String
    var projectID: UUID
    var revision: Int
    /// True when a copy was written and the open project still points at its own file.
    var copy: Bool
}

// MARK: - Answering

@MainActor
extension AppModel {
    static let agentMethods = ["manual", "catalog", "sessions", "state", "apply", "events", "undo", "redo", "save", "preview", "thumbnail",
                               "analyze", "export", "job", "cancel", "reveal", "transcript", "transcribe", "autoEdit", "logos", "setLogo", "removeLogo",
                               "sounds", "setSound", "removeSound",
                               "library", "libraryApply", "libraryUndo", "libraryRedo", "scanFolder", "style"]

    /// Answers one request line with one response line. Never throws: every failure is
    /// a structured error response.
    func handleAgentRequest(_ data: Data, instanceID: UUID) async -> Data {
        let request: AgentRequest
        do { request = try AgentProtocol.decoder.decode(AgentRequest.self, from: data) } catch {
            return agentResponse(Result<AgentEmpty, EditError>.failure(EditError(code: .invalidRequest,
                message: "That is not a valid protocol \(AgentProtocol.version) request: \(Self.describe(error))")), instanceID)
        }
        if let version = request.protocolVersion, version != AgentProtocol.version {
            return agentResponse(Result<AgentEmpty, EditError>.failure(EditError(code: .unsupportedCapability,
                message: "This YamVideo speaks protocol \(AgentProtocol.version), not \(version).")), instanceID)
        }
        if request.method != "hello", request.method != "sessions" { noteAgentClient(request) }
        switch request.method {
        case "hello", "sessions":
            return agentResponse(.success(AgentSessions(sessions: [agentSessionInfo(instanceID)])), instanceID)
        case "catalog":
            return agentResponse(.success(AgentCatalog.current), instanceID)
        case "manual":
            return agentResponse(AgentsManual.text.map { AgentsManual.Reply(text: $0, path: AgentsManual.url?.path) }
                .map(Result<AgentsManual.Reply, EditError>.success)
                ?? .failure(EditError(code: .missingMedia, message: "The Agents Manual is missing from this build.")), instanceID)
        case "state":
            if let refusal = checkSession(request, required: false) { return agentResponse(Result<AgentEmpty, EditError>.failure(refusal), instanceID) }
            await measureGraphicsForBubble()
            return agentResponse(.success(agentState()), instanceID)
        case "events": return agentResponse(agentEvents(request), instanceID)
        case "preview": return agentResponse(await agentPreview(request), instanceID)
        case "thumbnail": return agentResponse(await agentThumbnail(request), instanceID)
        case "job": return agentResponse(agentJob(request), instanceID)
        case "reveal": return agentResponse(agentReveal(request), instanceID)
        case "transcript": return agentResponse(agentTranscript(request), instanceID)
        case "logos": return agentResponse(Result<AgentLogos, EditError>.success(Self.agentLogos()), instanceID)
        case "sounds": return agentResponse(Result<AgentSounds, EditError>.success(Self.agentSounds()), instanceID)
        case "library": return agentResponse(Result<AgentLibrary, EditError>.success(agentLibrary()), instanceID)
        case "scanFolder": return agentResponse(agentScanFolder(request), instanceID)
        case "style": refreshStyleFromDisk(); return agentResponse(Result<AgentStyle, EditError>.success(agentStyle()), instanceID)
        case "libraryApply", "libraryUndo", "libraryRedo":
            // Library commands carry fields project commands do not, so a retry is matched
            // on the whole request, with its keys in a fixed order.
            let canonical = (try? AgentProtocol.decoder.decode(JSONValue.self, from: data)).flatMap { try? AgentProtocol.encoder.encode($0) } ?? data
            return await idempotent(request, instanceID: instanceID, payload: canonical) {
                switch request.method {
                case "libraryApply": return self.agentResponse(self.agentLibraryApply(request, data: data), instanceID)
                default: return self.agentResponse(self.agentLibraryHistory(request, redo: request.method == "libraryRedo"), instanceID)
                }
            }
        case "apply", "undo", "redo", "save", "export", "analyze", "cancel", "transcribe", "autoEdit", "setLogo", "removeLogo",
             "setSound", "removeSound":
            return await idempotent(request, instanceID: instanceID) {
                switch request.method {
                case "apply": return self.agentResponse(await self.agentApply(request), instanceID)
                case "undo", "redo": return self.agentResponse(self.agentHistory(request), instanceID)
                case "save": return self.agentResponse(self.agentSave(request), instanceID)
                case "export": return self.agentResponse(self.agentExport(request), instanceID)
                case "analyze": return self.agentResponse(self.agentAnalyze(request), instanceID)
                case "transcribe": return self.agentResponse(self.agentTranscribe(request), instanceID)
                case "autoEdit": return self.agentResponse(self.agentAutoEdit(request), instanceID)
                case "setLogo": return self.agentResponse(self.agentSetLogo(request), instanceID)
                case "removeLogo": return self.agentResponse(self.agentRemoveLogo(request), instanceID)
                case "setSound": return self.agentResponse(await self.agentSetSound(request), instanceID)
                case "removeSound": return self.agentResponse(self.agentRemoveSound(request), instanceID)
                default: return self.agentResponse(self.agentCancel(request), instanceID)
                }
            }
        default:
            return agentResponse(Result<AgentEmpty, EditError>.failure(EditError(code: .unsupportedCapability,
                message: "Unknown method \"\(request.method)\". Methods: \(Self.agentMethods.joined(separator: ", ")).")), instanceID)
        }
    }

    private func agentResponse<T: Encodable>(_ result: Result<T, EditError>, _ instanceID: UUID) -> Data {
        let envelope: AgentResponseEnvelope<T>
        switch result {
        case .success(let value):
            envelope = AgentResponseEnvelope(instanceID: instanceID, ok: true, result: value, error: nil)
        case .failure(let error):
            let withRevision: Set<EditError.Code> = [.revisionConflict, .wrongSession, .historyConflict, .resyncRequired]
            envelope = AgentResponseEnvelope(instanceID: instanceID, ok: false, result: nil, error: AgentErrorBody(
                code: error.code.rawValue, message: error.message, retryable: error.retryable,
                currentRevision: withRevision.contains(error.code) ? revision : nil))
        }
        return (try? AgentProtocol.encoder.encode(envelope))
            ?? AgentProtocol.errorLine(code: "internal_error", message: "Could not encode the response.", instanceID: instanceID)
    }

    /// Edits are remembered by request ID for the whole session: a retry with the same
    /// payload gets the original answer — before any revision check — and is never
    /// applied twice; reusing an ID for something else is refused.
    private func idempotent(_ request: AgentRequest, instanceID: UUID, payload: Data? = nil, _ body: () async -> Data) async -> Data {
        func refuse(_ code: EditError.Code, _ message: String) -> Data {
            agentResponse(Result<AgentEmpty, EditError>.failure(EditError(code: code, message: message)), instanceID)
        }
        guard let id = request.requestID, !id.isEmpty, id.count <= 128 else {
            return refuse(.invalidRequest, "Edits need a requestID (up to 128 characters) so a retry is never applied twice.")
        }
        let hash = Self.fingerprint(payload ?? (try? AgentProtocol.encoder.encode(request)) ?? Data())
        if let record = agentRequests[id] {
            return record.payloadHash == hash ? record.response
                : refuse(.requestIDReused, "Request ID \(id) was already used for a different request in this session.")
        }
        guard !agentPendingRequests.contains(id) else {
            return refuse(.requestInProgress, "Request \(id) is still being answered; ask again for its result.")
        }
        guard agentRequests.count < AgentProtocol.maxRequestIDs else {
            return refuse(.sessionFull, "This session has answered \(AgentProtocol.maxRequestIDs) edits. Reopen the project to start a new session.")
        }
        let session = editSession.sessionID
        agentPendingRequests.insert(id)
        let response = await body()
        agentPendingRequests.remove(id)
        // A request that started a new session belongs to the old one.
        if editSession.sessionID == session { agentRequests[id] = AgentRequestRecord(payloadHash: hash, response: response) }
        return response
    }

    func checkSession(_ request: AgentRequest, required: Bool) -> EditError? {
        if required, request.sessionID == nil || request.projectID == nil {
            return EditError(code: .invalidRequest, message: "Include sessionID and projectID from `state`.")
        }
        if let session = request.sessionID, session != editSession.sessionID {
            return EditError(code: .wrongSession, message:
                "That session has ended: the project was opened, reopened or replaced. Read state again.")
        }
        if let project = request.projectID, project != projectID {
            return EditError(code: .wrongSession, message: "A different project is open now. Read state again.")
        }
        return nil
    }

    /// Remembers who has been talking to the app, for the Local agents panel. Discovery
    /// (`sessions`) is not activity, so it is not counted.
    private func noteAgentClient(_ request: AgentRequest) {
        let name = agentOrigin(request).label
        let action = request.label.map { String($0.prefix(80)) } ?? request.method
        agentClients.removeAll { $0.name == name }
        agentClients.insert(AgentClient(name: name, lastSeen: Date(), lastAction: action), at: 0)
        if agentClients.count > 12 { agentClients.removeLast(agentClients.count - 12) }
    }

    func agentOrigin(_ request: AgentRequest) -> EditOrigin {
        let name = String((request.client ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(name.prefix(40))
        // "You" is how the owner's own steps read; an agent cannot take that name.
        return .agent(trimmed.isEmpty || trimmed.caseInsensitiveCompare("You") == .orderedSame ? "Local agent" : trimmed)
    }

    private func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw EditError(code: .invalidRequest, message: "This request needs \(what).") }
        return value
    }

    static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, let context):
                return "missing \(([key] + context.codingPath.reversed()).reversed().map(\.stringValue).joined(separator: "."))"
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            @unknown default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Reading

    private func agentSessionInfo(_ instanceID: UUID) -> AgentSessionInfo {
        AgentSessionInfo(instanceID: instanceID, processID: getpid(), sessionID: editSession.sessionID,
                         projectID: projectID, revision: revision,
                         title: projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled",
                         file: projectURL?.path, unsaved: hasUnsavedChanges, agentsPaused: agentsPaused,
                         exportInProgress: isConverting, interactionInProgress: editSession.gesture != nil,
                         methods: Self.agentMethods, commands: WireCommand.types)
    }

    private func historyStep(_ entry: EditHistory?) -> AgentHistoryStep? {
        entry.map { AgentHistoryStep(transactionID: $0.transactionID, label: $0.name, origin: $0.origin.label,
                                     originKind: $0.origin.isHuman ? "human" : "agent") }
    }

    /// The committed document — during an owner's drag, the state before it began — with
    /// stable IDs, edited timing and what each recording is doing.
    func agentState() -> AgentState {
        let document = committedProject
        let live = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let clips = document.clips.map { clip -> AgentState.Clip in
            var offset = 0.0
            var sections: [AgentState.Section] = []
            let gaps = clip.gaps?.lengths ?? [:]
            for segment in clip.timeline.segments {
                sections.append(.init(id: segment.id, start: segment.start, end: segment.end, speed: segment.speed,
                                      editedStart: offset, editedDuration: segment.duration, gapBefore: gaps[segment.id]))
                offset += segment.duration
            }
            let (status, detail): (String, String?) = {
                switch live[clip.id]?.status ?? .ready {
                case .probing: return ("probing", nil)
                case .ready: return ("ready", nil)
                case .converting: return ("exporting", nil)
                case .done(let url): return ("exported", url.path)
                case .failed(let message): return ("failed", message)
                }
            }()
            return AgentState.Clip(
                id: clip.id, name: clip.url.lastPathComponent, path: clip.url.path, status: status, statusDetail: detail,
                media: clip.info.map { .init(width: $0.width, height: $0.height, duration: $0.duration, fps: $0.fps,
                                             fpsExpression: $0.fpsExpression, hasAudio: $0.hasAudio, hdr: $0.hdrLabel) },
                editedDuration: clip.timeline.duration, includedInMovie: clip.includedInMovie ?? true,
                crop: clip.crop.map(WireRect.init), aspect: clip.aspectLabel, subtitles: clip.subtitles?.path,
                sections: sections, blurAreas: clip.blurRegions.map { .init(id: $0.id, rect: WireRect($0.rect), start: $0.start, end: $0.end) },
                zooms: clip.zoomShots.map { .init(id: $0.id, start: $0.start, hold: $0.hold, level: $0.level, end: $0.end,
                                                  target: WirePoint($0.target)) },
                color: clip.info.map { colorState(clip, info: $0, settings: document.settings) },
                blurEffects: (clip.blurEffects ?? []).map {
                    .init(id: $0.id, start: $0.start, end: $0.end, duration: $0.duration, amount: $0.amount, mix: $0.mix,
                          fadeIn: $0.fadeIn, fadeOut: $0.fadeOut, enabled: $0.isEnabled)
                },
                markers: (clip.markers ?? []).map { .init(id: $0.id, time: $0.time, label: $0.label, color: $0.color.rawValue) },
                graphics: clip.graphics,
                publish: clip.publish,
                publishIssues: clip.info == nil ? [] : (clip.publish ?? PublishInfo()).issues(duration: clip.timeline.duration,
                                                                                               graphics: clip.graphics,
                                                                                               music: clip.isOn(.music) ? clip.music : nil,
                                                                                               sounds: clip.isOn(.graphics) ? clip.item().usedSounds : []),
                suggestedChapters: clip.info == nil ? [] : PublishInfo.suggestedChapters(markers: clip.markers ?? [], graphics: clip.graphics,
                                                                                         duration: clip.timeline.duration),
                endScreen: EndScreenPlan(graphics: clip.graphics, publish: clip.publish, duration: clip.timeline.duration)?.json,
                transcript: clip.transcript.map {
                    .init(model: $0.model, language: $0.language, words: $0.words.count, keptWords: $0.keptWords(clip.timeline).count)
                },
                captions: .init(use: document.settings.captionUse(hasFile: clip.subtitles != nil).rawValue,
                                source: clip.item().captionsSource(document.settings)),
                shorts: Self.shortStates(clip, settings: document.settings),
                screen: Self.screenState(clip, overBubble: bubbleOverlaps(clip)),
                music: Self.musicState(clip),
                sounds: Self.soundsState(clip),
                switchedOff: (clip.switchedOff ?? []).map(\.rawValue))
        }
        var movieOffset = 0.0
        var movieClips: [AgentState.MovieEntry] = []
        for clip in document.clips where clip.includedInMovie ?? true {
            movieClips.append(.init(clip: clip.id, offset: movieOffset, duration: clip.timeline.duration))
            movieOffset += clip.timeline.duration
        }
        return AgentState(
            sessionID: editSession.sessionID, projectID: projectID, revision: revision,
            title: projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled", file: projectURL?.path,
            unsaved: hasUnsavedChanges,
            busy: .init(exporting: isConverting, interactionInProgress: editSession.gesture != nil, agentsPaused: agentsPaused,
                        runningJobs: agentJobs.values.filter { $0.status == "running" }.map(\.id)),
            history: .init(undo: historyStep(undoEntries.last), redo: historyStep(redoEntries.last)),
            selection: .init(clip: selection, section: selectedSegmentID,
                             sections: selectedItem.map { sectionSelection.ordered(in: $0.timeline).map(\.id) } ?? [],
                             zoom: selectedShotID, blurArea: selectedRegionID, effect: selectedEffectID, marker: selectedMarkerID, graphic: selectedGraphicID,
                             short: selectedShortID, viewer: viewer == .short ? "short" : viewer == .preview ? "preview" : "frame",
                             playhead: previewTime, movieMode: isMovieMode, movieTime: movieTime,
                             module: module.rawValue, idea: selectedIdeaID),
            idea: openProjectIdea.map { .init(id: $0.id, title: $0.title, topic: $0.topic) },
            notes: .init(why: projectNotes, videoNotes: videoNotesFile?.path, changes: changeLog.count, recent: Array(changeLog.suffix(10))),
            settings: (try? JSONValue.from(document.settings)) ?? .null,
            graphicsRenderer: graphicsRendererState,
            autoEdit: .init(options: document.autoEdit ?? AutoEditOptions(), saved: document.autoEdit != nil,
                            whisper: Whisper.cliPath == nil ? "needsWhisper" : "ready",
                            whisperDetail: Whisper.cliPath == nil ? Whisper.missingMessage : nil,
                            models: TranscriptModel.allCases.map {
                                .init(id: $0.rawValue, label: $0.label, size: $0.sizeLabel, downloaded: Whisper.hasModel($0), englishOnly: $0.englishOnly)
                            }),
            movie: .init(canvas: (document.movieSettings ?? MovieSettings()).canvas.rawValue, duration: movieOffset, clips: movieClips),
            clips: clips)
    }

    private var graphicsRendererState: AgentState.GraphicsRenderer {
        switch graphicsRenderer {
        case .ready?: return .init(status: "ready", detail: nil, version: HyperFrames.version)
        case .needsNode(let why)?: return .init(status: "needsNode", detail: why, version: HyperFrames.version)
        case .needsDownload?: return .init(status: "needsDownload", detail: HyperFrames.missingMessage, version: HyperFrames.version)
        case nil: return .init(status: "unknown", detail: nil, version: HyperFrames.version)
        }
    }

    private func colorState(_ clip: ProjectClip, info: MediaInfo, settings: ExportSettings) -> AgentState.Color {
        let color = clip.color ?? ClipColorSettings()
        let name = clip.url.lastPathComponent
        let inferred = info.inferredColorProfile(fileName: name)
        let chosen = color.inputProfile != .auto
        return AgentState.Color(
            inputProfile: color.inputProfile.rawValue,
            profileInEffect: chosen ? color.inputProfile.rawValue : inferred.profile?.rawValue,
            profileChosen: chosen,
            evidence: chosen ? "Chosen for this recording." : inferred.evidence,
            conversion: color.technicalLUT.map { .init(sha256: $0.sha256, name: $0.originalName, official: LUTStore.isOfficial($0),
                                                       available: LUTStore.has($0.sha256)) },
            correctionEnabled: color.correctionEnabled,
            exposureEV: color.exposureEV, warmth: color.warmth, contrast: color.contrast, saturation: color.saturation,
            algorithmVersion: color.algorithmVersion,
            problem: clip.item().colorStage(settings).problem)
    }

    private func agentEvents(_ request: AgentRequest) -> Result<AgentEventsPage, EditError> {
        let after = max(0, request.after ?? 0)
        let limit = min(max(1, request.limit ?? AgentProtocol.eventPageLimit), AgentProtocol.eventPageLimit)
        let events = editSession.events
        let latest = editSession.nextSequence - 1
        if let oldest = events.first, after < oldest.sequence - 1 {
            return .failure(EditError(code: .resyncRequired, message:
                "Events after \(after) are no longer kept. Read state again, then continue from \(latest)."))
        }
        let page = events.filter { $0.sequence > after }.prefix(limit).map {
            AgentEventRecord(sequence: $0.sequence, revision: $0.revision, kind: $0.kind.rawValue, origin: $0.origin.label,
                             originKind: $0.origin.isHuman ? "human" : "agent", label: $0.label,
                             transactionID: $0.transactionID, clips: $0.clips)
        }
        let next = page.last?.sequence ?? after
        return .success(AgentEventsPage(events: Array(page), next: next, latest: latest, revision: revision, more: next < latest))
    }

    /// Movie time to (recording, recording time), through the same order and edited
    /// durations the movie uses.
    private func movieLocation(_ time: Double, in document: VideoProject) throws -> (UUID, Double) {
        guard time.isFinite, time >= 0 else { throw EditError.invalid("Movie time must be a finite number from 0.") }
        var offset = 0.0
        let included = document.clips.filter { $0.includedInMovie ?? true }
        for (index, clip) in included.enumerated() {
            let duration = clip.timeline.duration
            if time < offset + duration || index == included.count - 1 && time <= offset + duration {
                return (clip.id, time - offset)
            }
            offset += duration
        }
        throw EditError.invalid("Movie time \(time) is past the end of the movie (\(offset) s).")
    }

    // MARK: Editing

    private func agentApply(_ request: AgentRequest) async -> Result<AgentReceipt, EditError> {
        if let refusal = checkSession(request, required: true) { return .failure(refusal) }
        do {
            let expected = try require(request.expectedRevision, "expectedRevision")
            let wire = try require(request.commands, "commands")
            guard !wire.isEmpty, wire.count <= AgentProtocol.maxCommands else {
                throw EditError(code: .invalidRequest, message: "Send 1 to \(AgentProtocol.maxCommands) commands per request.")
            }
            // Media is probed before anything is decided; the revision is checked only at
            // commit, so a probe can never apply over an edit made while it ran.
            var probed: [String: MediaInfo] = [:]
            for path in Set(wire.flatMap(\.mediaPaths)) {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw EditError(code: .missingMedia, message: "No file at \(url.path).")
                }
                do { probed[path] = try await FFmpeg.probe(url: url) } catch {
                    throw EditError(code: .missingMedia, message: "\(url.lastPathComponent) could not be read as video: \(error.localizedDescription)")
                }
            }
            // Tables are read and checked the same way. A good one is kept in the table
            // store even if the edit is then refused or only a dry run: the store holds
            // files by content, not project state.
            var tables: [String: LUTAssetRef] = [:]
            for path in Set(wire.flatMap(\.lutPaths)) {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw EditError(code: .missingMedia, message: "No file at \(url.path).")
                }
                do { tables[path] = try LUTStore.importTable(at: url, role: .pocket3DLogMToRec709) } catch {
                    throw EditError.invalid("\(url.lastPathComponent) cannot be used as a conversion: \(error.localizedDescription)")
                }
            }
            let document = committedProject
            // Music is measured the same way: each file's length and loudness, and the voice of
            // a recording that has no music yet.
            var music: [String: (duration: Double, loudness: Double)] = [:]
            for path in Set(wire.flatMap(\.musicPaths)) {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                do { music[path] = try await FFmpeg.measureMusic(url) } catch {
                    throw EditError(code: .missingMedia, message: error.localizedDescription)
                }
            }
            var voices: [UUID: Double] = [:]
            for command in wire where command.type == "addMusic" || command.type == "setSounds" {
                guard let id = command.clipID, voices[id] == nil,
                      let clip = document.clips.first(where: { $0.id == id }), clip.info?.hasAudio == true,
                      command.type == "addMusic" ? clip.music == nil : clip.sounds == nil else { continue }
                do { voices[id] = try await FFmpeg.integratedLoudness(of: clip.url) } catch {
                    throw EditError(code: .missingMedia, message: error.localizedDescription)
                }
            }
            // A Short asked to be centred on the speaker is looked at with Vision first.
            var speakers: [Int: CGRect] = [:]
            for (index, command) in wire.enumerated() where command.short?["window"] == .string("speaker") {
                speakers[index] = try await speakerWindow(for: command, in: document)
            }
            // A screen's bubble asked to sit on the speaker, or a first screen, is looked at
            // with Vision first too.
            var faces: [Int: CGPoint] = [:]
            var borders: [Int: CGRect] = [:]
            for (index, command) in wire.enumerated() {
                if let face = try await speakerFace(for: command, in: document) { faces[index] = face }
                if let border = try await screenBorder(for: command, in: document) { borders[index] = border }
            }
            let commands = try wire.enumerated().map { index, command in
                try resolve(command, in: document, probed: probed, tables: tables, speaker: speakers[index], face: faces[index],
                            border: borders[index], music: music, voices: voices, origin: agentOrigin(request))
            }
            let label = request.label.map { String($0.prefix(80)) }
            let result = perform(commands, label: label, origin: agentOrigin(request), expectedRevision: expected,
                                 dryRun: request.dryRun ?? false)
            return result.map {
                AgentReceipt(revision: $0.revision, transactionID: $0.transactionID, changed: $0.changed,
                             dryRun: request.dryRun ?? false, createdIDs: $0.createdIDs, removedZooms: $0.removedZooms,
                             removedGraphics: $0.removedGraphics, removedShorts: $0.removedShorts, removedLayouts: $0.removedLayouts,
                             affectedClips: $0.affectedClips)
            }
        } catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid(error.localizedDescription)) }
    }

    /// One wire command as an `EditCommand`, against the committed document.
    private func resolve(_ wire: WireCommand, in document: VideoProject, probed: [String: MediaInfo],
                         tables: [String: LUTAssetRef] = [:], speaker: CGRect? = nil, face: CGPoint? = nil,
                         border: CGRect? = nil, music: [String: (duration: Double, loudness: Double)] = [:],
                         voices: [UUID: Double] = [:], origin: EditOrigin = .human) throws -> EditCommand {
        func field<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw EditError.invalid("\(wire.type) needs \(name).") }
            return value
        }
        func record(_ id: UUID) throws -> ProjectClip {
            guard let clip = document.clips.first(where: { $0.id == id }) else {
                throw EditError.notFound("No recording \(id) in this project.")
            }
            return clip
        }
        /// A recording time, or a movie time mapped to its recording when asked for.
        func placed(_ time: Double) throws -> (UUID, Double) {
            switch wire.timeSpace ?? "recording" {
            case "recording": return (try field(wire.clipID, "clipID"), time)
            case "movie":
                let (clip, local) = try movieLocation(time, in: document)
                if let named = wire.clipID, named != clip {
                    throw EditError.invalid("Movie time \(time) falls in recording \(clip), not \(named).")
                }
                return (clip, local)
            default: throw EditError.invalid("timeSpace must be \"recording\" or \"movie\".")
            }
        }
        func markerColor(_ name: String?) throws -> TimelineMarker.Color? {
            guard let name else { return nil }
            guard let color = TimelineMarker.Color(rawValue: name) else {
                throw EditError.invalid("Unknown marker colour \"\(name)\". Colours: \(TimelineMarker.Color.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return color
        }
        func graphic(_ value: WireGraphic, keeping old: Graphic? = nil) throws -> Graphic {
            var result = old ?? Graphic(id: value.id ?? UUID(), kind: .titleCard, start: 0, end: 0)
            if let name = value.kind {
                guard let kind = GraphicKind(rawValue: name) else {
                    throw EditError.invalid("Unknown graphic kind \"\(name)\". Kinds: \(GraphicKind.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                result.kind = kind
            } else if old == nil { throw EditError.invalid("A new graphic needs a kind.") }
            if result.kind == .endScreen, value.end == nil, value.start != nil || old == nil {
                // An end screen ends where the video does. Without a start it takes the
                // last 20 s, or as much of them as is clear of the other graphics.
                let clip = try record(try field(wire.clipID, "clipID"))
                let duration = clip.timeline.duration
                if let start = value.start {
                    result.start = try placed(start).1
                } else {
                    let others = GraphicsTrack(items: (clip.graphics?.items ?? []).filter { $0.id != result.id })
                    guard let span = others.newEndScreenSpan(duration: duration) else {
                        throw EditError.invalid(String(format: "There is no room for an end screen: YouTube's end screen needs 5 to 20 s at the end of the video (%.2f s) with no other graphic showing. Give start to choose.", duration))
                    }
                    result.start = span.start
                }
                result.end = duration
            } else if let start = value.start {
                let length = (value.end ?? result.end) - (value.end == nil ? result.start : start)
                result.start = try placed(start).1
                result.end = result.start + length
            } else if old == nil { throw EditError.invalid("A new graphic needs start and end.") }
            if old == nil, result.kind == .endScreen, value.props == nil { result.props = EndScreen.defaultProps }
            if let end = value.end, value.start == nil { result.end = end }
            if let props = value.props { result.props = props }
            if let look = value.look {
                switch look {
                case "": result.look = nil
                case "glass", "ink": result.look = GraphicsLook(rawValue: look)
                default: throw EditError.invalid("A graphic's look is \"glass\" or \"ink\".")
                }
            }
            if let place = value.transform {
                var transform = result.transform ?? GraphicTransform()
                if let x = place.x { transform.x = x }
                if let y = place.y { transform.y = y }
                if let scale = place.scale { transform.scale = scale }
                result.transform = transform.isIdentity ? nil : transform
            }
            return result
        }
        /// A kinetic text with words "transcript" gets the words spoken over its time, each
        /// at its edited time.
        func spokenWords(_ graphic: Graphic, on clipID: UUID) throws -> Graphic {
            guard graphic.kind == .kineticText, graphic.props["words"]?.string == "transcript" else { return graphic }
            let clip = try record(clipID)
            guard clip.transcript != nil else {
                throw EditError.invalid("words \"transcript\" needs the recording's transcript; transcribe it first, or give the words.")
            }
            let words = KineticText.words(clip.transcript, timeline: clip.timeline, from: graphic.start, to: graphic.end)
            guard !words.isEmpty else {
                throw EditError.invalid(String(format: "No words are spoken from %.2f to %.2f s; move the kinetic text, or give the words.", graphic.start, graphic.end))
            }
            var filled = graphic
            filled.props["words"] = .array(words)
            return filled
        }
        func checkedImages(_ graphic: Graphic) throws -> Graphic {
            var missing: String?
            JSONValue.object(graphic.props).visit { key, value in
                if key == "image", let path = value.string, missing == nil, !FileManager.default.fileExists(atPath: path) {
                    missing = path
                }
            }
            if let missing { throw EditError(code: .missingMedia, message: "No image at \(missing).") }
            return graphic
        }
        func mergedStyle(_ changes: [String: JSONValue], onto style: GraphicsStyle) throws -> GraphicsStyle {
            let known: Set<String> = ["accent", "panel", "moveVideo", "edge", "look", "size"]
            if let unknown = changes.keys.sorted().first(where: { !known.contains($0) }) {
                throw EditError.invalid("Unknown graphics style key \"\(unknown)\". Keys: accent, panel, moveVideo, edge, look, size.")
            }
            guard case .object(var merged) = try JSONValue.from(style) else { return style }
            for (key, value) in changes { merged[key] = value }
            do {
                var decoded = try AgentProtocol.decoder.decode(GraphicsStyle.self, from: AgentProtocol.encoder.encode(JSONValue.object(merged)))
                // A size of 1 is the template's own: stored as no size at all.
                if let size = decoded.size, abs(size - 1) < 0.0005 { decoded.size = nil }
                return decoded
            } catch {
                throw EditError.invalid("graphicsStyle: panel is shade or solid, look is glass, ink or mix, "
                    + "moveVideo is true or false, edge and size are numbers (size 1 to 1.5, or null) and accent is a colour like #F5C42C.")
            }
        }
        func mergedPublish(_ changes: [String: JSONValue], onto info: PublishInfo) throws -> PublishInfo {
            let known: Set<String> = ["title", "description", "tags", "category", "chapters", "thumbnail", "language", "channel", "design", "endScreen", "test"]
            if let unknown = changes.keys.sorted().first(where: { !known.contains($0) }) {
                throw EditError.invalid("Unknown publish key \"\(unknown)\". Keys: \(known.sorted().joined(separator: ", ")).")
            }
            if case .string(let path)? = changes["thumbnail"] {
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path.hasPrefix("file:") ? (URL(string: path)?.path ?? path) : expanded) else {
                    throw EditError(code: .missingMedia, message: "No image at \(path).")
                }
            }
            if case .string(let path)? = changes["design"]?.object?["image"],
               !FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
                throw EditError(code: .missingMedia, message: "No image at \(path).")
            }
            guard case .object(var merged) = try JSONValue.from(info) else { return info }
            for (key, value) in changes {
                if value == .null { merged.removeValue(forKey: key) }
                else if key == "design" || key == "endScreen" || key == "test", case .object(let patch) = value {
                    // The design's, the end screen's and the test's keys merge too: only those given change.
                    var object = merged[key]?.object ?? [:]
                    for (name, part) in patch { if part == .null { object.removeValue(forKey: name) } else { object[name] = part } }
                    merged[key] = .object(object)
                } else { merged[key] = value }
            }
            do {
                var decoded = try AgentProtocol.decoder.decode(PublishInfo.self, from: AgentProtocol.encoder.encode(JSONValue.object(merged)))
                // The winner of a Test & Compare becomes the thumbnail, unless the thumbnail is given too.
                if case .number? = changes["test"]?.object?["winner"], changes["thumbnail"] == nil { decoded.markWinner(decoded.test?.winner) }
                return decoded
            } catch {
                throw EditError.invalid("publish: title, description, language and channel are text; tags is a list of text; "
                    + "category is one of \(YouTubeCategory.allCases.map(\.rawValue).joined(separator: ", ")); chapters is a list of "
                    + "{time, title}; thumbnail is a path to an image; design has time, title, highlight, tag, accent, image, cutout, outline, outlineWidth, "
                    + "side (\(ThumbnailDesign.Side.allCases.map(\.rawValue).joined(separator: ", "))), background "
                    + "(\(ThumbnailDesign.Background.allCases.map(\.rawValue).joined(separator: ", "))), zoom and place "
                    + "(\(ThumbnailDesign.Place.allCases.map(\.rawValue).joined(separator: ", "))); endScreen has circle "
                    + "(\(EndScreenElements.Circle.allCases.map(\.rawValue).joined(separator: ", "))), channel, message and videos, a list of "
                    + "{kind (\(EndScreenElements.Kind.allCases.map(\.rawValue).joined(separator: ", "))), link, title}; "
                    + "test has versions (B and C: designs), images (paths, A first) and winner (0 is A).")
            }
        }
        func zoom(_ value: WireZoom) -> ZoomShot {
            ZoomShot(id: value.id ?? UUID(), start: value.start, hold: value.hold ?? 2, level: value.level ?? 2,
                     target: value.target.point)
        }

        switch wire.type {
        case "splitSection":
            let (clip, time) = try placed(try field(wire.at, "at"))
            return .splitSection(clip: clip, at: time)
        case "trimSection":
            guard wire.start != nil || wire.end != nil else { throw EditError.invalid("trimSection needs start, end or both.") }
            return .trimSection(clip: try field(wire.clipID, "clipID"), section: try field(wire.sectionID, "sectionID"),
                                start: wire.start, end: wire.end)
        case "deleteSection":
            return .deleteSection(clip: try field(wire.clipID, "clipID"), section: try field(wire.sectionID, "sectionID"))
        case "moveSection":
            return .moveSection(clip: try field(wire.clipID, "clipID"), section: try field(wire.sectionID, "sectionID"),
                                to: try field(wire.index, "index"))
        case "setSectionSpeed":
            return .setSectionSpeed(clip: try field(wire.clipID, "clipID"), section: try field(wire.sectionID, "sectionID"),
                                    speed: try field(wire.speed, "speed"))
        case "replaceSections":
            return .replaceSections(clip: try field(wire.clipID, "clipID"), sections: try field(wire.sections, "sections").map {
                TimelineSegment(id: $0.id ?? UUID(), start: $0.start, end: $0.end, speed: $0.speed ?? 1)
            })
        case "closeGaps":
            let clip = try field(wire.clipID, "clipID")
            let stored = try record(clip)
            guard let section = wire.sectionID else { return .setGaps(clip: clip, gaps: []) }
            guard stored.gaps?.contains(where: { $0.section == section }) == true else {
                throw EditError.notFound("No gap in front of section \(section.uuidString). gapBefore in each section of the state shows the gaps.")
            }
            return .setGaps(clip: clip, gaps: (stored.gaps ?? []).filter { $0.section != section })
        case "setGap":
            let clip = try field(wire.clipID, "clipID")
            let section = try field(wire.sectionID, "sectionID")
            let length = try field(wire.duration, "duration")
            let stored = try record(clip)
            guard stored.timeline.segments.contains(where: { $0.id == section }) else {
                throw EditError.notFound("No section \(section.uuidString) in this recording.")
            }
            var gaps = (stored.gaps ?? []).filter { $0.section != section }
            if length != 0 { gaps.append(SectionGap(section: section, length: length)) }
            return .setGaps(clip: clip, gaps: gaps)
        case "setCrop":
            return .setCrop(clip: try field(wire.clipID, "clipID"), rect: try field(wire.rect, "rect").rect)
        case "setAspect":
            return .setAspect(clip: try field(wire.clipID, "clipID"), preset: try field(wire.preset, "preset"))
        case "setChange":
            let name = try field(wire.change, "change")
            guard let change = SwitchableChange(rawValue: name) else {
                throw EditError.invalid("Unknown change \"\(name)\". Use one of: \(SwitchableChange.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return .setChange(clip: try field(wire.clipID, "clipID"), change: change, on: try field(wire.on, "on"))
        case "addBlurArea":
            // A blur area's start and end are source seconds of the recording, whatever the timeSpace.
            return .addBlurArea(clip: try field(wire.clipID, "clipID"),
                                area: BlurRegion(id: wire.areaID ?? UUID(), rect: try field(wire.rect, "rect").rect,
                                                 start: wire.start, end: wire.end))
        case "updateBlurArea":
            let timed = wire.start != nil || wire.end != nil || wire.whole == true
            return .updateBlurArea(clip: try field(wire.clipID, "clipID"), area: try field(wire.areaID, "areaID"),
                                   rect: wire.rect?.rect,
                                   times: timed ? BlurTimes(start: wire.start, end: wire.end, whole: wire.whole ?? false) : nil)
        case "removeBlurArea":
            return .removeBlurArea(clip: try field(wire.clipID, "clipID"), area: try field(wire.areaID, "areaID"))
        case "replaceBlurAreas":
            return .replaceBlurAreas(clip: try field(wire.clipID, "clipID"), areas: try field(wire.areas, "areas").map {
                BlurRegion(id: $0.id ?? UUID(), rect: $0.rect.rect, start: $0.start, end: $0.end)
            })
        case "addZoom":
            let (clip, start) = try placed(try field(wire.start, "start"))
            return .addZoom(clip: clip, zoom: ZoomShot(id: wire.zoomID ?? UUID(), start: start, hold: wire.hold ?? 2,
                                                       level: wire.level ?? 2, target: try field(wire.target, "target").point))
        case "updateZoom":
            let clipID = try field(wire.clipID, "clipID"), zoomID = try field(wire.zoomID, "zoomID")
            guard var shot = try record(clipID).zoomShots.first(where: { $0.id == zoomID }) else {
                throw EditError.notFound("No zoom \(zoomID) on recording \(clipID).")
            }
            if let start = wire.start { shot.start = try placed(start).1 }
            if let hold = wire.hold { shot.hold = hold }
            if let level = wire.level { shot.level = level }
            if let target = wire.target { shot.target = target.point }
            return .updateZoom(clip: clipID, zoom: shot)
        case "removeZoom":
            return .removeZoom(clip: try field(wire.clipID, "clipID"), zoom: try field(wire.zoomID, "zoomID"))
        case "replaceZooms":
            let clip = try field(wire.clipID, "clipID")
            return .replaceZooms(clip: clip, zooms: try field(wire.zooms, "zooms").map(zoom))
        case "setMovieOrder":
            return .setMovieOrder(try field(wire.order, "order"))
        case "setIncludedInMovie":
            return .setIncludedInMovie(clip: try field(wire.clipID, "clipID"), included: try field(wire.included, "included"))
        case "setMovieCanvas":
            let name = try field(wire.canvas, "canvas")
            guard let canvas = MovieCanvas(rawValue: name) else {
                throw EditError.invalid("canvas must be one of: " + MovieCanvas.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            return .setMovieCanvas(canvas)
        case "setExportSettings":
            return .setExportSettings(try mergedSettings(document.settings, patch: try field(wire.settings, "settings")))
        case "setSubtitles":
            let url = URL(fileURLWithPath: (try field(wire.path, "path") as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EditError(code: .missingMedia, message: "No subtitle file at \(url.path).")
            }
            return .setSubtitles(clip: try field(wire.clipID, "clipID"), url: url)
        case "clearSubtitles":
            return .setSubtitles(clip: try field(wire.clipID, "clipID"), url: nil)
        case "addMedia":
            return .addMedia(try field(wire.paths, "paths").map { path in
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                var clip = ProjectClip(VideoItem(url: url))
                clip.info = probed[path]
                clip.crop = clip.info?.fullFrame
                clip.subtitles = Self.siblingSubtitles(for: url)
                return clip
            })
        case "removeMedia":
            return .removeMedia(clip: try field(wire.clipID, "clipID"))
        case "relinkMedia":
            let path = try field(wire.path, "path")
            guard let info = probed[path] else { throw EditError(code: .missingMedia, message: "Could not read \(path).") }
            return .relinkMedia(clip: try field(wire.clipID, "clipID"),
                                url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), info: info)
        case "setInputProfile":
            let name = try field(wire.profile, "profile")
            guard let profile = ColorInputProfile(rawValue: name) else {
                throw EditError.invalid("Unknown profile \"\(name)\". Profiles: \(ColorInputProfile.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return .setInputProfile(clip: try field(wire.clipID, "clipID"), profile: profile)
        case "importTechnicalLUT":
            let path = try field(wire.path, "path")
            guard let table = tables[path] else { throw EditError(code: .missingMedia, message: "Could not read \(path).") }
            return .setTechnicalLUT(clip: try field(wire.clipID, "clipID"), lut: table)
        case "clearTechnicalLUT":
            return .setTechnicalLUT(clip: try field(wire.clipID, "clipID"), lut: nil)
        case "setColorCorrection":
            return .setColorCorrection(clip: try field(wire.clipID, "clipID"), enabled: try field(wire.enabled, "enabled"))
        case "setColorAdjustments":
            return .setColorAdjustments(clip: try field(wire.clipID, "clipID"), exposureEV: wire.exposureEV,
                                        warmth: wire.warmth, contrast: wire.contrast, saturation: wire.saturation)
        case "resetColorAdjustments":
            return .resetColorAdjustments(clip: try field(wire.clipID, "clipID"))
        case "copyColorAdjustments":
            return .copyColor(from: try field(wire.clipID, "clipID"), to: try field(wire.targets, "targets"),
                              includeInterpretation: wire.includeInterpretation ?? false)
        case "addBlurEffect":
            let (clip, start) = try placed(try field(wire.start, "start"))
            guard wire.end == nil || wire.duration == nil else { throw EditError.invalid("Give end or duration, not both.") }
            let length = try record(clip).timeline.duration
            let end = try wire.end.map { try placed($0).1 } ?? start + (wire.duration ?? min(VideoBlurEffect.defaultDuration, max(0, length - start)))
            // Default fades shrink to fit a short effect; fades you give are kept or refused.
            let room = max(0, end - start) / 2
            return .addBlurEffect(clip: clip, effect: VideoBlurEffect(
                id: wire.effectID ?? UUID(), start: start, end: end, amount: wire.amount ?? VideoBlurEffect.defaultAmount,
                mix: wire.mix ?? 1, fadeIn: wire.fadeIn ?? min(VideoBlurEffect.defaultFade, room),
                fadeOut: wire.fadeOut ?? min(VideoBlurEffect.defaultFade, room), isEnabled: wire.enabled ?? true))
        case "updateBlurEffect":
            let clipID = try field(wire.clipID, "clipID"), effectID = try field(wire.effectID, "effectID")
            guard var effect = (try record(clipID).blurEffects ?? []).first(where: { $0.id == effectID }) else {
                throw EditError.notFound("No blur effect \(effectID) on recording \(clipID).")
            }
            guard wire.end == nil || wire.duration == nil else { throw EditError.invalid("Give end or duration, not both.") }
            let length = effect.duration
            if let start = wire.start { effect.start = try placed(start).1; effect.end = effect.start + length }
            if let end = wire.end { effect.end = try placed(end).1 }
            if let duration = wire.duration { effect.end = effect.start + duration }
            if let amount = wire.amount { effect.amount = amount }
            if let mix = wire.mix { effect.mix = mix }
            if let fadeIn = wire.fadeIn { effect.fadeIn = fadeIn }
            if let fadeOut = wire.fadeOut { effect.fadeOut = fadeOut }
            if let enabled = wire.enabled { effect.isEnabled = enabled }
            return .updateBlurEffect(clip: clipID, effect: effect)
        case "removeBlurEffect":
            return .removeBlurEffect(clip: try field(wire.clipID, "clipID"), effect: try field(wire.effectID, "effectID"))
        case "addMarker":
            let (clip, time) = try placed(try field(wire.time, "time"))
            return .addMarker(clip: clip, marker: TimelineMarker(id: wire.markerID ?? UUID(), time: time, label: wire.label ?? "",
                                                                 color: try markerColor(wire.color) ?? .blue))
        case "updateMarker":
            let clipID = try field(wire.clipID, "clipID"), markerID = try field(wire.markerID, "markerID")
            guard var marker = (try record(clipID).markers ?? []).first(where: { $0.id == markerID }) else {
                throw EditError.notFound("No marker \(markerID) on recording \(clipID).")
            }
            if let time = wire.time { marker.time = try placed(time).1 }
            if let label = wire.label { marker.label = label }
            if let color = try markerColor(wire.color) { marker.color = color }
            return .updateMarker(clip: clipID, marker: marker)
        case "removeMarker":
            return .removeMarker(clip: try field(wire.clipID, "clipID"), marker: try field(wire.markerID, "markerID"))
        case "addGraphic":
            var value = try field(wire.graphic, "graphic")
            if value.id == nil { value.id = wire.graphicID }
            let clip = wire.timeSpace == "movie" ? try placed(try field(value.start, "graphic.start")).0
                : try field(wire.clipID, "clipID")
            return .addGraphic(clip: clip, graphic: try spokenWords(try checkedImages(try graphic(value)), on: clip))
        case "updateGraphic":
            let clipID = try field(wire.clipID, "clipID")
            let value = try field(wire.graphic, "graphic")
            let graphicID = try field(wire.graphicID ?? value.id, "graphicID")
            guard let old = try record(clipID).graphics?.items.first(where: { $0.id == graphicID }) else {
                throw EditError.notFound("No graphic \(graphicID) on recording \(clipID).")
            }
            return .updateGraphic(clip: clipID, graphic: try spokenWords(try checkedImages(try graphic(value, keeping: old)), on: clipID))
        case "removeGraphic":
            return .removeGraphic(clip: try field(wire.clipID, "clipID"), graphic: try field(wire.graphicID, "graphicID"))
        case "replaceGraphics":
            let clipID = try field(wire.clipID, "clipID")
            let graphics = try field(wire.graphics, "graphics").map { try spokenWords(try checkedImages(try graphic($0)), on: clipID) }
            let style = try wire.graphicsStyle.map { try mergedStyle($0, onto: try record(clipID).graphics?.style ?? GraphicsStyle()) }
            return .replaceGraphics(clip: clipID, graphics: graphics, style: style)
        case "setGraphicsStyle":
            let clipID = try field(wire.clipID, "clipID")
            let changes = try field(wire.graphicsStyle, "graphicsStyle")
            return .setGraphicsStyle(clip: clipID, style: try mergedStyle(changes, onto: try record(clipID).graphics?.style ?? GraphicsStyle()))
        case "setPublishInfo":
            let clipID = try field(wire.clipID, "clipID")
            return .setPublishInfo(clip: clipID, info: try mergedPublish(try field(wire.publish, "publish"),
                                                                        onto: try record(clipID).publish ?? PublishInfo()))
        case "setProjectNotes":
            return .setNotes(try field(wire.notes, "notes"))
        case "addProjectNote":
            let note = try field(wire.note, "note").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { throw EditError.invalid("A note says something; send note with words in it.") }
            let bare = note.hasPrefix("- ") ? String(note.dropFirst(2)) : note
            return .addNote("- \(bare) *(\(origin.label), \(Date().formatted(.dateTime.day().month(.abbreviated))))*")
        case "setAutoEditOptions":
            return .setAutoEditOptions(try Self.mergedAutoEdit(try field(wire.autoEdit, "autoEdit"), onto: document.autoEdit ?? AutoEditOptions()))
        case "importTranscript":
            let clipID = try field(wire.clipID, "clipID")
            _ = try record(clipID)
            let path = (try field(wire.path, "path") as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: path) else {
                throw EditError(code: .missingMedia, message: "No file at \(path).")
            }
            do { return .setTranscript(clip: clipID, transcript: try Self.readTranscript(data)) }
            catch { throw EditError.invalid("\((path as NSString).lastPathComponent) cannot be used as a transcript: \(Self.describe(error))") }
        case "clearTranscript":
            return .setTranscript(clip: try field(wire.clipID, "clipID"), transcript: nil)
        case "addShort":
            let clip = try record(try field(wire.clipID, "clipID"))
            var patch = wire.short ?? [:]
            if patch["id"] == nil, let id = wire.shortID { patch["id"] = .string(id.uuidString) }
            return .addShort(clip: clip.id, short: try Self.mergedShort(patch, onto: nil, clip: clip, speaker: speaker))
        case "updateShort":
            let clip = try record(try field(wire.clipID, "clipID"))
            let id = try field(wire.shortID, "shortID")
            guard let old = clip.shorts?.first(where: { $0.id == id }) else {
                throw EditError.notFound("No Short \(id) on recording \(clip.id). state.clips[].shorts lists them.")
            }
            return .updateShort(clip: clip.id, short: try Self.mergedShort(try field(wire.short, "short"), onto: old, clip: clip, speaker: speaker))
        case "removeShort":
            return .removeShort(clip: try field(wire.clipID, "clipID"), short: try field(wire.shortID, "shortID"))
        case "importGraphics":
            let path = (try field(wire.path, "path") as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw EditError(code: .missingMedia, message: "No file at \(path).")
            }
            do {
                let track = try GraphicsEngine.importFile(URL(fileURLWithPath: path))
                return .replaceGraphics(clip: try field(wire.clipID, "clipID"), graphics: track.items, style: track.style)
            } catch {
                throw EditError.invalid("\((path as NSString).lastPathComponent) cannot be used as graphics: \(error.localizedDescription)")
            }
        case "setScreen", "updateScreen", "removeScreen", "addLayout", "updateLayout", "removeLayout", "replaceLayouts",
             "addScreenZoom", "updateScreenZoom", "removeScreenZoom", "replaceScreenZooms":
            return try Self.resolveScreen(wire, in: document, probed: probed, face: face, border: border)
        case "addMusic", "updateMusic", "removeMusic", "setMusicDuck":
            return try Self.resolveMusic(wire, in: document, measured: music, voices: voices)
        case "setSounds":
            return try Self.resolveSounds(wire, in: document, voices: voices)
        default:
            throw EditError(code: .unsupportedCapability,
                            message: "Unknown command type \"\(wire.type)\". Types: \(WireCommand.types.joined(separator: ", ")).")
        }
    }

    /// Auto edit answers named in `patch` replace the current ones; the rest are kept.
    static func mergedAutoEdit(_ patch: [String: JSONValue], onto options: AutoEditOptions) throws -> AutoEditOptions {
        guard case .object(var fields) = try JSONValue.from(options) else { throw EditError.invalid("Could not read the current options.") }
        let allowed: [String: [String]] = [
            "model": TranscriptModel.allCases.map(\.rawValue), "cutStyle": CutStyle.allCases.map(\.rawValue),
            "captions": CaptionUse.allCases.map(\.rawValue), "language": [], "normaliseAudio": [],
        ]
        for (key, value) in patch {
            guard let values = allowed[key] else {
                throw EditError.invalid("Unknown auto edit option \"\(key)\". Options: \(allowed.keys.sorted().joined(separator: ", ")).")
            }
            if !values.isEmpty {
                guard case .string(let text) = value, values.contains(text) else {
                    throw EditError.invalid("\(key) must be one of: \(values.joined(separator: ", ")).")
                }
            }
            fields[key] = value
        }
        let merged: AutoEditOptions
        do { merged = try AgentProtocol.decoder.decode(AutoEditOptions.self, from: AgentProtocol.encoder.encode(JSONValue.object(fields))) }
        catch { throw EditError.invalid("An auto edit option has the wrong type (language is text, normaliseAudio true or false).") }
        if let problem = merged.problem { throw EditError.invalid(problem) }
        return merged
    }

    /// whisper-cli's full JSON (-ojf, with -dtw for word times), or a transcript as state
    /// shows one: {model, language, words: [{text, start, end}]} in source seconds.
    static func readTranscript(_ data: Data) throws -> Transcript {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["transcription"] != nil {
            let params = object["params"] as? [String: Any]
            let model = ((params?["model"] as? String).map { ($0 as NSString).lastPathComponent } ?? "whisper")
                .replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")
            return try Whisper.parse(data, model: model, language: params?["language"] as? String ?? "en")
        }
        return try AgentProtocol.decoder.decode(Transcript.self, from: data)
    }

    /// Settings named in `patch` replace the current ones; the rest are kept.
    private func mergedSettings(_ settings: ExportSettings, patch: [String: JSONValue]) throws -> ExportSettings {
        guard case .object(var fields) = try JSONValue.from(settings) else { throw EditError.invalid("Could not read the current settings.") }
        for (key, value) in patch {
            guard Self.exportSettingKeys.contains(key) else {
                throw EditError.invalid("Unknown export setting \"\(key)\". Settings: \(Self.exportSettingKeys.sorted().joined(separator: ", ")).")
            }
            if case .string(let path) = value, key == "outputFolder", !path.hasPrefix("file:") {
                fields[key] = .string(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).absoluteString)
            } else if value == .null {
                fields.removeValue(forKey: key)
            } else {
                fields[key] = value
            }
        }
        do { return try AgentProtocol.decoder.decode(ExportSettings.self, from: AgentProtocol.encoder.encode(JSONValue.object(fields))) }
        catch { throw EditError.invalid("An export setting has the wrong type or value (\(Self.describe(error))).") }
    }

    nonisolated static let exportSettingKeys: Set<String> = {
        var every = ExportSettings()
        every.outputFolder = URL(fileURLWithPath: "/")
        every.graphics = true
        every.captions = .upload
        every.shortCaptions = .burnIn
        guard case .object(let fields)? = try? JSONValue.from(every) else { return [] }
        return Set(fields.keys)
    }()

    private func agentHistory(_ request: AgentRequest) -> Result<AgentReceipt, EditError> {
        if let refusal = checkSession(request, required: true) { return .failure(refusal) }
        guard let expected = request.expectedRevision, let transaction = request.transactionID else {
            return .failure(EditError(code: .invalidRequest, message:
                "\(request.method) needs expectedRevision and the transactionID of the step, from state.history."))
        }
        let origin = agentOrigin(request)
        let result = request.method == "redo"
            ? redo(origin: origin, expectedTransaction: transaction, expectedRevision: expected)
            : undo(origin: origin, expectedTransaction: transaction, expectedRevision: expected)
        return result.map {
            AgentReceipt(revision: $0.revision, transactionID: $0.transactionID, changed: true, dryRun: false,
                         createdIDs: [], removedZooms: [], affectedClips: $0.affectedClips)
        }
    }

    /// Saves without a dialog: in place, to a first location, or as a copy. A copy gets
    /// its own identity and the open project keeps pointing at its own file.
    private func agentSave(_ request: AgentRequest) -> Result<AgentSaveResult, EditError> {
        if let refusal = checkSession(request, required: true) { return .failure(refusal) }
        guard let expected = request.expectedRevision else {
            return .failure(EditError(code: .invalidRequest, message: "save needs expectedRevision."))
        }
        if let refusal = admit(agentOrigin(request), expectedRevision: expected) { return .failure(refusal) }
        let requested = request.path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        guard let destination = requested ?? projectURL else {
            return .failure(EditError(code: .invalidRequest, message: "This project has never been saved. Pass path to choose where."))
        }
        guard destination.pathExtension.lowercased() == "yamvideo" else {
            return .failure(.invalid("Project files end in .yamvideo."))
        }
        let current = projectURL?.standardizedFileURL
        let inPlace = destination == current
        let copy = !inPlace && current != nil
        if !inPlace, FileManager.default.fileExists(atPath: destination.path), request.overwrite != true {
            return .failure(.invalid("\(destination.lastPathComponent) already exists. Pass overwrite: true to replace it."))
        }
        if inPlace, diskConflict(at: destination) {
            return .failure(EditError(code: .diskConflict, message:
                "\(destination.lastPathComponent) changed on disk since it was opened or saved. Save a copy, or let the owner decide."))
        }
        do {
            if copy {
                var forked = project
                forked.projectID = UUID()
                try writeProject(forked, to: destination)
                return .success(AgentSaveResult(path: destination.path, projectID: forked.projectID!, revision: revision, copy: true))
            }
            savedFingerprint = try writeProject(project, to: destination)
            projectURL = destination; savedProject = project; hasUnsavedChanges = false
            scheduleAutosave()
            noteProjectLocation()
            writeVideoNotes()
            statusMessage = "\(agentOrigin(request).label) saved \(destination.lastPathComponent)."
            return .success(AgentSaveResult(path: destination.path, projectID: projectID, revision: revision, copy: false))
        } catch {
            return .failure(EditError(code: .invalidRequest, message: "Could not save: \(error.localizedDescription)"))
        }
    }

    /// Navigation on the owner's behalf, only when an agent explicitly asks. Not an edit:
    /// no revision, no undo step.
    private func agentReveal(_ request: AgentRequest) -> Result<AgentState.Selection, EditError> {
        if let refusal = checkSession(request, required: false) { return .failure(refusal) }
        if let idea = request.idea {
            guard library.item(idea) != nil else { return .failure(.notFound("No idea \(idea) in the Library.")) }
            showIdea(idea)
            return .success(agentState().selection)
        }
        // Everything else is in Studio.
        if request.clip != nil || request.section != nil || request.zoom != nil || request.effect != nil || request.marker != nil
            || request.graphic != nil || request.short != nil || request.layout != nil || request.time != nil {
            showModule(.studio)
        }
        if request.timeSpace == "movie" {
            setMovieMode(true)
            if let time = request.time { seekMovie(to: time) }
        } else {
            if let clip = request.clip {
                guard items.contains(where: { $0.id == clip }) else { return .failure(.notFound("No recording \(clip).")) }
                listSelection.wrappedValue = clip
                if isMovieMode { setMovieMode(false) }
            }
            if let section = request.section {
                guard selectedItem?.timeline.segments.contains(where: { $0.id == section }) == true else {
                    return .failure(.notFound("No section \(section) on the selected recording."))
                }
                selectSegment(section)
            }
            if let zoom = request.zoom {
                guard let shot = selectedItem?.zoomShots.first(where: { $0.id == zoom }) else {
                    return .failure(.notFound("No zoom \(zoom) on the selected recording."))
                }
                selectedShotID = zoom
                scrubToShot(shot)
            }
            if let id = request.effect {
                guard let effect = selectedItem?.blurEffects.first(where: { $0.id == id }) else {
                    return .failure(.notFound("No blur effect \(id) on the selected recording."))
                }
                selectedEffectID = id
                jumpToEffect(effect)
            }
            if let id = request.marker {
                guard let marker = selectedItem?.markers.first(where: { $0.id == id }) else {
                    return .failure(.notFound("No marker \(id) on the selected recording."))
                }
                selectMarker(marker)
            }
            if let graphic = request.graphic {
                guard let found = selectedItem?.graphics?.items.first(where: { $0.id == graphic }) else {
                    return .failure(.notFound("No graphic \(graphic) on the selected recording."))
                }
                selectedGraphicID = graphic
                if let item = selectedItem, item.editedDuration > 0 { setPreviewFraction(found.start / item.editedDuration) }
            }
            if let id = request.layout {
                guard let span = selectedItem?.screen?.spans.first(where: { $0.id == id }) else {
                    return .failure(.notFound("No layout \(id) on the selected recording."))
                }
                selectLayout(span)
            }
            if let id = request.short {
                guard let short = selectedItem?.short(id) else {
                    return .failure(.notFound("No Short \(id) on the selected recording."))
                }
                showShort(short)
                if let time = request.time, let item = selectedItem, item.editedDuration > 0 {
                    setPreviewFraction(min(short.end, short.start + max(0, time)) / item.editedDuration)
                }
                return .success(agentState().selection)
            }
            if let time = request.time, let item = selectedItem, item.editedDuration > 0 {
                setPreviewFraction(time / item.editedDuration)
            }
        }
        return .success(agentState().selection)
    }

    // MARK: Previews and jobs

    nonisolated static var artifactsDirectory: URL {
        // An instance with its own bridge directory keeps its previews there too, so its
        // cleanup can never touch another instance's.
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_AGENT_BRIDGE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("Artifacts", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo", isDirectory: true).appendingPathComponent("AgentArtifacts", isDirectory: true)
    }

    /// One frame of a recording at an edited time, as a PNG file — a path, never image
    /// bytes in the response. Blur areas, tone mapping and captions are applied as in
    /// the app's preview; `cropped` also applies the crop.
    private func agentPreview(_ request: AgentRequest) async -> Result<AgentPreview, EditError> {
        if let refusal = checkSession(request, required: false) { return .failure(refusal) }
        if let expected = request.expectedRevision, expected != revision {
            return .failure(EditError(code: .revisionConflict, message:
                "The project is at revision \(revision), not \(expected). Read state and ask again."))
        }
        var document = committedProject
        let requestedRevision = revision
        if let draft = request.draft {
            do { document = try Self.drafting(draft, clip: request.clip, in: document) }
            catch let error as EditError { return .failure(error) }
            catch { return .failure(.invalid("The draft graphics could not be read: \(error.localizedDescription)")) }
        }
        if let short = request.short { return await agentShortPreview(request, short: short, document: document, revision: requestedRevision) }
        do {
            let time = try require(request.time, "time")
            let (clipID, local): (UUID, Double)
            if request.timeSpace == "movie" { (clipID, local) = try movieLocation(time, in: document) }
            else { (clipID, local) = (try require(request.clip, "clip"), time) }
            guard let stored = document.clips.first(where: { $0.id == clipID }) else { throw EditError.notFound("No recording \(clipID).") }
            // The picture as it plays and exports: switched-off changes left out.
            let clip = ProjectClip(stored.item().effective)
            guard let info = clip.info else { throw EditError(code: .missingMedia, message: "That recording is still loading.") }
            let timeline = clip.timeline
            guard local.isFinite, local >= 0, local <= timeline.duration else {
                throw EditError.invalid("Time must be within the edited recording (0–\(timeline.duration) s).")
            }
            let source = timeline.location(at: local)?.source ?? 0
            let cropped = request.cropped ?? false
            let settings = document.settings
            let composed = request.composed ?? false
            if composed {
                let frame = try await composedFrame(clip, at: local, settings: settings, original: request.original ?? false)
                var preview = try writePreview(frame.image, clipID: clipID, local: local, source: source, revision: requestedRevision,
                                               cropped: true, original: request.original ?? false, composed: true)
                preview.graphics = frame.graphics
                return .success(preview)
            }
            let data = try await FFmpeg.thumbnail(
                url: clip.url, at: source, duration: info.duration, regions: clip.blurRegions.filter { $0.covers(source: source) }.map(\.rect),
                style: settings.blurStyle, strength: settings.blurStrength, toneMap: info.isHDR && settings.toneMapHDR,
                color: clip.item().colorFilters(settings, original: request.original ?? false),
                subtitles: clip.item().burnedCaptions(settings), subtitleStyle: settings.subtitleForceStyle,
                maxWidth: cropped ? info.width : min(info.width, 1600))
            guard let bitmap = NSBitmapImageRep(data: data), var image = bitmap.cgImage else {
                throw EditError.invalid("The frame could not be decoded.")
            }
            if cropped, let crop = clip.crop {
                let scale = Double(image.width) / Double(info.width)
                let rect = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
                guard let piece = image.cropping(to: rect) else { throw EditError.invalid("The crop could not be applied.") }
                image = piece
            }
            return .success(try writePreview(image, clipID: clipID, local: local, source: source, revision: requestedRevision,
                                             cropped: cropped, original: request.original ?? false, composed: false))
        } catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid("The frame could not be rendered: \(error.localizedDescription)")) }
    }

    /// `document` with draft graphics added to recording `clip`, checked as the recording's
    /// graphics are, for one preview.
    static func drafting(_ draft: [JSONValue], clip: UUID?, in document: VideoProject) throws -> VideoProject {
        guard let clip, let index = document.clips.firstIndex(where: { $0.id == clip }) else {
            throw EditError.invalid("A preview with draft graphics needs the recording in clip.")
        }
        var copy = document
        var track = copy.clips[index].graphics ?? GraphicsTrack()
        for value in draft {
            guard let item = value.object, let name = item["kind"]?.string, let kind = GraphicKind(rawValue: name),
                  let start = item["start"]?.number, let end = item["end"]?.number else {
                throw EditError.invalid("Each draft graphic needs a known kind, a start and an end, as in addGraphic.")
            }
            let id = item["id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID()
            let look = item["look"]?.string.flatMap(GraphicsLook.init(rawValue:))
            let transform = item["transform"]?.object.map { GraphicTransform(x: $0["x"]?.number ?? 0, y: $0["y"]?.number ?? 0, scale: $0["scale"]?.number ?? 1) }
            track.items.removeAll { $0.id == id }
            track.items.append(Graphic(id: id, kind: kind, start: start, end: end, props: item["props"]?.object ?? [:], look: look, transform: transform))
        }
        if let problem = track.problem(duration: copy.clips[index].timeline.duration) { throw EditError.invalid("Draft graphics: \(problem)") }
        copy.clips[index].graphics = track
        return copy
    }

    /// The picture at an edited time as the owner's Preview shows it: the native renderer
    /// (zooms, colour, effects, the move aside), then the graphics, drawn by the same engine
    /// page the Preview lays over the picture, with where each one landed.
    func composedFrame(_ clip: ProjectClip, at local: Double, settings: ExportSettings,
                       original: Bool = false, graphics: Bool = true, guides: Bool = true) async throws -> (image: CGImage, graphics: [PreviewGraphic]?) {
        guard let info = clip.info else { throw EditError(code: .missingMedia, message: "That recording is still loading.") }
        let timeline = clip.timeline
        let player = try await PlaybackController.makeItem(clip.item(), settings: settings, original: original)
        let generator = AVAssetImageGenerator(asset: player.asset)
        generator.videoComposition = player.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var image = try await generator.image(at: CMTime(seconds: min(local, max(0, timeline.duration - 1 / max(1, info.fps))),
                                                         preferredTimescale: 600_000)).image
        var drawn: [PreviewGraphic]?
        if graphics, let track = clip.item().placedGraphics, !track.items.isEmpty,
           abs(Double(image.width) / Double(max(1, image.height)) - 16.0 / 9.0) < 0.02 {
            // As the Preview shows them: the end screen's boxes say what goes in each.
            let snapshot = try await GraphicsSnapshot.draw(guides ? track.labellingEndScreen(clip.publish?.endScreen) : track, duration: timeline.duration,
                                                           fps: info.fpsExpression, time: local, over: image)
            image = snapshot.image
            drawn = track.items.compactMap { graphic in
                snapshot.boxes[graphic.id].map { PreviewGraphic(id: graphic.id, kind: graphic.kind.rawValue, rect: WireRect($0)) }
            }
        }
        return (image, drawn)
    }

    func writePreview(_ image: CGImage, clipID: UUID, local: Double, source: Double, revision: Int,
                              cropped: Bool, original: Bool, composed: Bool) throws -> AgentPreview {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw EditError.invalid("The frame could not be encoded.")
        }
        let directory = agentArtifactsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(
            "preview-r\(revision)-\(clipID.uuidString.prefix(8))-\(Int((local * 1000).rounded()))ms-\(UUID().uuidString.prefix(6)).png")
        try png.write(to: file, options: .atomic)
        return AgentPreview(path: file.path, revision: revision, clip: clipID, time: local, sourceTime: source,
                            width: image.width, height: image.height, cropped: cropped, original: original, composed: composed)
    }

    private func agentJob(_ request: AgentRequest) -> Result<AgentJob, EditError> {
        guard let id = request.job, let job = agentJobs[id] else { return .failure(.notFound("No job with that ID.")) }
        return .success(job)
    }

    private func agentCancel(_ request: AgentRequest) -> Result<AgentJob, EditError> {
        guard let id = request.job, let job = agentJobs[id] else { return .failure(.notFound("No job with that ID.")) }
        agentJobTasks[id]?.cancel()
        return .success(job)
    }

    func startJob(id: UUID = UUID(), kind: String, clip: UUID?, origin: EditOrigin,
                          work: @escaping @MainActor () async throws -> JSONValue) -> AgentJob {
        let job = AgentJob(id: id, kind: kind, status: "running", progress: ["export", "transcribe", "autoEdit"].contains(kind) ? 0 : nil,
                           sourceRevision: revision, clip: clip, origin: origin.label, createdAt: Date())
        agentJobs[job.id] = job
        agentJobTasks[job.id] = Task { [weak self] in
            var result: JSONValue?
            var failure: AgentErrorBody?
            var status = "succeeded"
            do { result = try await work() }
            catch is CancellationError { status = "cancelled" }
            catch {
                status = "failed"
                failure = AgentErrorBody(code: (error as? EditError)?.code.rawValue ?? "job_failed",
                                         message: error.localizedDescription, retryable: false, currentRevision: nil)
            }
            guard let self else { return }
            self.agentJobs[job.id]?.status = status
            self.agentJobs[job.id]?.result = result
            self.agentJobs[job.id]?.error = failure
            self.agentJobs[job.id]?.finishedAt = Date()
            self.agentJobTasks[job.id] = nil
            self.appendEvent(.job, origin: origin, label: "\(kind.capitalized) \(status)", clips: clip.map { [$0] } ?? [])
        }
        return job
    }

    /// Silence or zoom analysis of one recording. The result is a proposal tied to the
    /// revision it read; applying it is a separate, ordinary edit.
    private func agentAnalyze(_ request: AgentRequest) -> Result<AgentJob, EditError> {
        if let refusal = checkSession(request, required: true) { return .failure(refusal) }
        guard let clipID = request.clip, let item = committedProject.clips.first(where: { $0.id == clipID })?.item(),
              let info = item.info else {
            return .failure(EditError(code: .missingMedia, message: "analyze needs a loaded recording in clip."))
        }
        let timeline = item.timeline
        switch request.kind {
        case "silence":
            let threshold = request.threshold ?? -40, minimum = request.minimum ?? 0.8, padding = request.padding ?? 0.15
            guard threshold.isFinite, minimum.isFinite, padding.isFinite, minimum > 0, padding >= 0 else {
                return .failure(.invalid("threshold, minimum and padding must be finite; minimum above 0."))
            }
            return .success(startJob(kind: "analyze", clip: clipID, origin: agentOrigin(request)) {
                let overview = try await AudioAnalyzer.analyze(item.url)
                let cuts = overview.cuts(in: timeline, fps: info.fps, threshold: threshold, minimum: minimum, padding: padding)
                struct Cut: Encodable { var sectionID: UUID; var start: Double; var end: Double; var editedStart: Double; var duration: Double }
                struct Section: Encodable { var id: UUID; var start: Double; var end: Double; var speed: Double }
                struct Silence: Encodable { var kind = "silence"; var cuts: [Cut]; var proposedSections: [Section]; var savedSeconds: Double }
                let proposed = timeline.removing(cuts).segments
                return try JSONValue.from(Silence(
                    cuts: cuts.map { Cut(sectionID: $0.segmentID, start: $0.start, end: $0.end, editedStart: $0.timelineStart, duration: $0.duration) },
                    proposedSections: proposed.map { Section(id: $0.id, start: $0.start, end: $0.end, speed: $0.speed) },
                    savedSeconds: cuts.reduce(0) { $0 + $1.duration }))
            })
        case "zooms", "screenZooms":
            let screen = request.kind == "screenZooms"
            if screen, item.screen == nil {
                return .failure(.invalid("Recording \(clipID) has no screen recording. Add one with setScreen first."))
            }
            return .success(startJob(kind: "analyze", clip: clipID, origin: agentOrigin(request)) {
                let suggestions = screen ? try await ZoomAnalyzer.analyzeScreen(item) : try await ZoomAnalyzer.analyze(item)
                struct Suggestion: Encodable { var start: Double; var hold: Double; var level: Double; var target: WirePoint; var score: Double }
                struct Zooms: Encodable { var kind: String; var suggestions: [Suggestion] }
                return try JSONValue.from(Zooms(kind: screen ? "screenZooms" : "zooms", suggestions: suggestions.map {
                    Suggestion(start: $0.shot.start, hold: $0.shot.hold, level: $0.shot.level, target: WirePoint($0.shot.target), score: $0.score)
                }))
            })
        case "autoEdit":
            let options = committedProject.autoEdit ?? AutoEditOptions()
            let style: CutStyle?
            do { style = try Self.cutStyle(request.style) } catch let error as EditError { return .failure(error) } catch { return .failure(.invalid("\(error)")) }
            let clip = committedProject.clips.first { $0.id == clipID }!
            return .success(startJob(kind: "analyze", clip: clipID, origin: agentOrigin(request)) { [weak self] in
                guard let self else { throw CancellationError() }
                let plan = try await self.planAutoEdit(clipID, options: options, style: style)
                var note: String?
                if plan.style.cutsStumbles, clip.transcript == nil {
                    note = "No transcript yet, so these are pauses only. Run transcribe first to cut stumbles too."
                }
                return try JSONValue.from(AutoEditResult(plan, applied: false, transcribed: false, note: note))
            })
        case "music":
            guard item.music != nil else { return .failure(.invalid("Recording \(clipID) has no music. Add music with addMusic first.")) }
            return .success(startJob(kind: "analyze", clip: clipID, origin: agentOrigin(request)) {
                try JSONValue.from(try await MusicAnalysis.analyze(item, info: info))
            })
        case "thumbnailFrames":
            let count = request.limit ?? 8
            guard (1...20).contains(count) else { return .failure(.invalid("limit for thumbnailFrames is from 1 to 20.")) }
            let directory = agentArtifactsDirectory
            return .success(startJob(kind: "analyze", clip: clipID, origin: agentOrigin(request)) {
                let suggestions = try await FrameAnalyzer.analyze(item, count: count)
                struct Suggestion: Encodable {
                    var time: Double; var sourceTime: Double; var score: Double
                    var smile: Double; var quality: Double; var eyes: Double; var facing: Double; var face: WireRect
                }
                struct Frames: Encodable { var kind = "thumbnailFrames"; var suggestions: [Suggestion]; var sheet: String?; var note: String? }
                var sheet: String?
                if let picture = FrameAnalyzer.sheet(suggestions), let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let file = directory.appendingPathComponent("frames-\(clipID.uuidString.prefix(8))-\(UUID().uuidString.prefix(6)).png")
                    try png.write(to: file, options: .atomic)
                    sheet = file.path
                }
                func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
                return try JSONValue.from(Frames(suggestions: suggestions.map {
                    Suggestion(time: round($0.time), sourceTime: round($0.source), score: round($0.look.score), smile: round($0.look.smile),
                               quality: round($0.look.quality), eyes: round($0.look.eyes), facing: round($0.look.facing), face: WireRect($0.look.face))
                }, sheet: suggestions.isEmpty ? nil : sheet,
                   note: suggestions.isEmpty ? "Apple Vision found no face in the kept footage." : nil))
            })
        case "logos":
            let gap = request.minimum ?? 60
            guard gap.isFinite, gap >= 0 else { return .failure(.invalid("minimum for logos is the seconds between two badges of one logo, 0 or more.")) }
            guard item.transcript != nil else {
                return .failure(.notFound("\(item.name) has no transcript yet. Run transcribe, or importTranscript, first."))
            }
            return .success(startJob(kind: "analyze", clip: clipID, origin: agentOrigin(request)) { [weak self] in
                guard let self, let result = self.brandAnalysis(item, gap: gap) else { throw CancellationError() }
                return try JSONValue.from(result)
            })
        default:
            return .failure(.invalid("kind must be one of: \(AgentSessionInfo.analyzeKinds.joined(separator: ", "))."))
        }
    }

    static func cutStyle(_ name: String?) throws -> CutStyle? {
        guard let name else { return nil }
        guard let style = CutStyle(rawValue: name) else {
            throw EditError.invalid("style must be one of: \(CutStyle.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return style
    }

    /// The model and language a transcription uses: the request's, else the project's answers.
    private func transcriptChoice(_ request: AgentRequest) throws -> (TranscriptModel, String) {
        let options = committedProject.autoEdit ?? AutoEditOptions()
        var model = options.model
        if let name = request.model {
            guard let chosen = TranscriptModel(rawValue: name) else {
                throw EditError.invalid("model must be one of: \(TranscriptModel.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            model = chosen
        }
        let language = request.language ?? (model.englishOnly ? "en" : options.language)
        var check = AutoEditOptions(); check.model = model; check.language = language
        if let problem = check.problem { throw EditError.invalid(problem) }
        guard Whisper.cliPath != nil else { throw EditError(code: .unsupportedCapability, message: Whisper.missingMessage) }
        guard Whisper.hasModel(model) else { throw EditError(code: .unsupportedCapability, message: Whisper.needsModelMessage(model)) }
        return (model, language)
    }

    /// Transcribes a recording with whisper.cpp on this Mac, as a job; the words land as
    /// one undo step named Transcribe.
    private func agentTranscribe(_ request: AgentRequest) -> Result<AgentJob, EditError> {
        if let refusal = checkSession(request, required: true) { return .failure(refusal) }
        if agentsPaused { return .failure(EditError(code: .agentsPaused, message: "Agent edits are paused in YamVideo. Ask the owner to resume them.")) }
        guard let clipID = request.clip, let clip = committedProject.clips.first(where: { $0.id == clipID }), let info = clip.info else {
            return .failure(EditError(code: .missingMedia, message: "transcribe needs a loaded recording in clip."))
        }
        guard info.hasAudio else { return .failure(.invalid("\(clip.url.lastPathComponent) has no audio to transcribe.")) }
        let model: TranscriptModel, language: String
        do { (model, language) = try transcriptChoice(request) } catch let error as EditError { return .failure(error) } catch { return .failure(.invalid("\(error)")) }
        let origin = agentOrigin(request)
        let id = UUID()
        return .success(startJob(id: id, kind: "transcribe", clip: clipID, origin: origin) { [weak self] in
            guard let self else { throw CancellationError() }
            let (transcript, receipt) = try await self.transcribe(clipID, model: model, language: language, origin: origin) { fraction in
                Task { @MainActor [weak self] in self?.agentJobs[id]?.progress = fraction }
            }
            struct Done: Encodable {
                var model: String, language: String, words: Int, stumbles: Int
                var transactionID: UUID?, revision: Int
            }
            return try JSONValue.from(Done(model: transcript.model, language: transcript.language, words: transcript.words.count,
                                           stumbles: StumbleFinder.stumbles(in: transcript.words).count,
                                           transactionID: receipt.transactionID, revision: receipt.revision))
        })
    }

    /// The whole auto edit as a job, by the project's answers: transcribe when the cut
    /// style or captions need the words and there are none, find the cuts, then apply
    /// them with the captions and loudness choices as one undo step. With Review each cut
    /// nothing is applied: the cuts come back for the owner to choose from.
    private func agentAutoEdit(_ request: AgentRequest) -> Result<AgentJob, EditError> {
        if let refusal = checkSession(request, required: true) { return .failure(refusal) }
        if agentsPaused { return .failure(EditError(code: .agentsPaused, message: "Agent edits are paused in YamVideo. Ask the owner to resume them.")) }
        guard let clipID = request.clip, let clip = committedProject.clips.first(where: { $0.id == clipID }), clip.info != nil else {
            return .failure(EditError(code: .missingMedia, message: "autoEdit needs a loaded recording in clip."))
        }
        let options = committedProject.autoEdit ?? AutoEditOptions()
        let style: CutStyle?
        do { style = try Self.cutStyle(request.style) } catch let error as EditError { return .failure(error) } catch { return .failure(.invalid("\(error)")) }
        var choice: (TranscriptModel, String)?
        if needsTranscript(clip, options: options, style: style), clip.transcript == nil {
            do { choice = try transcriptChoice(request) } catch let error as EditError {
                return .failure(EditError(code: error.code, message: error.message
                    + " (The cut style or captions need a transcript. Without one, use style natural and captions off, or import one with importTranscript.)"))
            } catch { return .failure(.invalid("\(error)")) }
        }
        let origin = agentOrigin(request)
        let label = request.label ?? "Auto Edit"
        let id = UUID()
        return .success(startJob(id: id, kind: "autoEdit", clip: clipID, origin: origin) { [weak self] in
            guard let self else { throw CancellationError() }
            if let (model, language) = choice {
                try await self.transcribe(clipID, model: model, language: language, origin: origin) { fraction in
                    Task { @MainActor [weak self] in self?.agentJobs[id]?.progress = fraction * 0.9 }
                }
            }
            let plan = try await self.planAutoEdit(clipID, options: options, style: style)
            self.agentJobs[id]?.progress = 0.95
            if plan.style == .review {
                return try JSONValue.from(AutoEditResult(plan, applied: false, transcribed: choice != nil, note:
                    "The owner chose Review each cut, so nothing was cut. Show the owner these cuts; apply the ones they keep with replaceSections, and settings with setExportSettings."))
            }
            switch self.applyAutoEdit(plan, origin: origin, label: label) {
            case .success(let receipt):
                var result = AutoEditResult(plan, applied: true, transcribed: choice != nil, note: nil)
                result.transactionID = receipt.transactionID; result.revision = receipt.revision
                result.removedZooms = receipt.removedZooms; result.removedEffects = receipt.removedEffects
                result.removedMarkers = receipt.removedMarkers; result.removedGraphics = receipt.removedGraphics
                return try JSONValue.from(result)
            case .failure(let error): throw error
            }
        })
    }

    /// The words of a recording in source seconds with where each now plays (editedStart,
    /// null when cut), its captions on the edited timeline, and the stumbles found in it.
    private func agentTranscript(_ request: AgentRequest) -> Result<AgentTranscript, EditError> {
        guard let clipID = request.clip, let clip = committedProject.clips.first(where: { $0.id == clipID }) else {
            return .failure(.notFound("transcript needs a recording's id in clip."))
        }
        guard let transcript = clip.transcript else {
            return .failure(.notFound("\(clip.url.lastPathComponent) has no transcript yet. Run transcribe (state.autoEdit lists the models on this Mac), or importTranscript."))
        }
        let timeline = clip.timeline
        return .success(AgentTranscript(
            clip: clipID, model: transcript.model, language: transcript.language, text: transcript.text,
            words: transcript.words.map { .init(text: $0.text, start: $0.start, end: $0.end, editedStart: timeline.time(forSource: $0.start)) },
            captions: Captions.edited(transcript.captions(timeline: timeline), timeline: timeline).map { .init(start: $0.start, end: $0.end, text: $0.text) },
            stumbles: StumbleFinder.stumbles(in: transcript.words).map {
                .init(kind: $0.kind.rawValue, text: $0.text, start: $0.start, end: $0.end, editedStart: timeline.time(forSource: $0.start))
            }))
    }

    /// Exports exactly the document at `expectedRevision` to an explicit path. Like the
    /// owner's export it locks edits until it ends, and the owner's Stop cancels it.
    private func agentExport(_ request: AgentRequest) -> Result<AgentJob, EditError> {
        if let refusal = checkSession(request, required: true) { return .failure(refusal) }
        guard let expected = request.expectedRevision else {
            return .failure(EditError(code: .invalidRequest, message: "export needs expectedRevision."))
        }
        let origin = agentOrigin(request)
        if let refusal = admit(origin, expectedRevision: expected) { return .failure(refusal) }
        guard let path = request.path else { return .failure(EditError(code: .invalidRequest, message: "export needs path.")) }
        if let short = request.short { return agentShortExport(request, short: short, path: path, origin: origin) }
        if request.youtube == true { return agentYouTubeExport(request, folder: path, origin: origin) }
        let output = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let format = settings.format
        guard output.pathExtension.lowercased() == format.fileExtension else {
            return .failure(.invalid("The export format is \(format.label); use a .\(format.fileExtension) path, or change format first."))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.invalid("The folder \(output.deletingLastPathComponent().path) does not exist."))
        }
        let resolved = output.resolvingSymlinksInPath().path
        guard !items.contains(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL.path == resolved }) else {
            return .failure(.invalid("Exports can never replace a source recording."))
        }
        if FileManager.default.fileExists(atPath: output.path), request.overwrite != true {
            return .failure(.invalid("\(output.lastPathComponent) already exists. Pass overwrite: true to replace it."))
        }

        enum Work { case recording(VideoItem, MediaInfo), movie(MoviePlan) }
        let work: Work
        switch request.scope ?? (request.clip == nil ? "" : "recording") {
        case "recording":
            guard let clipID = request.clip, let item = items.first(where: { $0.id == clipID }), let info = item.info,
                  FileManager.default.fileExists(atPath: item.url.path) else {
                return .failure(EditError(code: .missingMedia, message: "export needs a loaded recording in clip whose source is present."))
            }
            work = .recording(item, info)
        case "movie":
            do { work = .movie(try moviePlan()) } catch { return .failure(.invalid(error.localizedDescription)) }
        default:
            return .failure(.invalid("scope must be \"recording\" (with clip) or \"movie\"."))
        }

        // Graphics that still need drawing need HyperFrames, which only the owner can download.
        if case .recording(let item, let info) = work, let graphics = item.exportGraphics(settings), !graphics.items.isEmpty,
           let renderer = graphicsRenderer, renderer != .ready,
           FFmpeg.graphicsPlan(graphics, info: info, crop: (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame),
                               segments: item.segments, settings: settings, converted: true).jobs.contains(where: { !$0.isRendered }) {
            let why: String
            if case .needsNode(let detail) = renderer { why = detail } else { why = HyperFrames.missingMessage }
            return .failure(EditError(code: .unsupportedCapability, message: why
                + " Ask the owner, or send setExportSettings with {\"graphics\": false} to export without graphics."))
        }

        let exportSettings = settings
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".yamvideo-\(UUID().uuidString).\(format.fileExtension)")
        let clipID: UUID? = { if case .recording(let item, _) = work { return item.id }; return nil }()
        playback.pause()
        isConverting = true
        if let clipID, let index = items.firstIndex(where: { $0.id == clipID }) { items[index].status = .converting(0) }
        if case .movie = work { movieProgress = 0 }
        statusMessage = "\(origin.label) is exporting \(output.lastPathComponent)…"

        let jobID = UUID()
        let isMovie: Bool = { if case .movie = work { return true }; return false }()
        let job = startJob(id: jobID, kind: "export", clip: clipID, origin: origin) { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: temporary)
                self?.isConverting = false
                self?.movieProgress = nil
            }
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    guard let self else { return }
                    self.agentJobs[jobID]?.progress = value
                    if let clipID, let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .converting(value) }
                    if isMovie { self.movieProgress = value }
                }
            }
            do {
                switch work {
                case .recording(let recording, let info):
                    let item = recording.effective
                    await MusicSpeech.prepare(item)
                    try await FFmpeg.export(input: item.url, output: temporary, info: info,
                                            crop: (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame),
                                            regions: item.blurBoxes, zoomShots: item.zoomShots,
                                            segments: item.segments, settings: exportSettings, subtitles: item.burnedCaptions(exportSettings),
                                            color: item.colorStage(exportSettings), effects: item.blurEffects,
                                            graphics: item.exportGraphics(exportSettings), screen: item.screen,
                                            music: item.exportMusic(exportSettings), onProgress: progress)
                case .movie(let plan):
                    try await FFmpeg.exportMovie(plan: plan, settings: exportSettings, output: temporary, onProgress: progress)
                }
                try Task.checkCancellation()
                // Published only when complete: a cancelled export never touches the destination.
                if FileManager.default.fileExists(atPath: output.path) {
                    _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: output)
                }
            } catch {
                if let self, let clipID, let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .ready }
                self?.statusMessage = error is CancellationError ? "Export cancelled." : "\(origin.label)'s export failed."
                throw error
            }
            if let self {
                if let clipID, let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .done(output) }
                if isMovie { self.movieOutput = output }
                self.statusMessage = "\(origin.label) exported \(output.lastPathComponent)."
            }
            return .object(["path": .string(output.path), "format": .string(format.rawValue)])
        }
        return .success(job)
    }

    /// Export for YouTube as a job: the MP4, captions on the edited timeline, thumbnail,
    /// upload text and JSON, written into an existing folder.
    private func agentYouTubeExport(_ request: AgentRequest, folder path: String, origin: EditOrigin) -> Result<AgentJob, EditError> {
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.invalid("For a YouTube export, path is an existing folder; \(folder.path) is not one."))
        }
        guard let clipID = request.clip, let item = items.first(where: { $0.id == clipID }), let info = item.info,
              FileManager.default.fileExists(atPath: item.url.path) else {
            return .failure(EditError(code: .missingMedia, message: "A YouTube export needs a loaded recording in clip whose source is present."))
        }
        let publish = item.publish ?? PublishInfo()
        if let blocking = publish.issues(duration: item.editedDuration, graphics: item.graphics, music: item.effective.music, sounds: item.effective.usedSounds)
            .first(where: { $0.severity == .blocking }) {
            return .failure(.invalid(blocking.message + " (state.clips[].publishIssues lists everything; setPublishInfo changes it.)"))
        }
        let files = YouTubeExport.files(in: folder, publish: publish, fallback: item.url.deletingPathExtension().lastPathComponent,
                                        captions: item.uploadsCaptions(settings),
                                        unique: false)
        if request.overwrite != true, let existing = files.all.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return .failure(.invalid("\(existing.lastPathComponent) already exists. Pass overwrite: true to replace it."))
        }
        let exportSettings = settings
        let project = projectID
        playback.pause()
        isConverting = true
        if let index = items.firstIndex(where: { $0.id == clipID }) { items[index].status = .converting(0) }
        statusMessage = "\(origin.label) is exporting \(files.video.lastPathComponent) for YouTube…"
        let jobID = UUID()
        let job = startJob(id: jobID, kind: "export", clip: clipID, origin: origin) { [weak self] in
            defer { self?.isConverting = false }
            do {
                try await YouTubeExport.run(item, info: info, publish: publish, settings: exportSettings, files: files, project: project) { value in
                    Task { @MainActor in
                        guard let self else { return }
                        self.agentJobs[jobID]?.progress = value
                        if let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .converting(value) }
                    }
                }
            } catch {
                if let self, let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .ready }
                self?.statusMessage = error is CancellationError ? "Export cancelled." : "\(origin.label)'s YouTube export failed."
                throw error
            }
            if let self {
                if let index = self.items.firstIndex(where: { $0.id == clipID }) { self.items[index].status = .done(files.video) }
                self.finishedExport(files.json, title: files.video.deletingPathExtension().lastPathComponent, origin: origin)
                self.statusMessage = "\(origin.label) exported \(files.video.lastPathComponent) for YouTube."
            }
            var result: [String: JSONValue] = ["path": .string(files.video.path), "format": .string("mp4"),
                                               "text": .string(files.text.path), "json": .string(files.json.path)]
            if let captions = files.captions, FileManager.default.fileExists(atPath: captions.path) { result["captions"] = .string(captions.path) }
            if let thumbnail = files.thumbnail { result["thumbnail"] = .string(thumbnail.path) }
            if !files.tests.isEmpty { result["thumbnailTest"] = .array(files.tests.map { .string($0.path) }) }
            return .object(result)
        }
        return .success(job)
    }

    /// Renders a recording's thumbnail design, with `design` tried over the stored one, to a
    /// PNG an agent can look at; with `save`, also next to the recording, for setPublishInfo.
    private func agentThumbnail(_ request: AgentRequest) async -> Result<AgentThumbnail, EditError> {
        if let refusal = checkSession(request, required: false) { return .failure(refusal) }
        guard let clipID = request.clip, let clip = committedProject.clips.first(where: { $0.id == clipID }) else {
            return .failure(.invalid("thumbnail needs clip, a recording's id from state."))
        }
        guard clip.info != nil else { return .failure(EditError(code: .missingMedia, message: "That recording is still loading.")) }
        var publish = clip.publish ?? PublishInfo()
        if publish.design == nil { publish.design = ThumbnailDesign(time: 0, title: publish.title) }
        // A version of a Test & Compare: B or C stands in for the design.
        let letter = request.version?.uppercased() ?? "A"
        guard let versionIndex = ThumbnailTest.letters.firstIndex(of: letter) else { return .failure(.invalid("version is A, B or C.")) }
        if versionIndex > 0 {
            guard let versions = publish.test?.versions, versions.count >= versionIndex else {
                return .failure(.invalid("The recording has no version \(letter). Add it with setPublishInfo: {test: {versions: [B, C]}}."))
            }
            publish.design = versions[versionIndex - 1]
        }
        if let changes = request.design {
            guard case .object(var merged)? = try? JSONValue.from(publish.design!) else { return .failure(.invalid("Could not read the design.")) }
            for (name, value) in changes { if value == .null { merged.removeValue(forKey: name) } else { merged[name] = value } }
            do { publish.design = try AgentProtocol.decoder.decode(ThumbnailDesign.self, from: AgentProtocol.encoder.encode(JSONValue.object(merged))) }
            catch { return .failure(.invalid("design: \(Self.describe(error)).")) }
        }
        guard let design = publish.design else { return .failure(.invalid("No design.")) }
        if let problem = design.problem { return .failure(.invalid(problem)) }
        guard design.time <= clip.timeline.duration + 0.0005 else {
            return .failure(.invalid("The thumbnail's frame must be within the edited recording (0–\(clip.timeline.duration) s)."))
        }
        do {
            let sources = try await thumbnailSources(clip, at: design.time, cutout: design.cutout)
            let accent = clip.graphics?.style.accent ?? GraphicsStyle().accent
            // The check draws the design itself, so it is drawn once.
            let checked = request.check == true ? try await PhoneCheck.run(design, sources: sources, accent: accent) : nil
            let image: CGImage
            if let checked { image = checked.image } else { image = try await ThumbnailMaker.render(design, sources: sources, accent: accent) }
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return .failure(.invalid("The thumbnail could not be encoded."))
            }
            let directory = agentArtifactsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stem = "thumbnail-\(clipID.uuidString.prefix(8))-\(UUID().uuidString.prefix(6))"
            let file = directory.appendingPathComponent(stem + ".png")
            try png.write(to: file, options: .atomic)
            var check: AgentPhoneCheck?
            if let checked {
                guard let phone = PhoneCheck.phonePicture(image),
                      let phonePNG = NSBitmapImageRep(cgImage: phone).representation(using: .png, properties: [:]) else {
                    return .failure(.invalid("The phone picture could not be drawn."))
                }
                let phoneFile = directory.appendingPathComponent(stem + "-phone.png")
                try phonePNG.write(to: phoneFile, options: .atomic)
                let title = request.videoTitle ?? publish.title
                let gap = InformationGap.make(design, pictureWords: checked.check.pictureWords, title: title)
                check = AgentPhoneCheck(checked.check.adding(gap), gap: AgentGap(title: title, gap), phone: phoneFile.path)
            }
            var saved: String?
            if request.save == true { saved = try await saveThumbnail(clip, design: design, version: request.version == nil ? nil : letter).path }
            let k = 1920 / Double(sources.frame.width)
            return .success(AgentThumbnail(path: file.path, savedPath: saved, width: image.width, height: image.height, design: design, version: letter,
                                           speakerFound: sources.cutout != nil,
                                           speaker: sources.cutout.map { WireRect(CGRect(x: $0.box.minX * k, y: $0.box.minY * k,
                                                                                         width: $0.box.width * k, height: $0.box.height * k)) },
                                           check: check))
        } catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid("The thumbnail could not be made: \(error.localizedDescription)")) }
    }
}

/// A rendered thumbnail: where to look at it, where it was saved, and what it was made from.
struct AgentThumbnail: Encodable {
    var path: String
    var savedPath: String?
    var width: Int
    var height: Int
    var design: ThumbnailDesign
    /// A, B or C: the version drawn.
    var version: String
    var speakerFound: Bool
    /// The speaker's box in design pixels of a 1920×1080 frame.
    var speaker: WireRect?
    /// With check: what does not read on a phone in 0.5 s.
    var check: AgentPhoneCheck?
}

/// The check of a thumbnail, for an agent: each finding (kind, level, the phone sizes, a
/// message), the word count, the title's letter size and the face's box in design pixels
/// of a 1920×1080 frame, `gap` (the thumbnail's words against the video's title), `path`
/// (the eye path), and `phone`, a PNG of the design at both sizes.
struct AgentPhoneCheck: Encodable {
    var reads: Bool
    var findings: [PhoneCheck.Finding]
    var words: Int
    var titleSize: Double
    var face: WireRect?
    var gap: AgentGap
    /// Where the eye goes, in order: the face, then the words by size, clarity and colour.
    var path: [AgentEyeStop]
    var phone: String

    init(_ check: PhoneCheck, gap: AgentGap, phone: String) {
        reads = check.reads
        findings = check.findings
        words = check.words
        titleSize = (check.titleSize * 10).rounded() / 10
        face = check.face.map { WireRect($0.integral) }
        self.gap = gap
        path = check.path.enumerated().map { AgentEyeStop(step: $0.offset + 1, $0.element) }
        self.phone = phone
    }
}

/// One stop of the eye path, for an agent: its place on the path, what it is (face,
/// accent, title, tag, picture), its words, and its box in design pixels of 1920×1080.
struct AgentEyeStop: Encodable {
    var step: Int
    var kind: EyeStop.Kind
    var text: String
    var box: WireRect

    init(step: Int, _ stop: EyeStop) {
        self.step = step
        kind = stop.kind
        text = stop.text
        box = WireRect(stop.box.rect.integral)
    }
}

/// The information gap, for an agent: the video title compared, the thumbnail's words it
/// repeats, the runs of words both have, the words the thumbnail adds, and the share of
/// the thumbnail's important words that the title has (0 to 1).
struct AgentGap: Encodable {
    var title: String
    var repeated: [String]
    var phrases: [String]
    var added: [String]
    var overlap: Double

    init(title: String, _ gap: InformationGap) {
        self.title = title
        repeated = gap.repeated
        phrases = gap.phrases
        added = gap.added
        overlap = (gap.overlap * 100).rounded() / 100
    }
}
