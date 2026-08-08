import SwiftUI

// MARK: - Handles

enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Position within the crop rect, in unit coordinates.
    var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        }
    }

    var movesLeft: Bool { unit.x == 0 }
    var movesRight: Bool { unit.x == 1 }
    var movesTop: Bool { unit.y == 0 }
    var movesBottom: Bool { unit.y == 1 }
    var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }

    var cursor: NSCursor {
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default: return .crosshair
        }
    }
}

/// Resizes `start` by dragging `handle`, honouring an optional aspect ratio and the pixel bounds.
func resizedCrop(
    start: CGRect,
    handle: CropHandle,
    delta: CGSize,
    ratio: CGFloat?,
    bounds: CGRect,
    minSide: CGFloat = 16
) -> CGRect {
    var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY

    if handle.movesLeft { minX = min(start.maxX - minSide, max(bounds.minX, start.minX + delta.width)) }
    if handle.movesRight { maxX = max(start.minX + minSide, min(bounds.maxX, start.maxX + delta.width)) }
    if handle.movesTop { minY = min(start.maxY - minSide, max(bounds.minY, start.minY + delta.height)) }
    if handle.movesBottom { maxY = max(start.minY + minSide, min(bounds.maxY, start.maxY + delta.height)) }

    var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    guard let ratio, ratio > 0 else { return rect }

    // Which dimension the gesture drives, and how much room the fixed anchor leaves.
    let driveByWidth = handle.isCorner || handle.movesLeft || handle.movesRight
    var width = driveByWidth ? rect.width : rect.height * ratio
    // The floor has to account for the ratio, otherwise a fully collapsed drag
    // would clamp both sides to minSide and silently break the lock.
    let minWidth = max(minSide, minSide * ratio)

    let availableWidth: CGFloat = handle.movesLeft
        ? rect.maxX - bounds.minX
        : (handle.movesRight ? bounds.maxX - rect.minX
           : 2 * min(start.midX - bounds.minX, bounds.maxX - start.midX))
    let availableHeight: CGFloat = handle.movesTop
        ? rect.maxY - bounds.minY
        : (handle.movesBottom ? bounds.maxY - rect.minY
           : 2 * min(start.midY - bounds.minY, bounds.maxY - start.midY))

    width = min(width, min(availableWidth, availableHeight * ratio))
    width = max(width, minWidth)
    let height = width / ratio

    let x: CGFloat = handle.movesLeft ? rect.maxX - width
        : (handle.movesRight ? rect.minX : start.midX - width / 2)
    let y: CGFloat = handle.movesTop ? rect.maxY - height
        : (handle.movesBottom ? rect.minY : start.midY - height / 2)

    rect = CGRect(x: x, y: y, width: width, height: height)
    return rect.offsetBy(
        dx: max(0, bounds.minX - rect.minX) - max(0, rect.maxX - bounds.maxX),
        dy: max(0, bounds.minY - rect.minY) - max(0, rect.maxY - bounds.maxY)
    )
}

// MARK: - Draggable rectangle

/// A movable, resizable rectangle drawn over the frame. Shared by the crop rectangle and
/// each blur region so they behave identically.
struct RectManipulator: View {
    let rect: CGRect            // source pixels
    let bounds: CGRect          // source pixels
    let ratio: CGFloat?
    let scale: CGFloat          // points per source pixel
    let tint: Color
    var showsHandles: Bool = true
    var showsGrid: Bool = false
    var fill: Color = .clear
    let onChange: (CGRect, Bool) -> Void   // rect, stillDragging
    var onSelect: () -> Void = {}

    @State private var dragStart: CGRect?

