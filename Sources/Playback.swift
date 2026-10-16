import AVFoundation
import AVKit
import CoreImage
import SwiftUI

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var error: String?
    var onTime: ((Double) -> Void)?
    private var observer: Any?
    private var statusObservation: NSKeyValueObservation?
    private var task: Task<Void, Never>?
    private var loadedMovie: [ProjectClip]?
    private var loadedCanvas: CGSize?
    private var loadedClip: ProjectClip?
    private var loadedSettings: ExportSettings?
    private var loadedOriginal = false
    private var loadedPicture: PictureKey?
    /// The Short the Preview shows, by id; nil shows the 16:9 video. Set by the app when
    /// the owner switches the viewer, so every `prepare` follows it.
    var shortID: UUID?
    /// While a Short shows, playback stops at its end.
    var stopAt: Double?
    private var requestedTime = 0.0
    private var playWhenReady = false
    private var seekGeneration = 0
    private var seeking = false

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, !self.isLoading else { return }
                self.isPlaying = self.player.rate != 0
                if self.isPlaying, let stop = self.stopAt, time.seconds >= stop - 0.0005 {
                    self.pause()
                    self.onTime?(stop)
                    return
                }
                if self.isPlaying { self.onTime?(time.seconds) }
            }
        }
    }

    func pause() {
        playWhenReady = false
        player.pause()
        isPlaying = false
    }

    func clear() {
        pause(); task?.cancel(); task = nil
        loadedClip = nil; loadedSettings = nil; loadedMovie = nil; loadedOriginal = false; loadedPicture = nil
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        isLoading = false; error = nil
    }

    func seek(to time: Double) {
        requestedTime = max(0, time)
        guard !isLoading, player.currentItem != nil else { return }
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        player.seek(to: CMTime(seconds: requestedTime, preferredTimescale: 600000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.seekGeneration else { return }
                self.seeking = false
            }
        }
    }

    /// What the picture is made of beyond the recording itself: the part shown (the crop,
    /// or a Short's window) and the graphics' native motion. A change here is a new video
    /// composition, not a new movie.
    struct PictureKey: Equatable {
        var crop: CGRect
        var motion: GraphicsMotion?
        /// A zoomed-out Short's taller 9:16 stage, with the picture at its top.
        var stage: CGSize?
    }

    static func picture(_ clip: VideoItem, info: MediaInfo, short: Short?) -> PictureKey {
        if let short {
            let picture = short.picture(info: info, crop: clip.crop)
            return PictureKey(crop: picture, motion: GraphicsMotion(clip.graphics?.forShort(short, recordingTime: true)),
                              stage: ShortFormat.stage(for: picture.size))
        }
        return PictureKey(crop: (clip.crop ?? info.fullFrame).evenClamped(in: info.fullFrame), motion: GraphicsMotion(clip.graphics))
    }

    /// `original` shows the recording without its colour stage, for comparison.
    func prepare(_ clip: VideoItem, settings: ExportSettings, at time: Double, play: Bool, original: Bool = false) {
        requestedTime = time
        playWhenReady = play
        let record = ProjectClip(clip)
        let short = clip.short(shortID)
        stopAt = short?.end
        let picture = clip.info.map { Self.picture(clip, info: $0, short: short) }
        if let loaded = loadedClip, loaded.withoutOverlays == record.withoutOverlays,
           loadedSettings == settings, loadedOriginal == original, error == nil {
            // Graphics draw in their own layer; only a change to the picture's motion or to
            // the part shown needs a new picture, and that is a composition swap, not a
            // new movie.
            if loadedPicture != picture, let item = player.currentItem, !isLoading, let info = clip.info {
                item.videoComposition = Self.videoComposition(for: item.asset, clip: clip, info: info,
                                                              settings: settings, original: original, short: short)
            }
            loadedClip = record; loadedPicture = picture
            seek(to: time)
            if !isLoading, play { player.play(); isPlaying = true }
            return
        }
        // A colour or effect change alone needs a new picture, not a new movie: swapping
        // the video composition keeps the loaded item, its position and its audio.
        var recolored = loadedClip
        recolored?.color = record.color
        recolored?.blurEffects = record.blurEffects
        recolored?.markers = record.markers
        // A screen's layouts, bubble and crop are drawn, not loaded: only another file or
        // offset needs new tracks.
        if let loaded = recolored?.screen, let screen = record.screen, loaded.url == screen.url, loaded.offset == screen.offset {
            recolored?.screen = screen
        }
        if let item = player.currentItem, !isLoading, error == nil, loadedMovie == nil,
           recolored?.withoutOverlays == record.withoutOverlays, loadedSettings == settings, let info = clip.info {
            item.videoComposition = Self.videoComposition(for: item.asset, clip: clip, info: info,
                                                          settings: settings, original: original, short: short)
            loadedClip = record; loadedOriginal = original; loadedPicture = picture
            seek(to: time)
            if play { player.play(); isPlaying = true }
            return
        }
        task?.cancel()
        player.pause(); isPlaying = false
        loadedMovie = nil
        loadedClip = record; loadedSettings = settings; loadedOriginal = original; loadedPicture = picture
        error = nil; isLoading = true
        task = Task {
            do {
                let item = try await Self.makeItem(clip, settings: settings, original: original, short: short)
                try Task.checkCancellation()
                player.replaceCurrentItem(with: item)
                statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        if item.status == .failed {
                            self.error = item.error?.localizedDescription ?? "Playback failed."
                            self.isLoading = false
                            self.pause()
                        }
                    }
                }
                isLoading = false
                seek(to: requestedTime)
                if playWhenReady { player.play(); isPlaying = true }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    func prepareMovie(_ plan: MoviePlan, settings: ExportSettings, at time: Double, play: Bool) {
        requestedTime = time; playWhenReady = play
        let records = plan.clips.map(ProjectClip.init)
        if loadedMovie == records, loadedCanvas == plan.size, loadedSettings == settings, error == nil {
            seek(to: time)
            if !isLoading, play { player.play(); isPlaying = true }
            return
        }
        task?.cancel(); player.pause(); isPlaying = false; stopAt = nil
        loadedClip = nil; loadedMovie = records; loadedCanvas = plan.size; loadedSettings = settings; loadedOriginal = false; loadedPicture = nil
        isLoading = true; error = nil
        task = Task {
            do {
                let item = try await Self.makeMovieItem(plan, settings: settings)
                try Task.checkCancellation()
                player.replaceCurrentItem(with: item)
                statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        if item.status == .failed {
                            self.error = item.error?.localizedDescription ?? "Movie playback failed."
                            self.pause(); self.isLoading = false
                        }
                    }
                }
                isLoading = false; seek(to: requestedTime)
                if playWhenReady { player.play(); isPlaying = true }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }

    static func makeItem(_ clip: VideoItem, settings: ExportSettings, original: Bool = false, short: Short? = nil) async throws -> AVPlayerItem {
        guard let info = clip.info else { throw FFmpegError(message: "The video is still loading.") }
        let asset = AVURLAsset(url: clip.url)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw FFmpegError(message: "macOS cannot play this video format. Export it to MP4 to preview it.")
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FFmpegError(message: "Could not create the video preview.")
        }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let audio = sourceAudio != nil && settings.audio != .none && !settings.format.isAnimation
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let audioRange = try await sourceAudio?.load(.timeRange)
        var position = CMTime.zero
        for segment in clip.timeline.segments {
            let range = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600000),
                                    duration: CMTime(seconds: segment.sourceDuration, preferredTimescale: 600000))
            try video.insertTimeRange(range, of: sourceVideo, at: position)
            if let sourceAudio, let audio, let audioRange {
                let intersection = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if intersection.duration > .zero {
                    try audio.insertTimeRange(intersection, of: sourceAudio,
                                              at: position + intersection.start - range.start)
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
        if let screen = clip.screen, short.map(clip.stacksScreen) ?? true {
            try await insertScreen(screen, segments: clip.timeline.segments, into: composition)
        }
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition(for: composition, clip: clip, info: info, settings: settings, original: original, short: short)
        item.audioTimePitchAlgorithm = .spectral
        let mix = AVMutableAudioMix()
        mix.inputParameters = composition.tracks(withMediaType: .audio).map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTimePitchAlgorithm = .spectral
            return parameters
        }
        item.audioMix = mix
        return item
    }

    /// Everything drawn on top of the assembled sections. A colour stage that cannot be
    /// applied shows the picture as recorded; the inspector says why. With a Short, the
    /// picture is its 9:16 window, with its graphics' motion.
    static func videoComposition(for asset: AVAsset, clip: VideoItem, info: MediaInfo,
                                 settings: ExportSettings, original: Bool, short: Short? = nil) -> AVVideoComposition {
        if let screen = clip.screen, short.map(clip.stacksScreen) ?? true, let composition = asset as? AVComposition,
           let layout = screenComposition(for: composition, clip: clip, screen: screen, info: info, settings: settings, original: original, short: short) {
            return layout
        }
        let picture = picture(clip, info: info, short: short)
        let crop = picture.crop
        let shots = clip.zoomShots
        let regions = clip.blurRegions
        let effects = clip.blurEffects
        let color = ColorPipeline.stage(clip.color, info: info, fileName: clip.name,
                                        toneMapHDR: settings.toneMapHDR, original: original).render
        let motion = picture.motion, stage = picture.stage
        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let result = renderFrame(request.sourceImage, info: info, crop: crop,
                                     regions: regions, shots: shots, settings: settings,
                                     time: request.compositionTime.seconds, color: color, effects: effects, motion: motion, stage: stage)
            request.finish(with: result, context: nil)
        }
        videoComposition.renderSize = stage ?? crop.size
        let rate = info.fpsExpression.split(separator: "/")
        if rate.count == 2, let numerator = Int32(rate[0]), let denominator = Int64(rate[1]), numerator > 0, denominator > 0 {
            videoComposition.frameDuration = CMTime(value: denominator, timescale: numerator)
        } else {
            videoComposition.frameDuration = CMTime(seconds: 1 / max(1, info.fps), preferredTimescale: 600000)
        }
        return videoComposition
    }
}

