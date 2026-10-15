import AppKit
import SwiftUI

// Move and resize graphics on the picture (graphics track G2b, docs/plans/graphics-track.md).
// A graphic's `transform` moves and scales it in design pixels; the engine applies it, so
// the preview and the export agree. Here: the boxes the engine measures, the snapping
// rules, the Preview layer that drags them, and the edits it makes.

// MARK: - Boxes on the picture

/// A graphic's box on the 1920×1080 design picture as the template draws it, and the point
/// its scale works from (the top-left corner of its zone). The engine measures both.
struct GraphicBounds: Equatable {
    var content: CGRect
    var origin: CGPoint

    /// Where the box sits once `transform` has moved and scaled it.
    func placed(_ transform: GraphicTransform?) -> CGRect {
        (transform ?? GraphicTransform()).apply(content, origin: origin)
    }

    /// Reads `YamGraphics.bounds()`: {id: {x, y, w, h, ox, oy}}.
    static func parse(_ json: String) -> [UUID: GraphicBounds] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else { return [:] }
        var result: [UUID: GraphicBounds] = [:]
        for (key, box) in root {
            guard let id = UUID(uuidString: key), let x = box["x"], let y = box["y"], let w = box["w"], let h = box["h"] else { continue }
            result[id] = GraphicBounds(content: CGRect(x: x, y: y, width: w, height: h),
                                       origin: CGPoint(x: box["ox"] ?? 0, y: box["oy"] ?? 0))
        }
        return result
    }
}

// MARK: - Moving and resizing, with snapping

enum GraphicPlacement {
    /// The title-safe area: 5 % in from each edge.
    static let safeArea = CGRect(x: 96, y: 54, width: 1728, height: 972)

    struct Guides: Equatable {
        var vertical: [Double]
        var horizontal: [Double]
    }

    /// The lines a graphic snaps to: the safe area, the centre lines, its own place in the
    /// template, and the column or the panel it belongs to.
    static func guides(for graphic: Graphic, bounds: GraphicBounds, style: GraphicsStyle) -> Guides {
        var vertical: [Double] = [safeArea.minX, 960, safeArea.maxX, bounds.content.minX, bounds.content.maxX]
        var horizontal: [Double] = [safeArea.minY, 540, safeArea.maxY, bounds.content.minY, bounds.content.maxY]
        if graphic.kind.zone == .column {
            vertical += [1240, 1880]
            horizontal.append(72)
        } else {
            vertical.append(style.moveVideo ? 960 : 1110)
        }
        return Guides(vertical: Array(Set(vertical)).sorted(), horizontal: Array(Set(horizontal)).sorted())
    }

    /// The lines a graphic snaps to on a Short's canvas: YouTube's clear area, the centre
    /// line, its own place, and the card or panel zone it belongs to.
    static func shortGuides(for graphic: Graphic, bounds: GraphicBounds, panels: ShortPanels) -> Guides {
        let clear = ShortFormat.clearArea
        let zone = ShortLayout(panels: panels).zone(of: graphic.kind)
        let vertical: [Double] = [clear.minX, ShortFormat.size.width / 2, clear.maxX, bounds.content.minX, bounds.content.maxX, zone.origin.x]
        let horizontal: [Double] = [clear.minY, clear.maxY, bounds.content.minY, bounds.content.maxY, zone.origin.y, ShortLayout.captionBottom]
        return Guides(vertical: Array(Set(vertical)).sorted(), horizontal: Array(Set(horizontal)).sorted())
    }

    /// A placement, and the guide lines it snapped to, in design pixels.
    struct Result: Equatable {
        var transform: GraphicTransform
        var vertical: Double?
        var horizontal: Double?
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
        func point(of rect: CGRect) -> CGPoint {
            CGPoint(x: isLeft ? rect.minX : rect.maxX, y: isTop ? rect.minY : rect.maxY)
        }
    }