    private var display: CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(fill)
                .overlay(Rectangle().strokeBorder(tint.opacity(0.95), lineWidth: 1.5))
                .background(Color.white.opacity(0.001)) // keeps the interior draggable
                .overlay { if showsGrid { thirdsGrid } }
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }

            if showsHandles {
                ForEach(Array(CropHandle.allCases.enumerated()), id: \.offset) { _, handle in
                    handleView(handle)
                }
            }
        }
        .frame(width: display.width, height: display.height)
        .offset(x: display.minX, y: display.minY)
    }

    private var thirdsGrid: some View {
        GeometryReader { geo in
            Path { path in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(tint.opacity(0.25), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func handleView(_ handle: CropHandle) -> some View {
        let size: CGFloat = handle.isCorner ? 12 : 10
        return RoundedRectangle(cornerRadius: 2)
            .fill(tint)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
            .frame(width: size, height: size)
            .position(x: display.width * handle.unit.x, y: display.height * handle.unit.y)
            .contentShape(Rectangle().size(width: 26, height: 26)
                .offset(x: display.width * handle.unit.x - 13,
                        y: display.height * handle.unit.y - 13))
            .gesture(resizeGesture(handle))
            .onHover { inside in
                if inside { handle.cursor.push() } else { NSCursor.pop() }
            }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? rect
                if dragStart == nil {
                    dragStart = rect
                    onSelect()
                }
                var moved = start.offsetBy(
                    dx: value.translation.width / scale,
                    dy: value.translation.height / scale
                )
                moved.origin.x = min(max(bounds.minX, moved.minX), bounds.maxX - moved.width)
                moved.origin.y = min(max(bounds.minY, moved.minY), bounds.maxY - moved.height)
                onChange(moved, true)
            }
            .onEnded { _ in
                dragStart = nil
                onChange(rect, false)
            }
    }

    private func resizeGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? rect
                if dragStart == nil {
                    dragStart = rect
                    onSelect()
                }
                onChange(resizedCrop(
                    start: start,
                    handle: handle,
                    delta: CGSize(width: value.translation.width / scale,
                                  height: value.translation.height / scale),
                    ratio: ratio,
                    bounds: bounds
                ), true)
            }
            .onEnded { _ in
                dragStart = nil
                onChange(rect, false)
            }
    }
}

/// Drag-to-draw on empty canvas, shared by "draw a new crop" and "add a blur area".
struct DrawRectGesture: ViewModifier {
    let bounds: CGRect
    let scale: CGFloat
    let ratio: CGFloat?
    let onDraw: (CGRect, Bool) -> Void

    @State private var origin: CGPoint?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let start = origin ?? CGPoint(x: value.startLocation.x / scale,
                                                  y: value.startLocation.y / scale)
                    if origin == nil { origin = start }
                    let anchor = CGRect(origin: start, size: CGSize(width: 16, height: 16))
                    let dx = value.translation.width, dy = value.translation.height
                    let handle: CropHandle = dx >= 0
                        ? (dy >= 0 ? .bottomRight : .topRight)
                        : (dy >= 0 ? .bottomLeft : .topLeft)
                    onDraw(resizedCrop(
                        start: anchor,
                        handle: handle,
                        delta: CGSize(width: dx / scale, height: dy / scale),
                        ratio: ratio,
                        bounds: bounds
                    ), true)
                }
                .onEnded { _ in
                    origin = nil
                    onDraw(.null, false)
                }
        )
    }
}

// MARK: - Crop overlay

struct CropOverlay: View {
    let crop: CGRect
    let bounds: CGRect
    let ratio: CGFloat?
    let displaySize: CGSize
    let onChange: (CGRect) -> Void

    private var scale: CGFloat { displaySize.width / max(bounds.width, 1) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DimMask(hole: crop, bounds: bounds, scale: scale)

            // Drag on the dimmed area to draw a fresh rectangle.
            Color.clear
                .contentShape(Rectangle())
                .modifier(DrawRectGesture(bounds: bounds, scale: scale, ratio: ratio) { rect, dragging in
                    if dragging { onChange(rect) }
                })

            RectManipulator(
                rect: crop, bounds: bounds, ratio: ratio, scale: scale,
                tint: .white, showsGrid: true
            ) { rect, dragging in
                if dragging { onChange(rect) }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped()
    }
}

/// Dims everything outside `hole`.
struct DimMask: View {
    let hole: CGRect
    let bounds: CGRect
    let scale: CGFloat
    var opacity: Double = 0.55

