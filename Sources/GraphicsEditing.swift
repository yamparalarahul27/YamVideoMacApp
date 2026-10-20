import AppKit
import Foundation
import UniformTypeIdentifiers

/// One step into a graphic's props: a key in an object, or a position in a list.
enum GraphicPropPath: Hashable {
    case key(String)
    case index(Int)
}

extension JSONValue {
    /// The value at `path`, or nil when the path does not exist.
    func value(at path: [GraphicPropPath]) -> JSONValue? {
        guard let first = path.first else { return self }
        switch (self, first) {
        case (.object(let values), .key(let key)): return values[key]?.value(at: Array(path.dropFirst()))
        case (.array(let values), .index(let index)) where values.indices.contains(index):
            return values[index].value(at: Array(path.dropFirst()))
        default: return nil
        }
    }

    /// A copy with the value at `path` replaced. Missing object keys are created.
    func setting(_ newValue: JSONValue, at path: [GraphicPropPath]) -> JSONValue {
        guard let first = path.first else { return newValue }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.object(var values), .key(let key)):
            values[key] = (values[key] ?? .object([:])).setting(newValue, at: rest)
            return .object(values)
        case (.array(var values), .index(let index)) where values.indices.contains(index):
            values[index] = values[index].setting(newValue, at: rest)
            return .array(values)
        default: return self
        }
    }
}

extension AppModel {
    var selectedGraphic: Graphic? {
        guard let selectedGraphicID else { return nil }
        return selectedItem?.graphics?.items.first { $0.id == selectedGraphicID }
    }

    // MARK: Import

