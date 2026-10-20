import AVFoundation
import CoreImage

// All instruction data is immutable, including the NSNumber track identifiers.
final class MovieInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let clip: VideoItem
    let transform: CGAffineTransform
    let settings: ExportSettings
    let canvas: CGSize
    /// The recording's colour stage, compiled once for every frame it draws.
    let color: ColorRender?

    init(range: CMTimeRange, trackID: CMPersistentTrackID, clip: VideoItem,
         transform: CGAffineTransform, settings: ExportSettings, canvas: CGSize) {
        timeRange = range; self.trackID = trackID; self.clip = clip
        self.transform = transform; self.settings = settings; self.canvas = canvas
        color = clip.colorStage(settings).render
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Separate instructions retain each source's rotation and coordinate space even when
/// portrait, landscape and cropped recordings share a movie.
final class MovieCompositor: NSObject, AVVideoCompositing {
    /// Half-float sources, so a 10-bit recording reaches its colour table without first
    /// being rounded to 8 bits. Only the displayed frame is 8-bit.
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf]]
    }
    var supportsWideColorSourceFrames: Bool { true }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()]
    }
    private let queue = DispatchQueue(label: "YamVideo.movie-render", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var renderContext: AVVideoCompositionRenderContext?
    private var generation = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock(); renderContext = newRenderContext; lock.unlock()
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock(); generation += 1; lock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let expected = generation; let renderer = renderContext; lock.unlock()
        queue.async { [self] in
            lock.lock(); let cancelled = generation != expected; lock.unlock()
            if cancelled { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? MovieInstruction,
                  let source = request.sourceFrame(byTrackID: instruction.trackID),
                  let output = renderer?.newPixelBuffer(), let info = instruction.clip.info else {
                request.finish(with: FFmpegError(message: "Could not render the movie frame.")); return
            }
            let t = instruction.transform
            // AV track matrices use a top-left origin; Core Image uses bottom-left.
            let oriented = CIImage(cvPixelBuffer: source).transformed(by:
                CGAffineTransform(a: t.a, b: -t.b, c: -t.c, d: t.d, tx: 0, ty: 0))
            let crop = (instruction.clip.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
            let edited = renderFrame(oriented, info: info, crop: crop,
                                     regions: instruction.clip.blurRegions, shots: instruction.clip.zoomShots,
                                     settings: instruction.settings,
                                     time: request.compositionTime.seconds - instruction.timeRange.start.seconds,
                                     color: instruction.color, effects: instruction.clip.blurEffects)
            let canvas = instruction.canvas
            let factor = min(canvas.width / crop.width, canvas.height / crop.height)
            let width = max(2, floor(crop.width * factor / 2) * 2)
            let height = max(2, floor(crop.height * factor / 2) * 2)
            let fitted = edited.transformed(by: CGAffineTransform(scaleX: width / crop.width, y: height / crop.height))
                .transformed(by: CGAffineTransform(translationX: (canvas.width - width) / 2, y: (canvas.height - height) / 2))
            let bounds = CGRect(origin: .zero, size: canvas)
            let result = fitted.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
            // Written and tagged as Rec.709 video, the space a single recording's preview
            // and every export use, rather than whatever the display happens to be.
            context.render(result, to: output, bounds: bounds, colorSpace: ColorPipeline.videoSpace)
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            request.finish(withComposedVideoFrame: output)
        }
    }
}

extension PlaybackController {
    static func makeMovieItem(_ plan: MoviePlan, settings: ExportSettings) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        var instructions: [MovieInstruction] = []
        var position = CMTime.zero
        /// Each recording's audio track: where it starts in the movie and where its sound is cut.
        var joints: [CMPersistentTrackID: (offset: Double, joints: [(time: Double, fade: Double)])] = [:]
        /// Each recording's music, from where the recording starts in the movie.
        var music: MusicPreviewTracks?
        for clip in plan.clips {
            try Task.checkCancellation()
            let source = AVURLAsset(url: clip.url)
            guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first,
                  let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FFmpegError(message: "macOS cannot preview \(clip.name). Export this source to MP4 first.")
            }
            let transform = try await sourceVideo.load(.preferredTransform)
            let sourceAudio = try await source.loadTracks(withMediaType: .audio).first
            let audio = sourceAudio != nil && settings.audio != .none && !settings.format.isAnimation
                ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
            let audioRange = try await sourceAudio?.load(.timeRange)
            let beginning = position
            if let audio { joints[audio.trackID] = (beginning.seconds, clip.timeline.audioJoints) }
            for segment in clip.timeline.segments {
                let range = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600000),
                                        duration: CMTime(seconds: segment.sourceDuration, preferredTimescale: 600000))
                try video.insertTimeRange(range, of: sourceVideo, at: position)
                if let sourceAudio, let audio, let audioRange {
                    let available = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                    if available.duration > .zero {
                        try audio.insertTimeRange(available, of: sourceAudio, at: position + available.start - range.start)
                    }
                }
                if segment.speed != 1 {
                    let outputDuration = CMTime(seconds: segment.duration, preferredTimescale: 600000)
                    let inserted = CMTimeRange(start: position, duration: range.duration)
                    video.scaleTimeRange(inserted, toDuration: outputDuration)
                    if let audio {
                        let end = position + range.duration
                        if audio.timeRange.end < end {
                            audio.insertEmptyTimeRange(CMTimeRange(start: audio.timeRange.end, duration: end - audio.timeRange.end))
                        }
                        audio.scaleTimeRange(inserted, toDuration: outputDuration)
                    }
                }
                position = position + CMTime(seconds: segment.duration, preferredTimescale: 600000)
            }
            if audio != nil, let mix = clip.exportMusic(settings) {
                if music == nil { music = MusicPreviewTracks(composition) }
                try await music?.insert(mix, offset: beginning.seconds)
            }
            instructions.append(MovieInstruction(range: CMTimeRange(start: beginning, duration: position - beginning),
                                                  trackID: video.trackID, clip: clip, transform: transform,
                                                  settings: settings, canvas: plan.size))
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = MovieCompositor.self
        videoComposition.instructions = instructions
        videoComposition.renderSize = plan.size
        let rate = plan.fpsExpression.split(separator: "/")
        if rate.count == 2, let n = Int32(rate[0]), let d = Int64(rate[1]), n > 0, d > 0 {
            videoComposition.frameDuration = CMTime(value: d, timescale: n)
        } else { videoComposition.frameDuration = CMTime(seconds: 1 / max(1, plan.fps), preferredTimescale: 600000) }
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioTimePitchAlgorithm = .spectral
        let mix = AVMutableAudioMix()
        mix.inputParameters = composition.tracks(withMediaType: .audio).map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTimePitchAlgorithm = .spectral
            // Each recording's sound fades out and in at its cuts, as its export does.
            if let clipJoints = joints[track.trackID] {
                PlaybackController.fadeJoints(clipJoints.joints, offset: clipJoints.offset, in: parameters)
            }
            music?.ramp(parameters)
            return parameters
        }
        item.audioMix = mix
        return item
    }
}