    var body: some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(CGRect(x: hole.minX * scale, y: hole.minY * scale,
                                width: hole.width * scale, height: hole.height * scale))
            context.fill(path, with: .color(.black.opacity(opacity)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Blur overlay

struct BlurOverlay: View {
    let regions: [BlurRegion]
    let selectedID: BlurRegion.ID?
    let crop: CGRect
    let bounds: CGRect
    let displaySize: CGSize
    let onSelect: (BlurRegion.ID) -> Void
    let onChange: (BlurRegion.ID, CGRect, Bool) -> Void
    let onAdd: (CGRect) -> Void

    @State private var pending: CGRect?

    private var scale: CGFloat { displaySize.width / max(bounds.width, 1) }
    private let tint = Color.orange

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Still show the framing, but the crop is not editable in this mode.
            DimMask(hole: crop, bounds: bounds, scale: scale, opacity: 0.4)
            Rectangle()
                .strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: crop.width * scale, height: crop.height * scale)
                .offset(x: crop.minX * scale, y: crop.minY * scale)
                .allowsHitTesting(false)

            // Drag anywhere empty to add another area.
            Color.clear
                .contentShape(Rectangle())
                .modifier(DrawRectGesture(bounds: bounds, scale: scale, ratio: nil) { rect, dragging in
                    if dragging {
                        pending = rect
                    } else if let drawn = pending {
                        pending = nil
                        if drawn.width >= 16, drawn.height >= 16 { onAdd(drawn) }
                    }
                })

            ForEach(regions) { region in
                RectManipulator(
                    rect: region.rect, bounds: bounds, ratio: nil, scale: scale,
                    tint: tint,
                    showsHandles: region.id == selectedID,
                    fill: tint.opacity(region.id == selectedID ? 0.16 : 0.10),
                    onChange: { rect, dragging in onChange(region.id, rect, dragging) },
                    onSelect: { onSelect(region.id) }
                )
                .onTapGesture { onSelect(region.id) }
            }

            if let pending {
                Rectangle()
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: pending.width * scale, height: pending.height * scale)
                    .offset(x: pending.minX * scale, y: pending.minY * scale)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped()
    }
}

// MARK: - Zoom overlay

struct ZoomOverlay: View {
    let shots: [ZoomShot]
    let selectedID: ZoomShot.ID?
    let crop: CGRect
    let bounds: CGRect
    let displaySize: CGSize
    let onSelect: (ZoomShot.ID) -> Void
    let onMove: (ZoomShot.ID, CGPoint) -> Void
    let onAdd: (CGPoint) -> Void

    private var scale: CGFloat { displaySize.width / max(bounds.width, 1) }
    private let tint = Color.cyan

    /// What stays visible at the peak of a shot: the crop shrunk by the zoom level,
    /// centred on the target and kept inside the frame.
    private func viewport(_ shot: ZoomShot) -> CGRect {
        let w = crop.width / shot.level
        let h = crop.height / shot.level
        let x = min(max(crop.minX, shot.target.x - w / 2), crop.maxX - w)
        let y = min(max(crop.minY, shot.target.y - h / 2), crop.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DimMask(hole: crop, bounds: bounds, scale: scale, opacity: 0.4)

            // Click anywhere to drop a zoom at the playhead.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    onAdd(CGPoint(x: location.x / scale, y: location.y / scale))
                }

            ForEach(shots) { shot in
                let selected = shot.id == selectedID
                let box = viewport(shot)

                Rectangle()
                    .strokeBorder(tint.opacity(selected ? 0.95 : 0.4),
                                  style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: [6, 3]))
                    .frame(width: box.width * scale, height: box.height * scale)
                    .offset(x: box.minX * scale, y: box.minY * scale)
                    .allowsHitTesting(false)

                ZoomTarget(shot: shot, selected: selected, scale: scale, tint: tint)
                    .position(x: shot.target.x * scale, y: shot.target.y * scale)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                onSelect(shot.id)
                                onMove(shot.id, CGPoint(x: value.location.x / scale,
                                                        y: value.location.y / scale))
                            }
                    )
                    .onTapGesture { onSelect(shot.id) }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped()
    }
}