    /// Reads a graphics JSON file (as Tools/Graphics uses) onto the selected recording,
    /// replacing its graphics and style in one undo step.
    func importGraphics(from url: URL) {
        guard let index = selectedIndex, items[index].info != nil else {
            statusMessage = "Select a recording first."; return
        }
        do {
            let track = try GraphicsEngine.importFile(url)
            switch perform([.replaceGraphics(clip: items[index].id, graphics: track.items, style: track.style)],
                           label: "Import Graphics") {
            case .success:
                statusMessage = "Imported \(track.items.count) graphic\(track.items.count == 1 ? "" : "s") from \(url.lastPathComponent)."
            case .failure(let error):
                statusMessage = error.message
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func chooseGraphicsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a graphics file (graphics.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importGraphics(from: url)
    }

    // MARK: Editing one graphic

    /// Applies `transform` to one graphic. With a `gesture` key the change shows live and
    /// is committed as one undo step when the gesture ends; an edit the rules refuse
    /// (an overlap, or running past the end) leaves the graphic where it was.
    func mutateGraphic(_ id: UUID, gesture: String? = nil, label: String = "Edit Graphic", keepPreview: Bool = false,
                       _ transform: (inout Graphic) -> Void) {
        guard let index = selectedIndex,
              let graphic = items[index].graphics?.items.first(where: { $0.id == id }) else { return }
        var edited = graphic
        transform(&edited)
        guard edited != graphic else { return }
        let command = EditCommand.updateGraphic(clip: items[index].id, graphic: edited)
        if let gesture {
            _ = updateGesture(gesture, label: label, [command], keepPreview: keepPreview)
            return
        }
        if case .failure(let error) = perform([command], label: label) { statusMessage = error.message }
    }

    /// Moves a graphic so it starts at `start`, keeping its length, inside the recording.
    /// The end screen keeps its end where the video ends, so moving it changes its length,
    /// within YouTube's 5 to 20 seconds.
    func moveGraphic(_ id: UUID, to start: Double, live: Bool = false) {
        let duration = selectedItem?.editedDuration ?? 0
        mutateGraphic(id, gesture: live ? "graphic-move-\(id)" : nil, label: "Move Graphic") { graphic in
            if graphic.kind == .endScreen { graphic.place(endScreenStart: start, duration: duration); return }
            let length = graphic.length
            graphic.start = max(0, min(start, duration - length))
            graphic.end = graphic.start + length
        }
    }

    /// Moves one edge; the other stays. A graphic stays at least half a second long.
    func setGraphicEdge(_ id: UUID, start: Double? = nil, end: Double? = nil, live: Bool = false) {
        let duration = selectedItem?.editedDuration ?? 0
        mutateGraphic(id, gesture: live ? "graphic-edge-\(id)" : nil, label: "Change Graphic Length") { graphic in
            if graphic.kind == .endScreen {
                if let start { graphic.place(endScreenStart: start, duration: duration) }
                return
            }
            if let start { graphic.start = max(0, min(start, graphic.end - GraphicsTrack.minimumLength)) }
            if let end { graphic.end = min(duration, max(end, graphic.start + GraphicsTrack.minimumLength)) }
        }
    }

    /// Adds an end screen to the selected recording: the last 20 s, or as much of them as is
    /// clear of its other graphics, and selects it.
    func addEndScreen() {
        guard let index = selectedIndex, items[index].info != nil else { statusMessage = "Select a recording first."; return }
        let track = items[index].graphics ?? GraphicsTrack()
        let duration = items[index].editedDuration
        guard track.endScreen == nil else {
            selectedGraphicID = track.endScreen?.id
            statusMessage = "This recording already has an end screen."
            return
        }
        guard let span = track.newEndScreenSpan(duration: duration) else {
            statusMessage = "There is no room for an end screen: YouTube's end screen needs 5 to 20 s at the end with no other graphic showing."
            return
        }
        let graphic = Graphic(kind: .endScreen, start: span.start, end: span.end, props: EndScreen.defaultProps)
        switch perform([.addGraphic(clip: items[index].id, graphic: graphic)], label: "Add End Screen") {
        case .success: selectedGraphicID = graphic.id
        case .failure(let error): statusMessage = error.message
        }
    }

    /// A kinetic text from the playhead: the next 3 s of what is said, each word on the
    /// time it is spoken. Without a transcript it starts with words to replace.
    func addKineticText() {
        guard let index = selectedIndex, items[index].info != nil else { statusMessage = "Select a recording first."; return }
        let item = items[index]
        let start = min(max(0, previewTime), max(0, item.editedDuration - 1))
        let end = min(item.editedDuration, start + 3)
        let words = KineticText.words(item.transcript, timeline: item.timeline, from: start, to: end)
        let props: [String: JSONValue] = words.isEmpty ? ["text": .string("Your *big* words"), "layout": .string("line")]
            : ["words": .array(words), "layout": .string("line")]
        addCover(Graphic(kind: .kineticText, start: start, end: end, props: props), to: item, label: "Add Kinetic Text")
    }

    /// A section card at the playhead, for 2.5 s; its bar shows how far into the video it is.
    func addSectionCard() {
        guard let index = selectedIndex, items[index].info != nil else { statusMessage = "Select a recording first."; return }
        let item = items[index]
        let start = min(max(0, previewTime), max(0, item.editedDuration - 2.5))
        let graphic = Graphic(kind: .sectionCard, start: start, end: min(item.editedDuration, start + 2.5), props: ["title": .string("Section")])
        addCover(graphic, to: item, label: "Add Section Card")
    }

    private func addCover(_ graphic: Graphic, to item: VideoItem, label: String) {
        switch perform([.addGraphic(clip: item.id, graphic: graphic)], label: label) {
        case .success: selectedGraphicID = graphic.id
        case .failure(let error): statusMessage = error.message
        }
    }

    /// A kinetic text's words again from what is said over its time.
    func fillKineticWords(_ id: UUID) {
        guard let item = selectedItem else { return }
        mutateGraphic(id, label: "Kinetic Text Words") { graphic in
            let words = KineticText.words(item.transcript, timeline: item.timeline, from: graphic.start, to: graphic.end)
            guard !words.isEmpty else { return }
            graphic.props["words"] = .array(words)
            graphic.props["text"] = nil
        }
    }

    func setGraphicProp(_ id: UUID, at path: [GraphicPropPath], to value: JSONValue) {
        mutateGraphic(id, label: "Edit Graphic Text") { graphic in
            graphic.props = JSONValue.object(graphic.props).setting(value, at: path).object ?? graphic.props
        }
    }

    func setGraphicLook(_ id: UUID, _ look: GraphicsLook?) {
        mutateGraphic(id, label: "Graphic Look") { $0.look = look }
    }

    func setEndScreenLayout(_ id: UUID, videos: Int? = nil, side: EndScreenLayout.Side? = nil) {
        mutateGraphic(id, label: "End Screen Layout") { graphic in
            if let videos { graphic.props["videos"] = .number(Double(videos)) }
            if let side { graphic.props["side"] = .string(side.rawValue) }
        }
    }

    func moveSelectedGraphicToPlayhead() {
        guard let id = selectedGraphicID else { return }
        moveGraphic(id, to: previewTime)
    }

    func removeSelectedGraphic() {
        guard let index = selectedIndex, let id = selectedGraphicID else { return }
        if case .success = perform([.removeGraphic(clip: items[index].id, graphic: id)]) {
            selectedGraphicID = nil
        }
    }

    /// Plays from just before the graphic, so its entrance shows.
    func showGraphic(_ graphic: Graphic) {
        guard let item = selectedItem, item.editedDuration > 0 else { return }
        setPreviewFraction(max(0, graphic.start - 0.3) / item.editedDuration)
    }

    // MARK: Style

    func setGraphicsStyle(_ transform: (inout GraphicsStyle) -> Void) {
        guard let index = selectedIndex, items[index].info != nil else { return }
        var style = items[index].graphics?.style ?? GraphicsStyle()
        let before = style
        transform(&style)
        guard style != before else { return }
        if case .failure(let error) = perform([.setGraphicsStyle(clip: items[index].id, style: style)]) {
            statusMessage = error.message
        }
    }
}

extension Graphic {
    /// An end screen starting at `start` (or as near as YouTube's 5 to 20 seconds allow),
    /// ending where the video ends.
    mutating func place(endScreenStart start: Double, duration: Double) {
        end = duration
        self.start = max(0, min(max(start, duration - EndScreen.lengths.upperBound), duration - EndScreen.lengths.lowerBound))
    }
}
