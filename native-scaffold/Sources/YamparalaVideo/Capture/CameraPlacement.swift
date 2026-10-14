import CoreGraphics
import Foundation

enum CameraFillMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case fill = "Fill"
    case fit  = "Fit"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .fill: return "Fills the area, cropping the edges of the frame."
        case .fit:  return "Shows the whole camera frame, letterboxed."
        }
    }
}

enum VerticalAlign: String, CaseIterable, Identifiable, Sendable, Codable {
    case top = "Top", middle = "Middle", bottom = "Bottom"
    var id: String { rawValue }
}

enum CameraCorner: String, CaseIterable, Identifiable, Sendable, Codable {
    case topLeft = "Top left", topRight = "Top right"
    case bottomLeft = "Bottom left", bottomRight = "Bottom right"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .topLeft:     return "arrow.up.left.square"
        case .topRight:    return "arrow.up.right.square"
        case .bottomLeft:  return "arrow.down.left.square"
        case .bottomRight: return "arrow.down.right.square"
        }
    }
}

enum CameraShape: String, CaseIterable, Identifiable, Sendable, Codable {
    case rectangle = "Rectangle"
    case rounded   = "Rounded"
    case circle    = "Circle"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .rounded:   return "rectangle.roundedtop"
        case .circle:    return "circle"
        }
    }

    /// A circle needs a square to sit in; the others keep the 16:9 frame shape.
    var isSquare: Bool { self == .circle }

    func cornerRadius(for box: CGRect) -> CGFloat {
        switch self {
        case .rectangle: return 0
        case .rounded:   return min(box.width, box.height) * 0.10
        case .circle:    return min(box.width, box.height) / 2
        }
    }
}

/// How the camera sits inside the recorded frame. Every field is adjustable
/// while a take is running.
struct CameraPlacement: Sendable, Equatable, Codable {
    var fillMode: CameraFillMode = .fill
    /// Where the camera sits in its column, side-by-side only.
    var verticalAlign: VerticalAlign = .middle
    /// Which corner the picture-in-picture hugs, overlay only.
    var corner: CameraCorner = .bottomRight
    /// Fraction of the output width the camera occupies.
    var sizeFraction: Double = 0.32
    /// Nudges the camera along its own axis, -1...1, for fine framing.
    var offset: Double = 0
    /// Outline of the picture-in-picture, overlay only.
    var shape: CameraShape = .rounded

    static let overlayMargin: CGFloat = 36

    /// The camera's box for the overlay layout, in output coordinates with y
    /// measured from the top. The compositor and the on-screen ghost both read
    /// this, so the guide cannot drift from what gets recorded.
    func overlayBoxTopDown(in output: CGSize) -> CGRect {
        let fraction = min(max(sizeFraction, 0.12), 0.55)
        let width = (output.width * fraction).rounded()
        let height = (shape.isSquare ? width : width * 9 / 16).rounded()
        let margin = Self.overlayMargin

        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: left ? margin : output.width - width - margin,
                      y: top ? margin : output.height - height - margin,
                      width: width, height: height)
    }
}
