import AVFoundation
import CoreImage

// The preview of a recording with a screen (docs/plans/screen-speaker.md, section 5): the
// composition has two video tracks, and `ScreenCompositor` draws each frame from both.

/// The whole composition as one instruction: which tracks to read and how to draw a frame.
final class ScreenCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let speakerTrack: CMPersistentTrackID
    let screenTrack: CMPersistentTrackID
    /// The frame at a composition time, from the speaker's frame and the screen's.
    let draw: (_ speaker: CIImage, _ screen: CIImage?, _ time: Double) -> CIImage

    init(timeRange: CMTimeRange, speakerTrack: CMPersistentTrackID, screenTrack: CMPersistentTrackID,
         draw: @escaping (CIImage, CIImage?, Double) -> CIImage) {
        self.timeRange = timeRange
        self.speakerTrack = speakerTrack
        self.screenTrack = screenTrack
        self.requiredSourceTrackIDs = [NSNumber(value: speakerTrack), NSNumber(value: screenTrack)]
        self.draw = draw
    }
}

/// Draws a frame of a recording with a screen. The engine hands both sources over in
/// half-float RGB, converted to the composition's Rec.709. Core Image reads them, and
/// writes the frame, in Core Media's own 709 space (`ColorPipeline.videoSpace`), as the
/// one-track preview does: the encoded values ffmpeg works on go through unchanged.
final class ScreenCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let space = ColorPipeline.videoSpace

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf],
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ScreenCompositionInstruction,
              let speaker = request.sourceFrame(byTrackID: instruction.speakerTrack),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: FFmpegError(message: "A frame of the screen layout could not be drawn."))
            return
        }
        let read = { (buffer: CVPixelBuffer) in CIImage(cvPixelBuffer: buffer, options: [.colorSpace: self.space]) }
        let screen = request.sourceFrame(byTrackID: instruction.screenTrack).map(read)
        let image = instruction.draw(read(speaker), screen, request.compositionTime.seconds)
        let size = request.renderContext.size
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: space)
        request.finish(withComposedVideoFrame: output)
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

extension PlaybackController {
    /// Adds the screen's track to `composition`: for each section, the screen's matching
    /// range, scaled for speed as the speaker is. Before the screen recording starts or
    /// after it ends, its first or last frame holds.
    static func insertScreen(_ screen: ScreenTrack, segments: [TimelineSegment], into composition: AVMutableComposition) async throws {
        let asset = AVURLAsset(url: screen.url)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw FFmpegError(message: "macOS cannot play the screen recording \(screen.name).")
        }
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FFmpegError(message: "Could not create the screen's preview.")
        }
        let available = try await source.load(.timeRange)
        let first = available.start.seconds, last = available.end.seconds
        let still = 0.01
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600000) }
        var position = CMTime.zero
        for segment in segments {
            let from = segment.start + screen.offset, to = segment.end + screen.offset
            var cursor = position
            /// One frame of the screen recording, held for `length` seconds.
            func hold(at moment: Double, for length: Double) throws {
                guard length > 0.000001 else { return }
                let frame = CMTimeRange(start: time(moment), duration: time(still))
                try track.insertTimeRange(frame, of: source, at: cursor)
                track.scaleTimeRange(CMTimeRange(start: cursor, duration: time(still)), toDuration: time(length))
                cursor = cursor + time(length)
            }
            try hold(at: first, for: min(to, first) - from)
            let start = max(from, first), end = min(to, last)
            if end - start > 0.000001 {
                try track.insertTimeRange(CMTimeRange(start: time(start), duration: time(end - start)), of: source, at: cursor)
                cursor = cursor + time(end - start)
            }
            try hold(at: max(first, last - still), for: to - max(from, last))
            if segment.speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: position, duration: time(segment.sourceDuration)), toDuration: time(segment.duration))
            }
            position = position + time(segment.duration)
        }
    }

    /// The video composition for a recording with a screen: the speaker drawn as the
    /// one-track preview draws it, the layout put together, then the move aside.
    static func screenComposition(for composition: AVComposition, clip: VideoItem, screen: ScreenTrack, info: MediaInfo,
                                  settings: ExportSettings, original: Bool) -> AVVideoComposition? {
        let tracks = composition.tracks.filter { $0.mediaType == .video }
        guard tracks.count >= 2 else { return nil }
        let key = Self.picture(clip, info: info, short: nil)
        let crop = key.crop, motion = key.motion
        let shots = clip.zoomShots, regions = clip.blurRegions, effects = clip.blurEffects
        let color = ColorPipeline.stage(clip.color, info: info, fileName: clip.name, toneMapHDR: settings.toneMapHDR, original: original).render
        let geometry = LayoutGeometry(track: screen, crop: crop)
        let endScreen = clip.graphics?.endScreen?.start
        let end = tracks.map { $0.timeRange.end }.max() ?? .zero
        let instruction = ScreenCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, end: end), speakerTrack: tracks[0].trackID, screenTrack: tracks[1].trackID
        ) { speaker, screenFrame, time in
            let face = renderFrame(speaker, info: info, crop: crop, regions: regions, shots: shots, settings: settings,
                                   time: time, color: color, effects: effects)
            let state = screen.state(at: time, geometry: geometry, endScreen: endScreen)
            let frame = composeLayout(speaker: face, screen: screenFrame, track: screen, state: state, frame: crop.size, time: time)
            guard let motion else { return frame }
            return moveAside(frame, size: crop.size, motion: motion, time: time)
        }
        let result = AVMutableVideoComposition()
        result.customVideoCompositorClass = ScreenCompositor.self
        result.instructions = [instruction]
        result.renderSize = crop.size
        result.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        result.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        result.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let rate = info.fpsExpression.split(separator: "/")
        if rate.count == 2, let numerator = Int32(rate[0]), let denominator = Int64(rate[1]), numerator > 0, denominator > 0 {
            result.frameDuration = CMTime(value: denominator, timescale: numerator)
        } else {
            result.frameDuration = CMTime(seconds: 1 / max(1, info.fps), preferredTimescale: 600000)
        }
        return result
    }
}