    /// The closest of `edges` to any of `lines`, within `tolerance`: the shift that puts it
    /// on the line, and the line.
    private static func nearest(_ edges: [Double], _ lines: [Double], _ tolerance: Double) -> (shift: Double, line: Double)? {
        var best: (shift: Double, line: Double)?
        for edge in edges {
            for line in lines where abs(line - edge) <= tolerance && abs(line - edge) < abs(best?.shift ?? .infinity) {
                best = (line - edge, line)
            }
        }
        return best
    }

    private static func clamped(_ transform: GraphicTransform) -> GraphicTransform {
        let reach = GraphicTransform.reach
        return GraphicTransform(x: min(max(transform.x, -reach.width), reach.width).rounded(),
                                y: min(max(transform.y, -reach.height), reach.height).rounded(),
                                scale: (min(max(transform.scale, GraphicTransform.scales.lowerBound),
                                            GraphicTransform.scales.upperBound) * 1000).rounded() / 1000)
    }

    /// Moved by `delta` from `start`. Its left, centre or right (and top, centre or
    /// bottom) snaps to the nearest guide within `tolerance`; nil guides do not snap.
    static func moved(_ start: GraphicTransform, by delta: CGSize, bounds: GraphicBounds,
                      guides: Guides?, tolerance: Double) -> Result {
        let box = bounds.placed(start).offsetBy(dx: delta.width, dy: delta.height)
        var dx = delta.width, dy = delta.height
        var vertical: Double?, horizontal: Double?
        if let guides {
            if let snap = nearest([box.minX, box.midX, box.maxX], guides.vertical, tolerance) { dx += snap.shift; vertical = snap.line }
            if let snap = nearest([box.minY, box.midY, box.maxY], guides.horizontal, tolerance) { dy += snap.shift; horizontal = snap.line }
        }
        return Result(transform: clamped(GraphicTransform(x: start.x + dx, y: start.y + dy, scale: start.scale)),
                      vertical: vertical, horizontal: horizontal)
    }

    /// Resized from `corner`, which follows `point`: the opposite corner stays put and the
    /// graphic keeps its shape. The size snaps to the template's own (100 %), or the
    /// moving corner to a guide, within `tolerance`.
    static func resized(_ start: GraphicTransform, corner: Corner, to point: CGPoint, bounds: GraphicBounds,
                        guides: Guides?, tolerance: Double) -> Result {
        let box = bounds.placed(start)
        let width = bounds.content.width, height = bounds.content.height
        guard width > 0, height > 0 else { return Result(transform: start) }
        let fixed = Corner.allCases.first { $0.isLeft != corner.isLeft && $0.isTop != corner.isTop }!.point(of: box)
        let across: Double = corner.isLeft ? -1 : 1, down: Double = corner.isTop ? -1 : 1
        var scale = max(abs(point.x - fixed.x) / width, abs(point.y - fixed.y) / height)
        var vertical: Double?, horizontal: Double?
        if let guides {
            if abs(scale - 1) * max(width, height) <= tolerance {
                scale = 1
            } else {
                let x = fixed.x + across * width * scale, y = fixed.y + down * height * scale
                let byX = nearest([x], guides.vertical, tolerance), byY = nearest([y], guides.horizontal, tolerance)
                if let snap = byX, abs(snap.shift) <= abs(byY?.shift ?? .infinity) {
                    scale = abs(snap.line - fixed.x) / width; vertical = snap.line
                } else if let snap = byY {
                    scale = abs(snap.line - fixed.y) / height; horizontal = snap.line
                }
            }
        }
        scale = min(max(scale, GraphicTransform.scales.lowerBound), GraphicTransform.scales.upperBound)
        let minX = corner.isLeft ? fixed.x - width * scale : fixed.x
        let minY = corner.isTop ? fixed.y - height * scale : fixed.y
        // The move that puts the scaled box's top-left there.
        let x = minX - bounds.origin.x - scale * (bounds.content.minX - bounds.origin.x)
        let y = minY - bounds.origin.y - scale * (bounds.content.minY - bounds.origin.y)
        return Result(transform: clamped(GraphicTransform(x: x, y: y, scale: scale)), vertical: vertical, horizontal: horizontal)
    }
}

// MARK: - Edits