/// Core Image uses a bottom-left origin; editor/export rectangles use top-left.
///
/// Order follows the shared rendering contract: colour first, on the whole frame, then
/// area obscuring, crop and zoom. A black area therefore stays black whatever the grade.
func renderFrame(_ source: CIImage, info: MediaInfo, crop: CGRect, regions: [BlurRegion],
                 shots: [ZoomShot], settings: ExportSettings, time: Double, color: ColorRender? = nil,
                 effects: [VideoBlurEffect] = [], motion: GraphicsMotion? = nil, stage: CGSize? = nil) -> CIImage {
    var image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
    if let color { image = ColorPipeline.apply(color, to: image, space: source.colorSpace) }
    for region in regions {
        let rect = region.rect.evenClamped(in: info.fullFrame)
        let area = CGRect(x: rect.minX, y: CGFloat(info.height) - rect.maxY, width: rect.width, height: rect.height)
        let patch: CIImage
        switch settings.blurStyle {
        case .black:
            patch = CIImage(color: .black).cropped(to: area)
        case .blur:
            patch = image.cropped(to: area).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.blurStrength]).cropped(to: area)
        case .pixelate:
            patch = image.cropped(to: area).clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: settings.blurStrength,
                    kCIInputCenterKey: CIVector(x: area.minX, y: area.minY)]).cropped(to: area)
        }
        image = patch.composited(over: image)
    }
    let area = CGRect(x: crop.minX, y: CGFloat(info.height) - crop.maxY, width: crop.width, height: crop.height)
    image = image.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
    if let shot = shots.first(where: { time >= $0.start && time < $0.end }) {
        let phase = min(1, max(0, min((time - shot.start) / ZoomShot.ease, (shot.end - time) / ZoomShot.ease)))
        let ramp = phase * phase * (3 - 2 * phase)
        let zoom = 1 + (shot.level - 1) * ramp
        let cx = crop.width / 2 + (shot.target.x - crop.minX - crop.width / 2) * ramp
        let cy = crop.height / 2 + (shot.target.y - crop.minY - crop.height / 2) * ramp
        let width = crop.width / zoom, height = crop.height / zoom
        let x = max(0, min(cx - width / 2, crop.width - width))
        let top = max(0, min(cy - height / 2, crop.height - height))
        let y = crop.height - top - height
        image = image.transformed(by: CGAffineTransform(translationX: -x, y: -y))
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
    }
    let bounds = CGRect(origin: .zero, size: crop.size)
    image = image.cropped(to: bounds)
    if let effect = effects.first(where: { $0.isVisible && $0.weight(at: time) > 0 }) {
        image = applyBlurEffect(effect, to: image, bounds: bounds, weight: effect.weight(at: time))
    }
    var size = crop.size
    if let stage {
        image = zoomOut(image, picture: crop.size, stage: stage)
        size = stage
    }
    if let motion { image = moveAside(image, size: size, motion: motion, time: time) }
    return image
}

