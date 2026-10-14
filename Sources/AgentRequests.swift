import AppKit
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
    var time: Double?
    /// "recording" (the default) or "movie". Movie time is never assumed.
    var timeSpace: String?
    var path: String?
    var overwrite: Bool?
    var scope: String?
    var kind: String?
    var job: UUID?
    var cropped: Bool?
    /// A preview without the recording's colour stage, to pair with a corrected one.
    var original: Bool?
    var threshold: Double?
    var minimum: Double?
    var padding: Double?
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
}

struct WireZoom: Codable, Equatable {
    var id: UUID?
    var start: Double
    var hold: Double?
    var level: Double?
    var target: WirePoint
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

    static let types = [
        "splitSection", "trimSection", "deleteSection", "moveSection", "setSectionSpeed", "replaceSections",
        "setCrop", "setAspect", "addBlurArea", "updateBlurArea", "removeBlurArea", "replaceBlurAreas",
        "addZoom", "updateZoom", "removeZoom", "replaceZooms", "setMovieOrder", "setIncludedInMovie",
        "setMovieCanvas", "setExportSettings", "setSubtitles", "clearSubtitles", "addMedia", "removeMedia",
        "relinkMedia", "setInputProfile", "importTechnicalLUT", "clearTechnicalLUT", "setColorCorrection",
        "setColorAdjustments", "resetColorAdjustments", "copyColorAdjustments",
    ]

