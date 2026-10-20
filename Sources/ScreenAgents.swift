import CoreGraphics
import Foundation

// Screen + speaker for local agents (docs/plans/screen-speaker.md, section 8): the wire
// commands as `EditCommand`s, and the screen as `state` shows it.

extension AgentState {
    /// A recording's screen as an agent needs it. Times are edited-recording seconds;
    /// `covered` is where the screen file has footage (outside it, its first or last frame
    /// holds), `picture` the part of the screen recording shown.
    struct ScreenState: Encodable {
        struct Bubble: Encodable { var corner: String; var size: Double; var face: WirePoint?; var shape: String; var corners: Double }
        struct Span: Encodable { var id: UUID; var start: Double; var end: Double; var duration: Double; var layout: String }
        var path: String
        var name: String
        var media: Media
        var offset: Double
        var crop: WireRect?
        var picture: WireRect
        var layout: String
        var bubble: Bubble
        var layouts: [Span]
        /// Zooms on the screen; targets are in the screen recording's pixels.
        var zooms: [Zoom]
        var covered: [[Double]]
        var missing: Bool
        /// Callouts whose point never shows: over their time the layout hides the screen,
        /// or a screen zoom leaves the point out.
        var hiddenCallouts: [UUID]
    }
}

extension AppModel {
    static func screenState(_ clip: ProjectClip) -> AgentState.ScreenState? {
        guard let screen = clip.screen else { return nil }
        let info = screen.info
        return AgentState.ScreenState(
            path: screen.url.path, name: screen.name,
            media: .init(width: info.width, height: info.height, duration: info.duration, fps: info.fps,
                         fpsExpression: info.fpsExpression, hasAudio: info.hasAudio, hdr: info.hdrLabel),
            offset: screen.offset, crop: screen.crop.map(WireRect.init), picture: WireRect(screen.picture),
            layout: screen.layout.rawValue,
            bubble: .init(corner: screen.bubble.corner.rawValue, size: screen.bubble.size, face: screen.bubble.face.map(WirePoint.init),
                          shape: screen.bubble.shape.rawValue, corners: screen.bubble.corners),
            layouts: screen.spans.map { .init(id: $0.id, start: $0.start, end: $0.end, duration: $0.duration, layout: $0.layout.rawValue) },
            zooms: screen.zooms.map { .init(id: $0.id, start: $0.start, hold: $0.hold, level: $0.level, end: $0.end, target: WirePoint($0.target)) },
            covered: screen.covered(on: clip.timeline).map { [$0.lowerBound, $0.upperBound] },
            missing: !FileManager.default.fileExists(atPath: screen.url.path),
            hiddenCallouts: hiddenCallouts(clip.item()))
    }

    static func hiddenCallouts(_ item: VideoItem) -> [UUID] {
        let hidden = item.hiddenCallouts
        return (item.graphics?.items ?? []).map(\.id).filter(hidden.contains)
    }

    /// Where the speaker's face is, in source pixels, at an edited time; nil when Apple
    /// Vision finds nobody.
    func speakerFace(_ clip: ProjectClip, at time: Double) async throws -> CGPoint? {
        guard let info = clip.info else { return nil }
        let image = try await sourceFrame(clip, at: time)
        guard let found = try ShortFraming.speaker(in: image) else { return nil }
        let k = Double(info.width) / Double(image.width)
        return CGPoint(x: found.x * k, y: found.y * k)
    }

    /// The face for a command that asks for it: updateScreen with bubble face "speaker", or
    /// setScreen on a recording that has no screen yet (a first screen starts on the face).
    func speakerFace(for command: WireCommand, in document: VideoProject) async throws -> CGPoint? {
        guard let id = command.clipID, let clip = document.clips.first(where: { $0.id == id }), clip.info != nil else { return nil }
        let asked = command.type == "updateScreen" && command.screen?["bubble"]?.object?["face"] == .string("speaker")
        let first = command.type == "setScreen" && clip.screen == nil
        guard asked || first else { return nil }
        let duration = clip.timeline.duration
        let face = try? await speakerFace(clip, at: duration / 2)
        if asked, face == nil {
            throw EditError.invalid("Apple Vision found nobody in the recording at \(PublishInfo.timestamp(duration / 2)). Give the face as {x, y} in source pixels.")
        }
        return face
    }

    /// The box inside the screen recording's dark border, for updateScreen with crop
    /// "border"; the whole recording when it has no border.
    func screenBorder(for command: WireCommand, in document: VideoProject) async throws -> CGRect? {
        guard command.type == "updateScreen", command.screen?["crop"] == .string("border"), let id = command.clipID,
              let screen = document.clips.first(where: { $0.id == id })?.screen else { return nil }
        return try await FFmpeg.screenBorder(screen.url, info: screen.info) ?? screen.info.fullFrame
    }