extension AppModel {
    /// Moves or resizes a graphic on the picture. A drag is one gesture and one undo step;
    /// the template's own place and size are stored as no transform at all.
    func placeGraphic(_ id: UUID, _ transform: GraphicTransform?, live: Bool = false, label: String = "Move Graphic on Picture") {
        let value = transform.flatMap { $0.isIdentity ? nil : $0 }
        mutateGraphic(id, gesture: live ? "graphic-place-\(id)" : nil, label: label, keepPreview: true) { $0.transform = value }
    }

    /// ⌥ arrow keys: one design pixel, ten with ⇧.
    func nudgeSelectedGraphic(dx: Double, dy: Double) {
        guard let graphic = selectedGraphic else { return }
        var transform = graphic.transform ?? GraphicTransform()
        transform.x += dx; transform.y += dy
        guard transform.problem == nil else { statusMessage = transform.problem; return }
        placeGraphic(graphic.id, transform, label: "Nudge Graphic")
    }

    func resetGraphicPlace(_ id: UUID) {
        placeGraphic(id, nil, label: "Reset Graphic Position")
    }

    /// Whether a drag on the picture snaps: ⌥ turns it off, as on the timeline.
    func pictureSnaps(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        !modifiers.contains(.option)
    }
}

// MARK: - The Preview layer

/// Over the Preview picture: click a graphic to select it, drag it to move it, drag a
/// corner to resize it. Guides show while it snaps; ⌥ turns snapping off.
struct GraphicsPlacementLayer: View {
    @EnvironmentObject var model: AppModel
    let input: GraphicsOverlayInput
    /// A Short whose own placements the drags change, on its 1080×1920 canvas; nil moves
    /// graphics on the 16:9 video.
    var short: UUID? = nil

    private var bounds: [UUID: GraphicBounds] { short == nil ? model.graphicBounds : model.shortGraphicBounds }
    private var stageWidth: CGFloat { input.track.canvas.size.width }

    private func place(_ id: UUID, _ transform: GraphicTransform, label: String) {
        if let short { model.placeGraphicInShort(short, graphic: id, transform, live: true, label: label == "Move Graphic on Picture" ? "Move Graphic in Short" : "Resize Graphic in Short") }
        else { model.placeGraphic(id, transform, live: true, label: label) }
    }

    private func guides(for graphic: Graphic, bounds: GraphicBounds) -> GraphicPlacement.Guides {
        if case .short(let panels) = input.track.canvas { return GraphicPlacement.shortGuides(for: graphic, bounds: bounds, panels: panels) }
        return GraphicPlacement.guides(for: graphic, bounds: bounds, style: input.track.style)
    }

    private enum Action { case move, resize(GraphicPlacement.Corner), deselect }
    private struct Drag {
        var action: Action
        var id: UUID?
        var start = GraphicTransform()
        var bounds: GraphicBounds?
        var changed = false
    }
    @State private var drag: Drag?
    @State private var snapped = GraphicPlacement.Result(transform: GraphicTransform())

    /// Screen points of slack around a handle or an edge, and of snapping.
    private static let handleReach: CGFloat = 9
    private static let snapReach: CGFloat = 6