/// A zoomed-out Short: the picture at the top of its taller 9:16 stage, its bottom edge
/// fading over `ShortFormat.zoomFade` design pixels into the fill below, made as the moved
/// picture's is (the picture grown to cover the stage, blurred, darkened). The export
/// draws the same (`FFmpeg.zoomStage`), on the encoded values.
func zoomOut(_ image: CIImage, picture: CGSize, stage: CGSize) -> CIImage {
    let frame = CGRect(origin: .zero, size: stage)
    let space = ColorPipeline.videoSpace
    guard let base = image.cropped(to: CGRect(origin: .zero, size: picture)).matchedFromWorkingSpace(to: space) else { return image }
    // The picture scaled to cover the stage, centred, then the moved picture's fill of it.
    let cover = stage.height / picture.height
    let covered = base.clampedToExtent()
        .transformed(by: CGAffineTransform(scaleX: cover, y: cover))
        .transformed(by: CGAffineTransform(translationX: -(picture.width * cover - stage.width) / 2, y: 0))
        .cropped(to: frame)
    let fill = movedPictureFill(covered, frame: frame, amount: 1)
    // Core Image's y runs up: the picture's top at the stage's top.
    let bottom = stage.height - picture.height
    let placed = base.transformed(by: CGAffineTransform(translationX: 0, y: bottom))
    let fade = ShortFormat.zoomFade * GraphicsMotion.unit(stage)
    let result = placed.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: fill,
        kCIInputMaskImageKey: linearRamp(from: CGPoint(x: 0, y: bottom), to: CGPoint(x: 0, y: bottom + fade), strength: 1, frame: frame),
    ])
    return (result.matchedToWorkingSpace(from: space) ?? result).cropped(to: frame)
}

