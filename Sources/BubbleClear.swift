import CoreGraphics
import Foundation

// Graphics clear of the speaker's bubble. In the Screen layout the speaker is a small
// picture in a corner (the bubble), and no card may cover the face in it. The app writes
// the bubble's box into each column card while the bubble shows with it (`props.clear`);
// the engine measures the card and moves it below a top bubble or above a bottom bubble,
// or beside the bubble when there is no room (`clearMove` in graphics.js). The owner's own
// move (`transform`) wins. `state` lists each graphic that still meets the bubble.

/// The box a column card keeps clear of: the bubble in design pixels of the 1920×1080
/// frame, and the side the card moves to.
struct BubbleClear: Equatable {
    enum Side: String { case below, above }
    var rect: CGRect
    var side: Side

    /// The space the engine leaves between a moved card and the bubble (CLEAR_GAP).
    static let gap = 24.0

    var json: JSONValue {
        .object(["x": .number(Double(rect.minX)), "y": .number(Double(rect.minY)), "w": .number(Double(rect.width)),
                 "h": .number(Double(rect.height)), "side": .string(side.rawValue)])
    }
}

extension ScreenTrack {
    /// Each moment from `start` to `end` that a bubble starts to show, with that bubble:
    /// `start` when the Screen layout is in force then, and each change in the Screen layout
    /// after it (a layout part can move the bubble). Empty when no bubble shows.
    func bubbles(from start: Double, to end: Double, endScreen: Double?) -> [(time: Double, bubble: SpeakerBubble)] {
        var shown: [(time: Double, bubble: SpeakerBubble)] = []
        if layout(at: start, endScreen: endScreen) == .screen { shown.append((start, bubble(at: start, endScreen: endScreen))) }
        for change in changes(endScreen: endScreen) where change.to == .screen && change.time > start && change.time < end - 0.000001 {
            shown.append((change.time, change.bubble))
        }
        return shown
    }

    /// The first moment from `start` to `end` with the Screen layout in force, so a bubble
    /// shows; nil when it never does.
    func bubbleTime(from start: Double, to end: Double, endScreen: Double?) -> Double? {
        bubbles(from: start, to: end, endScreen: endScreen).first?.time
    }
}