private struct ZoomTarget: View {
    let shot: ZoomShot
    let selected: Bool
    let scale: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(selected ? 1 : 0.55), lineWidth: selected ? 2 : 1.5)
                .background(Circle().fill(tint.opacity(selected ? 0.22 : 0.10)))
                .frame(width: 30, height: 30)
            Circle()
                .fill(tint.opacity(selected ? 1 : 0.6))
                .frame(width: 5, height: 5)
            Text(shot.levelLabel)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(selected ? 0.95 : 0.6)))
                .offset(y: 24)
                .fixedSize()
        }
        .contentShape(Circle().size(width: 34, height: 34).offset(x: -17, y: -17))
    }
}

// MARK: - Canvas (frame + overlay)

struct CropCanvas: View {
    let image: NSImage?
    let info: MediaInfo
    let crop: CGRect
    let ratio: CGFloat?
    let isLoading: Bool
    let mode: EditorMode
    let regions: [BlurRegion]
    let selectedRegionID: BlurRegion.ID?
    let shots: [ZoomShot]
    let selectedShotID: ZoomShot.ID?
    let onChange: (CGRect) -> Void
    let onSelectRegion: (BlurRegion.ID) -> Void
    let onChangeRegion: (BlurRegion.ID, CGRect, Bool) -> Void
    let onAddRegion: (CGRect) -> Void
    let onSelectShot: (ZoomShot.ID) -> Void
    let onMoveShot: (ZoomShot.ID, CGPoint) -> Void
    let onAddShot: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 16
            let available = CGSize(width: max(1, geo.size.width - inset * 2),
                                   height: max(1, geo.size.height - inset * 2))
            let fitted = fittedSize(aspect: info.aspect, in: available)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.35))

                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: fitted.width, height: fitted.height)
                    } else {
                        Rectangle()
                            .fill(Color(nsColor: .darkGray).opacity(0.4))
                            .frame(width: fitted.width, height: fitted.height)
                            .overlay {
                                if isLoading { ProgressView().controlSize(.small) }
                            }
                    }

                    switch mode {
                    case .crop:
                        CropOverlay(
                            crop: crop,
                            bounds: info.fullFrame,
                            ratio: ratio,
                            displaySize: fitted,
                            onChange: onChange
                        )
                    case .blur:
                        BlurOverlay(
                            regions: regions,
                            selectedID: selectedRegionID,
                            crop: crop,
                            bounds: info.fullFrame,
                            displaySize: fitted,
                            onSelect: onSelectRegion,
                            onChange: onChangeRegion,
                            onAdd: onAddRegion
                        )
                    case .zoom:
                        ZoomOverlay(
                            shots: shots,
                            selectedID: selectedShotID,
                            crop: crop,
                            bounds: info.fullFrame,
                            displaySize: fitted,
                            onSelect: onSelectShot,
                            onMove: onMoveShot,
                            onAdd: onAddShot
                        )
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fittedSize(aspect: CGFloat, in container: CGSize) -> CGSize {
        guard aspect > 0 else { return container }
        var width = container.width
        var height = width / aspect
        if height > container.height {
            height = container.height
            width = height * aspect
        }
        return CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
    }
}

// MARK: - Numeric field

struct PixelField: View {
    let label: String
    let accessibleName: String
    let value: CGFloat
    let range: ClosedRange<CGFloat>
    let onCommit: (CGFloat) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 58)
                .accessibilityLabel(accessibleName)
                .help("\(accessibleName) in pixels")
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
        }
        .onAppear { text = String(Int(value)) }
        .onChange(of: value) { _, newValue in
            if !focused { text = String(Int(newValue)) }
        }
    }

    private func commit() {
        guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else {
            text = String(Int(value))
            return
        }
        let clamped = min(max(CGFloat(parsed), range.lowerBound), range.upperBound)
        onCommit((clamped / 2).rounded() * 2)
        text = String(Int((clamped / 2).rounded() * 2))
    }
}