/// A whole-frame blur mixed in at `weight`, matching the export: blurred and mixed on the
/// frame's encoded values, as ffmpeg does, not in Core Image's linear working space, where
/// a blur pulls highlights outward. Edges repeat their outermost pixels, so no dark or
/// transparent halo creeps in.
func applyBlurEffect(_ effect: VideoBlurEffect, to image: CIImage, bounds: CGRect, weight: Double) -> CIImage {
    let space = ColorPipeline.videoSpace
    guard let encoded = image.matchedFromWorkingSpace(to: space) else { return image }
    let blurred = encoded.clampedToExtent()
        .applyingGaussianBlur(sigma: effect.sigma(for: bounds.size) * BlurCalibration.coreImageRadiusPerSigma)
        .cropped(to: bounds)
    let mixed = weight >= 1 ? blurred : encoded.applyingFilter("CIDissolveTransition", parameters: [
        kCIInputTargetImageKey: blurred, kCIInputTimeKey: weight,
    ])
    return (mixed.matchedToWorkingSpace(from: space) ?? mixed).cropped(to: bounds)
}

/// Core Image's Gaussian radius against ffmpeg's `gblur` sigma, measured by the parity
/// checks in `./test.sh`.
enum BlurCalibration {
    static let coreImageRadiusPerSigma = 1.0
}