    /// One screen command as an `EditCommand`, against the committed document.
    static func resolveScreen(_ wire: WireCommand, in document: VideoProject, probed: [String: MediaInfo], face: CGPoint?,
                              border: CGRect? = nil) throws -> EditCommand {
        guard let id = wire.clipID else { throw EditError.invalid("\(wire.type) needs clipID.") }
        guard let clip = document.clips.first(where: { $0.id == id }) else { throw EditError.notFound("No recording \(id) in this project.") }
        if wire.timeSpace == "movie" { throw EditError.invalid("Layout times are recording times; leave timeSpace out.") }
        func current() throws -> ScreenTrack {
            guard let screen = clip.screen else {
                throw EditError.invalid("Recording \(id) has no screen recording. Add one with setScreen first.")
            }
            return screen
        }
        func kind(_ name: String?) throws -> ScreenLayout? {
            guard let name else { return nil }
            guard let layout = ScreenLayout(rawValue: name) else {
                throw EditError.invalid("Unknown layout \"\(name)\". Layouts: \(ScreenLayout.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return layout
        }
        func span(_ value: WireLayout, keeping old: LayoutSpan? = nil) throws -> LayoutSpan {
            var result = old ?? LayoutSpan(id: value.id ?? wire.layoutID ?? UUID(), start: 0, end: 0, layout: .speaker)
            if let start = value.start {
                let length = (value.end ?? result.end) - (value.end == nil ? result.start : start)
                result.start = start
                result.end = start + length
            } else if old == nil {
                throw EditError.invalid("A new layout needs start and end.")
            }
            if let end = value.end { result.end = end }
            if let layout = try kind(value.layout) { result.layout = layout }
            else if old == nil { throw EditError.invalid("A new layout needs layout: speaker, screen or split.") }
            return result
        }
        switch wire.type {
        case "setScreen":
            guard let path = wire.path, let info = probed[path] else { throw EditError.invalid("setScreen needs path, a local video file.") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard url.standardizedFileURL.path != clip.url.standardizedFileURL.path else {
                throw EditError.invalid("The screen recording must be another file than the recording itself.")
            }
            var screen = clip.screen ?? ScreenTrack(url: url, info: info)
            screen.url = url
            screen.info = info
            if let crop = screen.crop, !info.fullFrame.contains(crop) { screen.crop = nil }
            if let offset = wire.offset { screen.offset = offset }
            if clip.screen == nil, let face { screen.bubble.face = face }
            return .setScreen(clip: id, screen: screen)
        case "updateScreen":
            guard let patch = wire.screen else { throw EditError.invalid("updateScreen needs screen, the keys to change.") }
            return .setScreen(clip: id, screen: try mergedScreen(patch, onto: try current(), face: face, border: border))
        case "removeScreen":
            _ = try current()
            return .setScreen(clip: id, screen: nil)
        case "addLayout":
            guard var value = wire.layout else { throw EditError.invalid("addLayout needs layout: {start, end, layout}.") }
            _ = try current()
            if value.id == nil { value.id = wire.layoutID }
            return .addLayout(clip: id, span: try span(value))
        case "updateLayout":
            guard let value = wire.layout else { throw EditError.invalid("updateLayout needs layout, the keys to change.") }
            guard let layoutID = wire.layoutID ?? value.id else { throw EditError.invalid("updateLayout needs layoutID.") }
            guard let old = try current().spans.first(where: { $0.id == layoutID }) else {
                throw EditError.notFound("No layout \(layoutID) on recording \(id). state.clips[].screen.layouts lists them.")
            }
            return .updateLayout(clip: id, span: try span(value, keeping: old))
        case "removeLayout":
            guard let layoutID = wire.layoutID else { throw EditError.invalid("removeLayout needs layoutID.") }
            _ = try current()
            return .removeLayout(clip: id, span: layoutID)
        case "replaceLayouts":
            guard let values = wire.layouts else { throw EditError.invalid("replaceLayouts needs layouts: [{start, end, layout}].") }
            _ = try current()
            return .replaceLayouts(clip: id, spans: try values.map { try span($0) })
        case "addScreenZoom":
            _ = try current()
            guard let start = wire.start, let target = wire.target else {
                throw EditError.invalid("addScreenZoom needs start (edited seconds) and target ({x, y} in the screen recording's pixels).")
            }
            return .addScreenZoom(clip: id, zoom: ZoomShot(id: wire.zoomID ?? UUID(), start: start, hold: wire.hold ?? 2,
                                                           level: wire.level ?? AppModel.defaultScreenZoomLevel, target: target.point))
        case "updateScreenZoom":
            guard let zoomID = wire.zoomID else { throw EditError.invalid("updateScreenZoom needs zoomID.") }
            guard var shot = try current().zooms.first(where: { $0.id == zoomID }) else {
                throw EditError.notFound("No screen zoom \(zoomID) on recording \(id). state.clips[].screen.zooms lists them.")
            }
            if let start = wire.start { shot.start = start }
            if let hold = wire.hold { shot.hold = hold }
            if let level = wire.level { shot.level = level }
            if let target = wire.target { shot.target = target.point }
            return .updateScreenZoom(clip: id, zoom: shot)
        case "removeScreenZoom":
            guard let zoomID = wire.zoomID else { throw EditError.invalid("removeScreenZoom needs zoomID.") }
            _ = try current()
            return .removeScreenZoom(clip: id, zoom: zoomID)
        case "replaceScreenZooms":
            guard let values = wire.zooms else { throw EditError.invalid("replaceScreenZooms needs zooms: [{start, hold, level, target}].") }
            _ = try current()
            return .replaceScreenZooms(clip: id, zooms: values.map {
                ZoomShot(id: $0.id ?? UUID(), start: $0.start, hold: $0.hold ?? 2, level: $0.level ?? AppModel.defaultScreenZoomLevel, target: $0.target.point)
            })
        default:
            throw EditError(code: .unsupportedCapability, message: "Unknown screen command \(wire.type).")
        }
    }

    /// The screen keys named in `patch` replace the current ones; the rest are kept.
    static func mergedScreen(_ patch: [String: JSONValue], onto screen: ScreenTrack, face: CGPoint?, border: CGRect? = nil) throws -> ScreenTrack {
        let known: Set<String> = ["offset", "crop", "layout", "bubble"]
        if let unknown = patch.keys.sorted().first(where: { !known.contains($0) }) {
            throw EditError.invalid("Unknown screen key \"\(unknown)\". Keys: \(known.sorted().joined(separator: ", ")).")
        }
        var result = screen
        if let value = patch["offset"] {
            guard let offset = value.number else { throw EditError.invalid("offset is a number of seconds.") }
            result.offset = offset
        }
        if let value = patch["crop"] {
            if value == .null { result.crop = nil } else if value == .string("border") {
                result.crop = border.flatMap { $0 == screen.info.fullFrame ? nil : $0 }
            } else {
                guard let rect = try? AgentProtocol.decoder.decode(WireRect.self, from: AgentProtocol.encoder.encode(value)) else {
                    throw EditError.invalid("crop is {x, y, width, height} in the screen recording's pixels, \"border\" to cut away a dark border, or null for all of it.")
                }
                result.crop = rect.rect
            }
        }
        if let value = patch["layout"] {
            guard let name = value.string, let layout = ScreenLayout(rawValue: name) else {
                throw EditError.invalid("layout is one of: \(ScreenLayout.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            result.layout = layout
        }
        if let value = patch["bubble"] {
            guard let bubble = value.object else { throw EditError.invalid("bubble is {corner, size, face, shape, corners}.") }
            let keys: Set<String> = ["corner", "size", "face", "shape", "corners"]
            if let unknown = bubble.keys.sorted().first(where: { !keys.contains($0) }) {
                throw EditError.invalid("Unknown bubble key \"\(unknown)\". Keys: corner, size, face, shape, corners.")
            }
            if let value = bubble["shape"] {
                guard let name = value.string, let shape = SpeakerBubble.Shape(rawValue: name) else {
                    throw EditError.invalid("shape is one of: \(SpeakerBubble.Shape.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                result.bubble.shape = shape
            }
            if let value = bubble["corners"] {
                guard let corners = value.number else {
                    throw EditError.invalid("corners is a number: a rounded square's corner radius as a share of its side.")
                }
                result.bubble.corners = corners
            }
            if let value = bubble["corner"] {
                guard let name = value.string, let corner = SpeakerBubble.Corner(rawValue: name) else {
                    throw EditError.invalid("corner is one of: \(SpeakerBubble.Corner.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                result.bubble.corner = corner
            }
            if let value = bubble["size"] {
                guard let size = value.number else { throw EditError.invalid("size is a number: the bubble's diameter as a share of the frame's height.") }
                result.bubble.size = size
            }
            if let value = bubble["face"] {
                switch value {
                case .null: result.bubble.face = nil
                case .string("speaker"): result.bubble.face = face
                default:
                    guard let point = try? AgentProtocol.decoder.decode(WirePoint.self, from: AgentProtocol.encoder.encode(value)) else {
                        throw EditError.invalid("face is {x, y} in the recording's source pixels, \"speaker\" to find it with Apple Vision, or null.")
                    }
                    result.bubble.face = point.point
                }
            }
        }
        return result
    }
}