    /// Files that must be probed before this command can be resolved.
    var mediaPaths: [String] {
        switch type {
        case "addMedia": return paths ?? []
        case "relinkMedia": return path.map { [$0] } ?? []
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
    var analyzeKinds = ["silence", "zooms"]
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
    }
    struct Area: Encodable { var id: UUID; var rect: WireRect }
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
    }
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
        var clip: UUID?, section: UUID?, sections: [UUID], zoom: UUID?, blurArea: UUID?
        var playhead: Double, movieMode: Bool, movieTime: Double
    }
    struct Busy: Encodable {
        var exporting: Bool, interactionInProgress: Bool, agentsPaused: Bool, runningJobs: [UUID]
    }
    struct History: Encodable { var undo: AgentHistoryStep?; var redo: AgentHistoryStep? }

    var sessionID: UUID
    var projectID: UUID
    var revision: Int
    var title: String
    var file: String?
    var unsaved: Bool
    var busy: Busy
    var history: History
    var selection: Selection
    var settings: JSONValue
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
    static let agentMethods = ["sessions", "state", "apply", "events", "undo", "redo", "save", "preview",
                               "analyze", "export", "job", "cancel", "reveal"]

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
        case "state":
            if let refusal = checkSession(request, required: false) { return agentResponse(Result<AgentEmpty, EditError>.failure(refusal), instanceID) }
            return agentResponse(.success(agentState()), instanceID)
        case "events": return agentResponse(agentEvents(request), instanceID)
        case "preview": return agentResponse(await agentPreview(request), instanceID)
        case "job": return agentResponse(agentJob(request), instanceID)
        case "reveal": return agentResponse(agentReveal(request), instanceID)
        case "apply", "undo", "redo", "save", "export", "analyze", "cancel":
            return await idempotent(request, instanceID: instanceID) {
                switch request.method {
                case "apply": return self.agentResponse(await self.agentApply(request), instanceID)
                case "undo", "redo": return self.agentResponse(self.agentHistory(request), instanceID)
                case "save": return self.agentResponse(self.agentSave(request), instanceID)
                case "export": return self.agentResponse(self.agentExport(request), instanceID)
                case "analyze": return self.agentResponse(self.agentAnalyze(request), instanceID)
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
    private func idempotent(_ request: AgentRequest, instanceID: UUID, _ body: () async -> Data) async -> Data {
        func refuse(_ code: EditError.Code, _ message: String) -> Data {
            agentResponse(Result<AgentEmpty, EditError>.failure(EditError(code: code, message: message)), instanceID)
        }
        guard let id = request.requestID, !id.isEmpty, id.count <= 128 else {
            return refuse(.invalidRequest, "Edits need a requestID (up to 128 characters) so a retry is never applied twice.")
        }
        let hash = Self.fingerprint((try? AgentProtocol.encoder.encode(request)) ?? Data())
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

    private func checkSession(_ request: AgentRequest, required: Bool) -> EditError? {
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

    private func agentOrigin(_ request: AgentRequest) -> EditOrigin {
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
            for segment in clip.timeline.segments {
                sections.append(.init(id: segment.id, start: segment.start, end: segment.end, speed: segment.speed,
                                      editedStart: offset, editedDuration: segment.duration))
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
                sections: sections, blurAreas: clip.blurRegions.map { .init(id: $0.id, rect: WireRect($0.rect)) },
                zooms: clip.zoomShots.map { .init(id: $0.id, start: $0.start, hold: $0.hold, level: $0.level, end: $0.end,
                                                  target: WirePoint($0.target)) },
                color: clip.info.map { colorState(clip, info: $0, settings: document.settings) })
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
                             zoom: selectedShotID, blurArea: selectedRegionID,
                             playhead: previewTime, movieMode: isMovieMode, movieTime: movieTime),
            settings: (try? JSONValue.from(document.settings)) ?? .null,
            movie: .init(canvas: (document.movieSettings ?? MovieSettings()).canvas.rawValue, duration: movieOffset, clips: movieClips),
            clips: clips)
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
            let commands = try wire.map { try resolve($0, in: document, probed: probed, tables: tables) }
            let label = request.label.map { String($0.prefix(80)) }
            let result = perform(commands, label: label, origin: agentOrigin(request), expectedRevision: expected,
                                 dryRun: request.dryRun ?? false)
            return result.map {
                AgentReceipt(revision: $0.revision, transactionID: $0.transactionID, changed: $0.changed,
                             dryRun: request.dryRun ?? false, createdIDs: $0.createdIDs, removedZooms: $0.removedZooms,
                             affectedClips: $0.affectedClips)
            }
        } catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid(error.localizedDescription)) }
    }

    /// One wire command as an `EditCommand`, against the committed document.
    private func resolve(_ wire: WireCommand, in document: VideoProject, probed: [String: MediaInfo],
                         tables: [String: LUTAssetRef] = [:]) throws -> EditCommand {
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
        case "setCrop":
            return .setCrop(clip: try field(wire.clipID, "clipID"), rect: try field(wire.rect, "rect").rect)
        case "setAspect":
            return .setAspect(clip: try field(wire.clipID, "clipID"), preset: try field(wire.preset, "preset"))
        case "addBlurArea":
            return .addBlurArea(clip: try field(wire.clipID, "clipID"),
                                area: BlurRegion(id: wire.areaID ?? UUID(), rect: try field(wire.rect, "rect").rect))
        case "updateBlurArea":
            return .updateBlurArea(clip: try field(wire.clipID, "clipID"), area: try field(wire.areaID, "areaID"),
                                   rect: try field(wire.rect, "rect").rect)
        case "removeBlurArea":
            return .removeBlurArea(clip: try field(wire.clipID, "clipID"), area: try field(wire.areaID, "areaID"))
        case "replaceBlurAreas":
            return .replaceBlurAreas(clip: try field(wire.clipID, "clipID"), areas: try field(wire.areas, "areas").map {
                BlurRegion(id: $0.id ?? UUID(), rect: $0.rect.rect)
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
        default:
            throw EditError(code: .unsupportedCapability,
                            message: "Unknown command type \"\(wire.type)\". Types: \(WireCommand.types.joined(separator: ", ")).")
        }
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

    static let exportSettingKeys: Set<String> = {
        var every = ExportSettings()
        every.outputFolder = URL(fileURLWithPath: "/")
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
                editorMode = .zoom; selectedShotID = zoom
                scrubToShot(shot)
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
        let document = committedProject
        let requestedRevision = revision
        do {
            let time = try require(request.time, "time")
            let (clipID, local): (UUID, Double)
            if request.timeSpace == "movie" { (clipID, local) = try movieLocation(time, in: document) }
            else { (clipID, local) = (try require(request.clip, "clip"), time) }
            guard let clip = document.clips.first(where: { $0.id == clipID }) else { throw EditError.notFound("No recording \(clipID).") }
            guard let info = clip.info else { throw EditError(code: .missingMedia, message: "That recording is still loading.") }
            let timeline = clip.timeline
            guard local.isFinite, local >= 0, local <= timeline.duration else {
                throw EditError.invalid("Time must be within the edited recording (0–\(timeline.duration) s).")
            }
            let source = timeline.location(at: local)?.source ?? 0
            let cropped = request.cropped ?? false
            let settings = document.settings
            let data = try await FFmpeg.thumbnail(
                url: clip.url, at: source, duration: info.duration, regions: clip.blurRegions.map(\.rect),
                style: settings.blurStyle, strength: settings.blurStrength, toneMap: info.isHDR && settings.toneMapHDR,
                color: clip.item().colorFilters(settings, original: request.original ?? false),
                subtitles: clip.subtitles, subtitleStyle: settings.subtitleForceStyle,
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
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw EditError.invalid("The frame could not be encoded.")
            }
            let directory = agentArtifactsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(
                "preview-r\(requestedRevision)-\(clipID.uuidString.prefix(8))-\(Int((local * 1000).rounded()))ms-\(UUID().uuidString.prefix(6)).png")
            try png.write(to: file, options: .atomic)
            return .success(AgentPreview(path: file.path, revision: requestedRevision, clip: clipID, time: local,
                                         sourceTime: source, width: image.width, height: image.height, cropped: cropped,
                                         original: request.original ?? false))
        } catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid("The frame could not be rendered: \(error.localizedDescription)")) }
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

    private func startJob(id: UUID = UUID(), kind: String, clip: UUID?, origin: EditOrigin,
                          work: @escaping @MainActor () async throws -> JSONValue) -> AgentJob {
        let job = AgentJob(id: id, kind: kind, status: "running", progress: kind == "export" ? 0 : nil,
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
        case "zooms":
            return .success(startJob(kind: "analyze", clip: clipID, origin: agentOrigin(request)) {
                let suggestions = try await ZoomAnalyzer.analyze(item)
                struct Suggestion: Encodable { var start: Double; var hold: Double; var level: Double; var target: WirePoint; var score: Double }
                struct Zooms: Encodable { var kind = "zooms"; var suggestions: [Suggestion] }
                return try JSONValue.from(Zooms(suggestions: suggestions.map {
                    Suggestion(start: $0.shot.start, hold: $0.shot.hold, level: $0.shot.level, target: WirePoint($0.shot.target), score: $0.score)
                }))
            })
        default:
            return .failure(.invalid("kind must be \"silence\" or \"zooms\"."))
        }
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
                case .recording(let item, let info):
                    try await FFmpeg.export(input: item.url, output: temporary, info: info,
                                            crop: (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame),
                                            regions: item.blurRegions.map(\.rect), zoomShots: item.zoomShots,
                                            segments: item.segments, settings: exportSettings, subtitles: item.subtitles,
                                            color: item.colorStage(exportSettings), effects: item.blurEffects,
                                            onProgress: progress)
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
}
