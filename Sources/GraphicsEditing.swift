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
    func mutateGraphic(_ id: UUID, gesture: String? = nil, label: String = "Edit Graphic",
                       _ transform: (inout Graphic) -> Void) {
        guard let index = selectedIndex,
              let graphic = items[index].graphics?.items.first(where: { $0.id == id }) else { return }
        var edited = graphic
        transform(&edited)
        guard edited != graphic else { return }
        let command = EditCommand.updateGraphic(clip: items[index].id, graphic: edited)
        if let gesture {
            _ = updateGesture(gesture, label: label, [command])
            return
        }
        if case .failure(let error) = perform([command], label: label) { statusMessage = error.message }
    }

    /// Moves a graphic so it starts at `start`, keeping its length, inside the recording.
    func moveGraphic(_ id: UUID, to start: Double, live: Bool = false) {
        let duration = selectedItem?.editedDuration ?? 0
        mutateGraphic(id, gesture: live ? "graphic-move-\(id)" : nil, label: "Move Graphic") { graphic in
            let length = graphic.length
            graphic.start = max(0, min(start, duration - length))
            graphic.end = graphic.start + length
        }
    }

    /// Moves one edge; the other stays. A graphic stays at least half a second long.
    func setGraphicEdge(_ id: UUID, start: Double? = nil, end: Double? = nil, live: Bool = false) {
        let duration = selectedItem?.editedDuration ?? 0
        mutateGraphic(id, gesture: live ? "graphic-edge-\(id)" : nil, label: "Change Graphic Length") { graphic in
            if let start { graphic.start = max(0, min(start, graphic.end - GraphicsTrack.minimumLength)) }
            if let end { graphic.end = min(duration, max(end, graphic.start + GraphicsTrack.minimumLength)) }
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
