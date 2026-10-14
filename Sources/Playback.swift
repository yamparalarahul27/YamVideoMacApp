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
    private var requestedTime = 0.0
    private var playWhenReady = false
    private var seekGeneration = 0
    private var seeking = false

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, !self.isLoading else { return }
                self.isPlaying = self.player.rate != 0
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
        loadedClip = nil; loadedSettings = nil; loadedMovie = nil; loadedOriginal = false
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

    /// `original` shows the recording without its colour stage, for comparison.
    func prepare(_ clip: VideoItem, settings: ExportSettings, at time: Double, play: Bool, original: Bool = false) {
        requestedTime = time
        playWhenReady = play
        let record = ProjectClip(clip)
        if loadedClip == record, loadedSettings == settings, loadedOriginal == original, error == nil {
            seek(to: time)
            if !isLoading, play { player.play(); isPlaying = true }
            return
        }
        // A colour change alone needs a new picture, not a new movie: swapping the video
        // composition keeps the loaded item, its position and its audio.
        var recolored = loadedClip
        recolored?.color = record.color
        if let item = player.currentItem, !isLoading, error == nil, loadedMovie == nil,
           recolored == record, loadedSettings == settings, let info = clip.info {
            item.videoComposition = Self.videoComposition(for: item.asset, clip: clip, info: info,
                                                          settings: settings, original: original)
            loadedClip = record; loadedOriginal = original
            seek(to: time)
            if play { player.play(); isPlaying = true }
            return
        }
        task?.cancel()
        player.pause(); isPlaying = false
        loadedMovie = nil
        loadedClip = record; loadedSettings = settings; loadedOriginal = original
        error = nil; isLoading = true
        task = Task {
            do {
                let item = try await Self.makeItem(clip, settings: settings, original: original)
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
        task?.cancel(); player.pause(); isPlaying = false
        loadedClip = nil; loadedMovie = records; loadedCanvas = plan.size; loadedSettings = settings; loadedOriginal = false
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

    static func makeItem(_ clip: VideoItem, settings: ExportSettings, original: Bool = false) async throws -> AVPlayerItem {
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
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition(for: composition, clip: clip, info: info, settings: settings, original: original)
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
    /// applied shows the picture as recorded; the inspector says why.
    static func videoComposition(for asset: AVAsset, clip: VideoItem, info: MediaInfo,
                                 settings: ExportSettings, original: Bool) -> AVVideoComposition {
        let crop = (clip.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let shots = clip.zoomShots
        let regions = clip.blurRegions
        let effects = clip.blurEffects
        let color = ColorPipeline.stage(clip.color, info: info, fileName: clip.name,
                                        toneMapHDR: settings.toneMapHDR, original: original).render
        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let result = renderFrame(request.sourceImage, info: info, crop: crop,
                                     regions: regions, shots: shots, settings: settings,
                                     time: request.compositionTime.seconds, color: color, effects: effects)
            request.finish(with: result, context: nil)
        }
        videoComposition.renderSize = crop.size
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
                 effects: [VideoBlurEffect] = []) -> CIImage {
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
    return image
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

struct PlaybackCanvas: View {
    @ObservedObject var playback: PlaybackController
    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: playback.player)
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