/// The speaker (already drawn: colour, blur areas, crop, zoom, effects) and the screen in
/// one frame, as `state` places them. Like the move aside, it works on the frames' encoded
/// values, as ffmpeg does: the screen zoomed at `time` as its zooms say, the fill from it,
/// the screen with rounded corners over that, then the speaker's window, scaled with
/// Lanczos into its place and masked. The export draws the same (`FFmpeg.layoutStage`).
func composeLayout(speaker: CIImage, screen: CIImage?, track: ScreenTrack, state: LayoutState, frame: CGSize, time: Double = 0) -> CIImage {
    guard let screenPlace = state.screen else { return speaker }
    let bounds = CGRect(origin: .zero, size: frame)
    let space = ColorPipeline.videoSpace
    guard let face = speaker.cropped(to: bounds).matchedFromWorkingSpace(to: space) else { return speaker }
    let crop = track.picture
    var picture: CIImage
    if let screen {
        let source = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
        let area = CGRect(x: crop.minX, y: CGFloat(track.info.height) - crop.maxY, width: crop.width, height: crop.height)
        picture = source.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
        picture = picture.matchedFromWorkingSpace(to: space) ?? picture
    } else {
        picture = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: crop.size))
    }
    // A zoom: its window grown back to the picture's size, as a recording's own zoom is.
    let zoomed = track.zoomWindow(at: time)
    if zoomed.width < crop.width - 0.0001 {
        let zoom = crop.width / zoomed.width
        picture = picture.transformed(by: CGAffineTransform(translationX: -zoomed.minX, y: -(crop.height - zoomed.maxY)))
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            .cropped(to: CGRect(origin: .zero, size: crop.size))
    }
    // The fill: the screen grown to cover the frame, centred, then blurred and darkened.
    let cover = max(frame.width / crop.width, frame.height / crop.height)
    let covered = picture.clampedToExtent()
        .transformed(by: CGAffineTransform(scaleX: cover, y: cover))
        .transformed(by: CGAffineTransform(translationX: -(crop.width * cover - frame.width) / 2, y: -(crop.height * cover - frame.height) / 2))
        .cropped(to: bounds)
    var result = movedPictureFill(covered, frame: bounds, amount: 1)
    result = placed(picture, size: crop.size, in: screenPlace, frame: frame).composited(over: result)
    let window = state.window
    let area = CGRect(x: window.minX, y: frame.height - window.maxY, width: window.width, height: window.height)
    let cut = face.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
    result = placed(cut, size: window.size, in: state.speaker, frame: frame).composited(over: result)
    return (result.matchedToWorkingSpace(from: space) ?? result).cropped(to: bounds)
}

/// `image` (`size`, at the origin) scaled with Lanczos into `place`, with its corners
/// rounded. Edges repeat their outermost pixels, so the scaled picture has no soft border.
private func placed(_ image: CIImage, size: CGSize, in place: LayoutPlace, frame: CGSize) -> CIImage {
    let rect = place.rect
    let across = rect.width / size.width, down = rect.height / size.height
    let piece = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
    let moved = image.clampedToExtent()
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: down, kCIInputAspectRatioKey: across / down])
        .cropped(to: piece)
        .transformed(by: CGAffineTransform(translationX: rect.minX, y: frame.height - rect.maxY))
    guard place.radius >= 0.5 else { return moved }
    let shape = CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
    let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
        "inputExtent": CIVector(cgRect: shape), "inputRadius": place.radius, "inputColor": CIColor.white,
    ])!.outputImage!
    return moved.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
}