/// While a side panel shows, the picture slides left by a quarter of its width. A larger,
/// blurred, darker copy of the same frame fills the space it leaves, the moved picture's
/// right edge fades into that copy, and a frost fades in under the panel. Sizes are in
/// design pixels of a 1920-wide frame, scaled to the real width. The export draws the same
/// (`FFmpeg.moveStage`): like the blur effects, everything here works on the frame's
/// encoded values, as ffmpeg does, not in Core Image's linear working space.
///
/// From the end screen's start the picture instead moves into the end screen's frame,
/// over the same fill, and stays there.
func moveAside(_ image: CIImage, size: CGSize, motion: GraphicsMotion, time: Double) -> CIImage {
    if let screen = motion.screen, time >= screen.start {
        let amount = motion.screenProgress(at: time)
        return moveIntoFrame(image, size: size, place: motion.screenPlacement(amount: amount, size: size), amount: amount)
    }
    let (amount, span) = motion.progress(at: time)
    guard amount > 0.0001, let span else { return image }
    // A Short's split: the picture shrinks into its frame in the top half, over the fill.
    if motion.short == .split {
        return moveIntoFrame(image, size: size, place: motion.splitPlacement(amount: amount, size: size), amount: amount)
    }
    let frame = CGRect(origin: .zero, size: size)
    let w = size.width, h = size.height, unit = GraphicsMotion.unit(size)
    let space = ColorPipeline.videoSpace
    guard let base = image.cropped(to: frame).matchedFromWorkingSpace(to: space) else { return image }
    var result: CIImage
    switch motion.short {
    case nil:
        let behind = movedPictureFill(base, frame: frame, amount: amount)
        let shift = w * GraphicsTrack.shiftFraction * amount
        let moved = base.transformed(by: CGAffineTransform(translationX: -shift, y: 0))
        let fade = GraphicsMotion.edgeFade * unit * amount
        result = moved.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: behind,
            kCIInputMaskImageKey: linearRamp(from: CGPoint(x: w - shift - fade + max(fade, 0.5), y: 0), to: CGPoint(x: w - shift - fade, y: 0),
                                             strength: 1, frame: frame),
        ])
    case .sheet?:
        // The picture lifts; its bottom edge fades into the fill. Core Image's y runs up.
        let behind = movedPictureFill(base, frame: frame, amount: amount)
        let shift = CGFloat(motion.lift(amount: amount, size: size))
        let moved = base.transformed(by: CGAffineTransform(translationX: 0, y: shift))
        let fade = GraphicsMotion.edgeFade * unit * amount
        result = moved.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: behind,
            kCIInputMaskImageKey: linearRamp(from: CGPoint(x: 0, y: shift + fade - max(fade, 0.5)), to: CGPoint(x: 0, y: shift + fade),
                                             strength: 1, frame: frame),
        ])
    case .shade?, .split?:
        result = base
    }

    if let ramp = motion.frostRamp(for: span) {
        let frosted = result.clampedToExtent()
            .applyingGaussianBlur(sigma: ramp.blur * unit * BlurCalibration.coreImageRadiusPerSigma).cropped(to: frame)
        // Across the 16:9 frame from left to right; down a Short from top to bottom.
        let mask = motion.short == nil
            ? linearRamp(from: CGPoint(x: ramp.from * w, y: 0), to: CGPoint(x: max(ramp.to * w, ramp.from * w + 0.5), y: 0), strength: amount, frame: frame)
            : linearRamp(from: CGPoint(x: 0, y: h - ramp.from * h), to: CGPoint(x: 0, y: min(h - ramp.to * h, h - ramp.from * h - 0.5)), strength: amount, frame: frame)
        result = frosted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask])
    }
    return (result.matchedToWorkingSpace(from: space) ?? result).cropped(to: frame)
}

