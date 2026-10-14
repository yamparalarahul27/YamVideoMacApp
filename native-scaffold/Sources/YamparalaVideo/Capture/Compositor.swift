import AVFoundation
import CoreImage
import CoreVideo
import Metal

enum RecordingLayout: String, CaseIterable, Identifiable {
    case sideBySide    = "Side by side"
    case cameraOverlay = "Camera overlay"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .sideBySide:
            return "Game left, webcam right — matches the app layout."
        case .cameraOverlay:
            return "Game full frame, webcam in the corner."
        }
    }
}

/// Builds each output frame: the cropped game region plus the camera, drawn
/// into a clean 1920x1080 canvas with none of the app's own chrome.
final class FrameCompositor {
    let outputSize = CGSize(width: 1920, height: 1080)

    private let ciContext: CIContext
    private var pool: CVPixelBufferPool?
    private var maskCache: [String: CIImage] = [:]

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// - Parameters:
    ///   - gameCrop: region of the window buffer holding the web view, in
    ///     Core Image coordinates (origin bottom-left), already in pixels.
    func composite(
        window: CVPixelBuffer,
        gameCrop: CGRect,
        camera: CVPixelBuffer?,
        cameraMirrored: Bool,
        cameraHidden: Bool,
        layout: RecordingLayout,
        placement: CameraPlacement
    ) -> CVPixelBuffer? {
        let canvas = CGRect(origin: .zero, size: outputSize)

        var image = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.06)).cropped(to: canvas)

        // --- game ---
        let windowImage = CIImage(cvPixelBuffer: window)
        let crop = gameCrop.intersection(windowImage.extent)
        let game = crop.isNull || crop.isEmpty
            ? windowImage
            : windowImage.cropped(to: crop).transformed(
                by: .init(translationX: -crop.origin.x, y: -crop.origin.y))

        var cameraImage: CIImage?
        if let camera, !cameraHidden {
            var ci = CIImage(cvPixelBuffer: camera)
            if cameraMirrored {
                ci = ci
                    .transformed(by: .init(scaleX: -1, y: 1))
                    .transformed(by: .init(translationX: ci.extent.width, y: 0))
            }
            cameraImage = ci
        }

        let fraction = min(max(placement.sizeFraction, 0.12), 0.55)

        switch layout {
        case .sideBySide:
            let camWidth = (outputSize.width * fraction).rounded()
            let gameRect = CGRect(x: 0, y: 0,
                                  width: outputSize.width - camWidth, height: outputSize.height)
            let column = CGRect(x: gameRect.width, y: 0,
                                width: camWidth, height: outputSize.height)

            image = aspectFill(game, into: gameRect).composited(over: image)
            if let cameraImage {
                image = fitCamera(cameraImage, into: column, placement: placement,
                                  cornerRadius: 0).composited(over: image)
            }

        case .cameraOverlay:
            image = aspectFill(game, into: canvas).composited(over: image)
            if let cameraImage {
                // Shared with the on-screen ghost, then flipped: Core Image
                // measures y upward, the box is expressed from the top.
                let topDown = placement.overlayBoxTopDown(in: outputSize)
                let box = CGRect(x: topDown.minX,
                                 y: outputSize.height - topDown.maxY,
                                 width: topDown.width, height: topDown.height)
                image = fitCamera(cameraImage, into: box, placement: placement,
                                  cornerRadius: placement.shape.cornerRadius(for: box))
                    .composited(over: image)
            }
        }

        guard let buffer = makeBuffer() else { return nil }
        ciContext.render(image, to: buffer, bounds: canvas,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    /// Places the camera inside `area`.
    ///
    /// Fill covers the area and crops the overflow; Fit shows the whole frame
    /// and letterboxes. Alignment and nudge work in both: with Fill they choose
    /// which slice of the frame survives the crop, with Fit they choose where
    /// the frame sits in the empty space.
    private func fitCamera(_ image: CIImage, into area: CGRect,
                           placement: CameraPlacement, cornerRadius: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scale = placement.fillMode == .fill
            ? max(area.width / extent.width, area.height / extent.height)
            : min(area.width / extent.width, area.height / extent.height)

        let scaled = CGSize(width: extent.width * scale, height: extent.height * scale)

        let x = area.midX - scaled.width / 2
        var y: CGFloat
        switch placement.verticalAlign {
        case .top:    y = area.maxY - scaled.height
        case .middle: y = area.midY - scaled.height / 2
        case .bottom: y = area.minY
        }

        // Positive for Fit (empty space to move within), negative for Fill
        // (overflow to pan across) — the magnitude is what matters either way.
        let range = abs(area.height - scaled.height) / 2
        y += CGFloat(placement.offset) * range

        var placed = image
            .transformed(by: .init(scaleX: scale, y: scale))
        placed = placed.transformed(by: .init(
            translationX: x - placed.extent.origin.x,
            y: y - placed.extent.origin.y))
        placed = placed.cropped(to: area)

        if cornerRadius > 0 {
            // With Fit the frame may be smaller than the area, so the mask has
            // to hug the image rather than the box it sits in.
            let box = placement.fillMode == .fit
                ? CGRect(x: x, y: y, width: scaled.width, height: scaled.height).intersection(area)
                : area
            placed = placed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: roundedMask(for: box,
                                                  radius: min(cornerRadius,
                                                              min(box.width, box.height) / 2)),
            ])
        }
        return placed
    }

    /// Scales to cover `rect` entirely, centre-cropping the overflow.
    private func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
        let dx = rect.midX - scaled.extent.midX
        let dy = rect.midY - scaled.extent.midY
        return scaled
            .transformed(by: .init(translationX: dx, y: dy))
            .cropped(to: rect)
    }

    /// White where the camera shows, black where it is clipped away. Read as
    /// luminance by CIBlendWithMask, so it does not need an alpha channel.
    private func roundedMask(for rect: CGRect, radius: CGFloat) -> CIImage {
        let key = "\(Int(rect.width))x\(Int(rect.height))r\(Int(radius))"
        let mask: CIImage
        if let cached = maskCache[key] {
            mask = cached
        } else {
            let w = Int(rect.width), h = Int(rect.height)
            let cs = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return CIImage(color: .white).cropped(to: rect)
            }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            guard let cg = ctx.makeImage() else {
                return CIImage(color: .white).cropped(to: rect)
            }
            let built = CIImage(cgImage: cg)
            maskCache[key] = built
            mask = built
        }
        return mask.transformed(by: .init(translationX: rect.origin.x, y: rect.origin.y))
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                    attrs as CFDictionary, &created)
            pool = created
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