    private var selected: (graphic: Graphic, bounds: GraphicBounds)? {
        guard let id = model.selectedGraphicID, let graphic = input.track.items.first(where: { $0.id == id && $0.kind.isPlaceable }),
              let bounds = bounds[id] else { return nil }
        return (graphic, bounds)
    }

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / stageWidth
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if let selected {
                    selectionBox(selected.graphic, rect: scaled(selected.bounds.placed(selected.graphic.transform), k))
                }
                if drag != nil { guideLines(k, size: geo.size) }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { changed($0, k) }
                .onEnded { _ in ended() })
        }
    }

    private func scaled(_ rect: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
    }

    private func selectionBox(_ graphic: Graphic, rect: CGRect) -> some View {
        let showing = input.time >= graphic.start && input.time < graphic.end
        let accent = Color(nsColor: .controlAccentColor)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(accent, style: StrokeStyle(lineWidth: 1.5, dash: showing ? [] : [5, 4]))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            ForEach(GraphicPlacement.Corner.allCases, id: \.self) { corner in
                let point = corner.point(of: rect)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .offset(x: point.x - 4.5, y: point.y - 4.5)
            }
            if case .resize? = drag?.action {
                Text("\(Int(((graphic.transform?.scale ?? 1) * 100).rounded())) %")
                    .font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: rect.minX, y: max(0, rect.minY - 20))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Selected \(graphic.kind.label.lowercased()) on the picture")
        .accessibilityHint("Drag to move it or drag a corner to resize it. The inspector has its position and size.")
    }

    private func guideLines(_ k: CGFloat, size: CGSize) -> some View {
        let color = Color(nsColor: .systemOrange)
        return ZStack(alignment: .topLeading) {
            if let x = snapped.vertical {
                Rectangle().fill(color).frame(width: 1, height: size.height).offset(x: x * k)
            }
            if let y = snapped.horizontal {
                Rectangle().fill(color).frame(width: size.width, height: 1).offset(y: y * k)
            }
        }
        .allowsHitTesting(false)
    }

    private func begin(at location: CGPoint, _ k: CGFloat) -> Drag {
        let point = CGPoint(x: location.x / k, y: location.y / k)
        let reach = Self.handleReach / k
        if let selected {
            let box = selected.bounds.placed(selected.graphic.transform)
            for corner in GraphicPlacement.Corner.allCases {
                let handle = corner.point(of: box)
                if abs(handle.x - point.x) <= reach, abs(handle.y - point.y) <= reach {
                    return Drag(action: .resize(corner), id: selected.graphic.id,
                                start: selected.graphic.transform ?? GraphicTransform(), bounds: selected.bounds)
                }
            }
            if box.insetBy(dx: -reach / 2, dy: -reach / 2).contains(point) {
                return Drag(action: .move, id: selected.graphic.id,
                            start: selected.graphic.transform ?? GraphicTransform(), bounds: selected.bounds)
            }
        }
        // The topmost graphic showing now under the pointer; later ones draw on top.
        // The end screen stays put, so clicks reach what sits under its boxes.
        let showing = input.track.items.filter { $0.kind.isPlaceable && input.time >= $0.start && input.time < $0.end }
        if let hit = showing.reversed().first(where: { bounds[$0.id]?.placed($0.transform).contains(point) == true }) {
            model.selectedGraphicID = hit.id
            return Drag(action: .move, id: hit.id, start: hit.transform ?? GraphicTransform(), bounds: bounds[hit.id])
        }
        return Drag(action: .deselect)
    }

    private func changed(_ value: DragGesture.Value, _ k: CGFloat) {
        if drag == nil { drag = begin(at: value.startLocation, k) }
        guard var current = drag, let id = current.id, let bounds = current.bounds,
              let graphic = input.track.items.first(where: { $0.id == id }) else { return }
        let moved = abs(value.translation.width) + abs(value.translation.height) >= 1
        guard current.changed || moved else { return }
        current.changed = true
        drag = current
        let guides = model.pictureSnaps() ? self.guides(for: graphic, bounds: bounds) : nil
        let tolerance = Double(Self.snapReach / k)
        switch current.action {
        case .move:
            snapped = GraphicPlacement.moved(current.start, by: CGSize(width: value.translation.width / k, height: value.translation.height / k),
                                             bounds: bounds, guides: guides, tolerance: tolerance)
            place(id, snapped.transform, label: "Move Graphic on Picture")
        case .resize(let corner):
            snapped = GraphicPlacement.resized(current.start, corner: corner, to: CGPoint(x: value.location.x / k, y: value.location.y / k),
                                               bounds: bounds, guides: guides, tolerance: tolerance)
            place(id, snapped.transform, label: "Resize Graphic")
        case .deselect:
            break
        }
    }

    private func ended() {
        if let finished = drag {
            switch finished.action {
            case .deselect where !finished.changed: model.selectedGraphicID = nil
            case .move, .resize: if finished.changed { model.endGesture() }
            default: break
            }
        }
        drag = nil
        snapped = GraphicPlacement.Result(transform: GraphicTransform())
    }
}
