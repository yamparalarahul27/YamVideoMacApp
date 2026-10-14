import SwiftUI

/// Works out what the recording will actually contain, expressed in the
/// on-screen game pane's coordinates (top-left origin) so it can be drawn
/// straight over the web view.
///
/// This matters because the pane is not 16:9. Filling a 1920x1080 frame with it
/// always crops something, and without a guide there is no way to know what.
struct RecordingGuide {
    /// The part of the game pane that survives into the recording.
    let safeRect: CGRect
    /// Where the camera lands, for the overlay layout.
    let cameraRect: CGRect?

    static let outputSize = CGSize(width: 1920, height: 1080)

    init(paneSize: CGSize, layout: RecordingLayout, placement: CameraPlacement) {
        let output = Self.outputSize
        let fraction = min(max(placement.sizeFraction, 0.12), 0.55)
        let camWidth = (output.width * fraction).rounded()

        let target: CGSize = layout == .sideBySide
            ? CGSize(width: output.width - camWidth, height: output.height)
            : output

        guard paneSize.width > 1, paneSize.height > 1 else {
            safeRect = .zero
            cameraRect = nil
            return
        }

        // Mirrors the compositor's aspect-fill: scale to cover, then centre-crop.
        let scale = max(target.width / paneSize.width, target.height / paneSize.height)
        let visible = CGSize(width: min(target.width / scale, paneSize.width),
                             height: min(target.height / scale, paneSize.height))
        let safe = CGRect(x: ((paneSize.width - visible.width) / 2).rounded(),
                          y: ((paneSize.height - visible.height) / 2).rounded(),
                          width: visible.width.rounded(),
                          height: visible.height.rounded())
        safeRect = safe

        guard layout == .cameraOverlay else {
            cameraRect = nil
            return
        }

        let box = placement.overlayBoxTopDown(in: output)
        cameraRect = CGRect(
            x: safe.minX + (box.minX / target.width) * safe.width,
            y: safe.minY + (box.minY / target.height) * safe.height,
            width: (box.width / target.width) * safe.width,
            height: (box.height / target.height) * safe.height)
    }
}

/// Ghost overlay: dims what gets cropped away and outlines where the camera
/// will sit. Purely informational — it never intercepts clicks.
struct FramingGuideView: View {
    let layout: RecordingLayout
    let placement: CameraPlacement
    let cameraHidden: Bool

    var body: some View {
        GeometryReader { geo in
            let guide = RecordingGuide(paneSize: geo.size, layout: layout, placement: placement)
            let safe = guide.safeRect

            ZStack(alignment: .topLeading) {
                if safe.width > 0 {
                    // Everything outside the recorded frame, dimmed.
                    Rectangle()
                        .fill(.black.opacity(0.45))
                        .mask {
                            Rectangle()
                                .overlay(alignment: .topLeading) {
                                    Rectangle()
                                        .frame(width: safe.width, height: safe.height)
                                        .offset(x: safe.minX, y: safe.minY)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                        }

                    Rectangle()
                        .strokeBorder(.white.opacity(0.55), style: .init(lineWidth: 1, dash: [5, 4]))
                        .frame(width: safe.width, height: safe.height)
                        .offset(x: safe.minX, y: safe.minY)

                    label("recorded frame", color: .white.opacity(0.75))
                        .offset(x: safe.minX + 6, y: safe.minY + 5)

                    if let camera = guide.cameraRect {
                        ghostShape(for: camera)
                            .fill(Color.accentColor.opacity(0.16))
                            .overlay {
                                ghostShape(for: camera)
                                    .strokeBorder(Color.accentColor.opacity(0.85),
                                                  style: .init(lineWidth: 1.5, dash: [6, 3]))
                            }
                            .overlay {
                                label(cameraHidden ? "camera hidden" : "camera",
                                      color: .white.opacity(0.9))
                            }
                            .frame(width: camera.width, height: camera.height)
                            .offset(x: camera.minX, y: camera.minY)
                    } else {
                        // Side by side: the camera column lives outside the pane.
                        label("camera →", color: .white.opacity(0.7))
                            .offset(x: safe.maxX - 62, y: safe.midY - 8)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Matches the mask the compositor will apply, so the ghost is honest.
    private func ghostShape(for rect: CGRect) -> AnyInsettableShape {
        let radius = placement.shape.cornerRadius(for: rect)
        if placement.shape == .circle {
            return AnyInsettableShape(Circle())
        }
        return AnyInsettableShape(RoundedRectangle(cornerRadius: radius))
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Lets the guide hand back either a circle or a rounded rectangle and still
/// use `strokeBorder`.
struct AnyInsettableShape: InsettableShape {
    private let makePath: @Sendable (CGRect) -> Path
    private let makeInset: @Sendable (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        makePath = { shape.path(in: $0) }
        makeInset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { makePath(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { makeInset(amount) }
}