/// The fill behind a moved picture, from its encoded values: the frame grown by
/// `fillScale`, blurred, then darkened and desaturated by one matrix, faded in with the
/// move. Over black, so `amount` scales the colour, as ffmpeg's table does.
func movedPictureFill(_ base: CIImage, frame: CGRect, amount: Double) -> CIImage {
    let w = frame.width, h = frame.height, unit = GraphicsMotion.unit(frame.size)
    let scale = GraphicsMotion.fillScale
    let grow = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
    let luma = GraphicsMotion.lumaWeights, s = GraphicsMotion.fillSaturation
    let gain = GraphicsMotion.fillDim * amount
    func row(_ index: Int) -> CIVector {
        let weights = [luma.r, luma.g, luma.b].enumerated().map { gain * ((1 - s) * $0.element + ($0.offset == index ? s : 0)) }
        return CIVector(x: weights[0], y: weights[1], z: weights[2], w: 0)
    }
    return base.clampedToExtent().transformed(by: grow)
        .applyingGaussianBlur(sigma: GraphicsMotion.fillBlur * unit * BlurCalibration.coreImageRadiusPerSigma)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        .cropped(to: frame)
}

/// The picture scaled with Lanczos, as ffmpeg's `scale` does, at a whole-pixel place
/// (top-left origin) over the moved-picture fill: the end screen's move and a Short's split.
private func moveIntoFrame(_ image: CIImage, size: CGSize, place: (x: Int, y: Int, width: Int, height: Int), amount: Double) -> CIImage {
    guard amount > 0.0001 else { return image }
    let frame = CGRect(origin: .zero, size: size)
    let space = ColorPipeline.videoSpace
    guard let base = image.cropped(to: frame).matchedFromWorkingSpace(to: space) else { return image }
    let across = Double(place.width) / size.width, down = Double(place.height) / size.height
    let piece = CGRect(x: 0, y: 0, width: place.width, height: place.height)
    // Edges repeat their outermost pixels, so the scaled picture has no soft border.
    let picture = base.clampedToExtent()
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: down, kCIInputAspectRatioKey: across / down])
        .cropped(to: piece)
        .transformed(by: CGAffineTransform(translationX: CGFloat(place.x), y: size.height - CGFloat(place.y + place.height)))
    let result = picture.composited(over: movedPictureFill(base, frame: frame, amount: amount))
    return (result.matchedToWorkingSpace(from: space) ?? result).cropped(to: frame)
}

/// A grey ramp for CIBlendWithMask: 0 at `from` and `strength` at `to`, along the line
/// between them (Core Image coordinates), held beyond both. The colours are linear, so
/// the mask values are the numbers given rather than sRGB greys converted to light.
private func linearRamp(from: CGPoint, to: CGPoint, strength: Double, frame: CGRect) -> CIImage {
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let low = CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: linear)!
    let high = CIColor(red: strength, green: strength, blue: strength, alpha: 1, colorSpace: linear)!
    return CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: from.x, y: from.y), "inputPoint1": CIVector(x: to.x, y: to.y),
        "inputColor0": low, "inputColor1": high,
    ])!.outputImage!.cropped(to: frame)
}

struct PlaybackCanvas: View {
    @ObservedObject var playback: PlaybackController
    /// The selected recording's graphics, drawn over the picture.
    var graphics: GraphicsOverlayInput? = nil
    /// Lets the owner select, move and resize the graphics on the picture.
    var editsGraphics = false
    /// The Short shown, whose own placements drags change.
    var short: UUID? = nil
    /// Where YouTube draws over a Short, faintly.
    var furniture = false
    var onGraphicBounds: ([UUID: GraphicBounds]) -> Void = { _ in }
    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: playback.player)
            if let graphics, graphics.frame.width > 0, graphics.frame.height > 0 {
                GeometryReader { geo in
                    // The player fits the picture inside its bounds; the overlay matches it.
                    let scale = min(geo.size.width / graphics.frame.width, geo.size.height / graphics.frame.height)
                    let size = CGSize(width: graphics.frame.width * scale, height: graphics.frame.height * scale)
                    GraphicsOverlay(input: graphics, onBounds: onGraphicBounds)
                        .frame(width: size.width, height: size.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                    if furniture {
                        ShortFurniture()
                            .frame(width: size.width, height: size.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    if editsGraphics {
                        GraphicsPlacementLayer(input: graphics, short: short)
                            .frame(width: size.width, height: size.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
            }
            if playback.isLoading { ProgressView("Preparing preview…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
            if let error = playback.error {
                Text(error).font(.callout).multilineTextAlignment(.center)
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(16)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