extension VideoItem {
    /// The box of `bubble` (nil: the screen's own) in the Screen layout, in design pixels
    /// of the 1920×1080 frame; nil without a screen recording.
    func bubbleBox(_ bubble: SpeakerBubble? = nil) -> CGRect? {
        guard let screen, let info else { return nil }
        let crop = (self.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let geometry = LayoutGeometry(track: screen, crop: crop)
        guard geometry.frame.width > 0 else { return nil }
        let unit = 1920 / Double(geometry.frame.width)
        let rect = geometry.speakerPlace(.screen, bubble: bubble).rect
        return CGRect(x: Double(rect.minX) * unit, y: Double(rect.minY) * unit, width: Double(rect.width) * unit, height: Double(rect.height) * unit)
    }

    /// Each place of the bubble while a graphic shows from `start` to `end`: the moment it
    /// starts to show there, and its box. A place that shows again is listed once.
    func bubblePlaces(from start: Double, to end: Double, endScreen: Double?) -> [(time: Double, box: CGRect)] {
        guard let screen else { return [] }
        var places: [(time: Double, box: CGRect)] = []
        for shown in screen.bubbles(from: start, to: end, endScreen: endScreen) {
            guard let box = bubbleBox(shown.bubble), !places.contains(where: { $0.box == box }) else { continue }
            places.append((shown.time, box))
        }
        return places
    }

    /// The bubble a card keeps clear of: the one that shows when the card is fully in
    /// (0.3 s after it starts, as for logo badges), else the first that shows with it.
    func clearBubble(for graphic: Graphic, endScreen: Double?) -> BubbleClear? {
        guard let screen else { return nil }
        let settled = min(graphic.end - 0.000001, graphic.start + 0.3)
        let bubble = screen.layout(at: settled, endScreen: endScreen) == .screen
            ? screen.bubble(at: settled, endScreen: endScreen)
            : screen.bubbles(from: graphic.start, to: graphic.end, endScreen: endScreen).first?.bubble
        guard let bubble, let box = bubbleBox(bubble) else { return nil }
        return BubbleClear(rect: box, side: box.midY < 540 ? .below : .above)
    }

    /// `track` with `clear` in the props of each column card that shows while a bubble
    /// does; any other `clear` is removed, so only the app's own box reaches the engine.
    func placingClear(_ track: GraphicsTrack) -> GraphicsTrack {
        guard track.canvas == .landscape, track.items.contains(where: { $0.kind.zone == .column }) else { return track }
        let endScreen = track.endScreen?.start
        var placed = track
        for index in placed.items.indices where placed.items[index].kind.zone == .column {
            placed.items[index].props["clear"] = clearBubble(for: placed.items[index], endScreen: endScreen)?.json
        }
        return placed
    }

    /// Each graphic of the placed `track` that meets a place of the bubble while the bubble
    /// shows there, from `bounds`, the engine's measures of that track: one item for each
    /// place it meets. A panel's box meets the bubble where the picture has moved aside for
    /// the panel.
    func bubbleOverlaps(_ track: GraphicsTrack, bounds: [UUID: GraphicBounds]) -> [AgentState.BubbleOverlap] {
        guard track.canvas == .landscape else { return [] }
        let endScreen = track.endScreen?.start
        var overlaps: [AgentState.BubbleOverlap] = []
        for graphic in track.items.sorted(by: { $0.start < $1.start }) where graphic.kind.isPlaceable {
            guard let measured = bounds[graphic.id] else { continue }
            let rect = measured.placed(graphic.transform)
            let cleared = graphic.props["clear"]?.object.flatMap { box -> CGRect? in
                guard let x = box["x"]?.number, let y = box["y"]?.number, let w = box["w"]?.number, let h = box["h"]?.number else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            }
            for place in bubblePlaces(from: graphic.start, to: graphic.end, endScreen: endScreen) {
                let bubble = graphic.kind.zone == .panel && track.style.moveVideo
                    ? place.box.offsetBy(dx: -GraphicsTrack.shiftFraction * 1920, dy: 0) : place.box
                let meets = rect.intersection(bubble)
                guard !meets.isNull, meets.width > 0.5, meets.height > 0.5 else { continue }
                let why: String
                if graphic.transform.map({ !$0.isIdentity }) ?? false { why = "transform" }
                else if graphic.kind.zone == .panel { why = "panel" }
                else if graphic.kind.zone == .column { why = cleared == place.box ? "noRoom" : "otherBubble" }
                else { why = "badge" }
                overlaps.append(.init(graphicID: graphic.id, kind: graphic.kind.rawValue, start: graphic.start, end: graphic.end, at: place.time,
                                      rect: WireRect(rect.integral), bubble: WireRect(bubble), why: why))
            }
        }
        return overlaps
    }
}

extension AgentState {
    /// A graphic that meets the speaker's bubble in the Screen layout, so it covers the
    /// face. Boxes are design pixels of the 1920×1080 frame.
    struct BubbleOverlap: Encodable, Equatable {
        var graphicID: UUID
        var kind: String
        var start: Double, end: Double
        /// The first moment the bubble shows at this place while the graphic shows.
        var at: Double
        /// The graphic as drawn, once fully in.
        var rect: WireRect
        var bubble: WireRect
        /// Why the app did not move it clear: transform (its own move wins: move it again),
        /// noRoom (no place clear of the bubble in the safe area), otherBubble (the bubble
        /// moves while the card shows, and the app moved the card clear of the bubble that
        /// shows when the card is fully in), panel (the app does not move panels) or badge
        /// (a logo badge moved by hand onto the bubble).
        var why: String
    }
}

extension AppModel {
    /// Measures, with the engine, the graphics of each recording whose bubble shows with a
    /// graphic, so `state` can say which graphics still meet the bubble. The measures stay
    /// until the graphics, the layouts or the bubble change.
    func measureGraphicsForBubble() async {
        let clips = Set(committedProject.clips.map(\.id))
        bubbleMeasures = bubbleMeasures.filter { clips.contains($0.key) }
        for clip in committedProject.clips {
            guard clip.isOn(.graphics), let info = clip.info, clip.screen != nil else { bubbleMeasures[clip.id] = nil; continue }
            let item = clip.item()
            guard let track = item.placedGraphics,
                  track.items.contains(where: { $0.kind.isPlaceable && item.screen?.bubbleTime(from: $0.start, to: $0.end, endScreen: track.endScreen?.start) != nil })
            else { bubbleMeasures[clip.id] = nil; continue }
            let duration = clip.timeline.duration
            guard let key = try? track.engineData(duration: duration, fps: info.fpsExpression) else { continue }
            if bubbleMeasures[clip.id]?.key == key { continue }
            guard let bounds = try? await GraphicsSnapshot.bounds(track, duration: duration, fps: info.fpsExpression) else { continue }
            bubbleMeasures[clip.id] = (key, bounds)
        }
    }

    /// What `state` says for one recording: nil when its bubble never shows with a graphic,
    /// or the graphics are not measured yet.
    func bubbleOverlaps(_ clip: ProjectClip) -> [AgentState.BubbleOverlap]? {
        guard clip.isOn(.graphics), let info = clip.info, let measured = bubbleMeasures[clip.id] else { return nil }
        let item = clip.item()
        guard let track = item.placedGraphics,
              (try? track.engineData(duration: clip.timeline.duration, fps: info.fpsExpression)) == measured.key else { return nil }
        return item.bubbleOverlaps(track, bounds: measured.bounds)
    }
}
