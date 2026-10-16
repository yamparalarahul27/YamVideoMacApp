import CoreGraphics
import Foundation

// The export of a recording with a screen (docs/plans/screen-speaker.md, section 6): the
// screen recording is one more input, and the layout stage puts it with the speaker,
// frame by frame as `ScreenTrack.state` places them, as `composeLayout` does in the preview.

/// What a screen adds to an export's filter graph.
struct ScreenLayer {
    /// Graph parts that read the screen recording's input and write `[scrh]`: the screen on
    /// the speaker's source frame grid, Rec.709, cut and scaled to `size`.
    var head: [String]
    /// Reads `[lyin]` (the speaker after its effects) and `[scrv]` (the screen on the edited
    /// timeline), writes `[lyout]`.
    var stage: FFmpeg.EffectStage
    /// The screen's size in its stream: its place in the Screen layout, its largest, or more
    /// when it has zooms, so a zoom shows the recording's own detail (up to all of it).
    var size: CGSize
    /// The speaker's source frame, which the screen rides under through the cuts.
    var sourceSize: CGSize
    /// Where to start reading the screen recording, in its seconds: a little before the
    /// first moment the export shows, so a long offset is not decoded for nothing.
    var seek: Double

    /// The screen recording as an ffmpeg input. The seek stops at the key frame before
    /// `seek` and keeps it, so the frame current at that moment is there.
    func input(_ url: URL) -> [String] {
        seek > 0 ? ["-noaccurate_seek", "-ss", String(format: "%.3f", seek), "-i", url.path] : ["-i", url.path]
    }
}

extension FFmpeg {
    /// Why a recording's screen cannot be exported as asked, if it cannot.
    static func screenProblem(_ screen: ScreenTrack?, info: MediaInfo, settings: ExportSettings) -> String? {
        guard let screen else { return nil }
        guard FileManager.default.fileExists(atPath: screen.url.path) else {
            return "The screen recording \(screen.name) is no longer there. Add it again in the inspector's Screen section."
        }
        if info.isHDR, !settings.toneMapHDR {
            return "Screen layouts work on standard colour. Turn on Convert HDR to SDR to export this \(info.hdrLabel ?? "HDR") recording with its screen."
        }
        return nil
    }

    /// The part of a screen recording inside a dark border (a window's shadow, or the
    /// desktop round a recorded window), as ffmpeg's cropdetect finds it on frames spread
    /// through the file. Every frame's box goes into one, so nothing shown is cut. Nil when
    /// there is no border.
    static func screenBorder(_ url: URL, info: MediaInfo) async throws -> CGRect? {
        guard let ffmpeg = ffmpegPath else { throw FFmpegError(message: "ffmpeg was not found.") }
        var box: CGRect?
        for index in 1...6 {
            let time = info.duration * Double(index) / 7
            let result = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-ss", String(format: "%.3f", time), "-i", url.path,
                                                      "-frames:v", "3", "-vf", "cropdetect=limit=24:round=2:reset=0", "-f", "null", "-"])
            guard let line = result.stderrText.components(separatedBy: "crop=").last, result.stderrText.contains("crop=") else { continue }
            let numbers = line.prefix { "0123456789:".contains($0) }.split(separator: ":").compactMap { Double($0) }
            guard numbers.count == 4, numbers[0] > 0, numbers[1] > 0 else { continue }
            let found = CGRect(x: numbers[2], y: numbers[3], width: numbers[0], height: numbers[1])
            box = box.map { $0.union(found) } ?? found
        }
        guard let box else { return nil }
        let even = box.evenClamped(in: info.fullFrame)
        return even.width * even.height > Double(info.width * info.height) * 0.99 ? nil : even
    }

    /// The screen for one export. `input` is the screen recording's input number; `rate` and
    /// `rateExpression` are the frame rate from the geometry on; `tags` describe the
    /// speaker's frames when they reach the layout stage.
    static func screenLayer(_ screen: ScreenTrack, info: MediaInfo, crop: CGRect, segments: [TimelineSegment]?,
                            rate: Double, rateExpression: String, input: Int, tags: FrameTags, endScreen: Double?) -> ScreenLayer {
        let geometry = LayoutGeometry(track: screen, crop: crop)
        let size = streamSize(screen, place: geometry.screenPlace(.screen)?.rect.size ?? crop.size)
        let duration = segments.map { ClipTimeline(segments: $0).duration } ?? info.duration
        let first = (segments?.map(\.start).min() ?? 0) + screen.offset - 2
        let seek = first > 2 ? max(0, (min(first, screen.info.duration - 3) * 1000).rounded(.down) / 1000) : 0
        return ScreenLayer(
            head: screenHead(screen, speaker: info, size: size, input: input, seek: seek),
            stage: layoutStage(screen, geometry: geometry, duration: duration, rate: rate, rateExpression: rateExpression,
                               sourceRate: info.fps, tags: tags, endScreen: endScreen, stream: size),
            size: size, sourceSize: CGSize(width: info.width, height: info.height), seek: seek)
    }

    /// The size of the screen's stream: its place in the Screen layout, grown by the deepest
    /// zoom, but never past the recording's own pixels.
    static func streamSize(_ screen: ScreenTrack, place: CGSize) -> CGSize {
        let picture = screen.picture.size
        let deepest = screen.zooms.map(\.level).max() ?? 1
        let grow = max(1, min(deepest, Double(picture.width / place.width), Double(picture.height / place.height)))
        guard grow > 1.0001 else { return place }
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded(.down) * 2) }
        return CGSize(width: even(Double(place.width) * grow), height: even(Double(place.height) * grow))
    }

    /// The screen recording on the speaker's source frame grid: its times (from the file's
    /// start, or from `seek` when the input seeks) moved by the offset, then one frame per
    /// speaker frame, each the screen frame current at that moment (`round=up`, as the
    /// preview shows the frame current at a time). Before the screen recording starts its
    /// first frame holds, after it ends its last. Then Rec.709 limited range, the screen's
    /// crop, and one Lanczos scale to `size`.
    static func screenHead(_ screen: ScreenTrack, speaker info: MediaInfo, size: CGSize, input: Int, seek: Double = 0) -> [String] {
        let moved = screen.offset - seek
        let shift = moved >= 0 ? String(format: "-%.6f/TB", moved) : String(format: "+%.6f/TB", -moved)
        let hold = max(0, info.duration - (screen.info.duration - screen.offset)) + 1
        var chain = "[\(input):v]setpts=PTS\(shift),fps=\(info.fpsExpression):start_time=0:round=up,"
            + "tpad=stop_mode=clone:stop_duration=\(num(hold))"
        let picture = screen.picture
        if picture != screen.info.fullFrame {
            chain += ",crop=\(Int(picture.width)):\(Int(picture.height)):\(Int(picture.minX)):\(Int(picture.minY))"
        }
        chain += ",scale=\(Int(size.width)):\(Int(size.height)):in_color_matrix=\(screen.info.yuvMatrix)"
            + ":in_range=\(screen.info.isFullRange ? "pc" : "tv"):out_color_matrix=bt709:out_range=tv"
            + ":flags=lanczos+accurate_rnd+full_chroma_int,format=yuv444p10le,setsar=1,\(FrameTags.rec709.filter)[scrh]"
        return [chain]
    }

    /// The layout stage: graph parts reading `[lyin]` and `[scrv]`, writing `[lyout]`. The
    /// video is cut into runs of frames with one layout state: a held layout is one chain,
    /// and each frame of a change has its own, as the end screen's move does. A run where
    /// the speaker fills the frame passes straight through. Otherwise: the fill made from
    /// the screen, the screen with rounded corners over it, then the speaker's window
    /// scaled into its place and masked (a circle or rounded corners).
    static func layoutStage(_ screen: ScreenTrack, geometry: LayoutGeometry, duration: Double, rate: Double, rateExpression: String,
                            sourceRate: Double, tags: FrameTags, endScreen: Double?, stream: CGSize? = nil, name: String = "ly") -> EffectStage {
        let w = Int(geometry.frame.width), h = Int(geometry.frame.height)
        let full = geometry.screenPlace(.screen)?.rect.size ?? geometry.frame
        let fps = max(1, rate)
        let total = max(1, Int((duration * fps).rounded()))
        var runs: [(first: Int, end: Int?, state: LayoutState)] = []
        for frame in 0..<total {
            let state = screen.state(at: Double(frame) / fps, geometry: geometry, endScreen: endScreen)
            if let last = runs.last, last.state == state { runs[runs.count - 1].end = frame + 1 }
            else { runs.append((frame, frame + 1, state)) }
        }
        // The last run reaches the last frame, whatever the exact count.
        runs[runs.count - 1].end = nil

        let convert = tags == .rec709 ? ""
            : "scale=in_color_matrix=\(tags.colorspace == "unknown" ? "bt709" : tags.colorspace):in_range=\(tags.fullRange ? "pc" : "tv")"
                + ":out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,"
        let shown = runs.indices.filter { runs[$0].state.screen != nil }
        // The speaker is converted once, here, and the runs work in 10-bit 4:4:4 until the
        // concat. A conversion in each run had a scaler of its own (ffmpeg inserts one).
        var parts = ["[lyin]setsar=1,\(convert)format=yuv444p10le,split=\(runs.count)" + runs.indices.map { "[\(name)s\($0)]" }.joined()]
        var screenChain = rate < sourceRate - 0.0001 ? "fps=\(rateExpression)," : ""
        // The zooms, on the edited timeline, from the stream's own detail down to the place
        // the Screen layout gives it: the sums of a recording's own zooms.
        let size = stream ?? full
        let picture = screen.picture
        let scale = Double(size.width / picture.width)
        let shots = screen.zooms.map { shot -> ZoomShot in
            var moved = shot
            moved.target = CGPoint(x: Double(shot.target.x - picture.minX) * scale, y: Double(shot.target.y - picture.minY) * scale)
            return moved
        }
        if let zoom = zoomFilter(shots: shots, frame: size, cropOrigin: .zero, fpsExpression: rateExpression, output: full) {
            // zoompan works in 8 bits; the fill and the masks after it work in 10.
            screenChain += zoom + ",format=yuv444p10le,\(FrameTags.rec709.filter),"
        } else if size != full {
            screenChain += "scale=\(Int(full.width)):\(Int(full.height)):flags=lanczos+accurate_rnd+full_chroma_int,"
        }
        if shown.isEmpty {
            parts.append("[scrv]nullsink")
        } else {
            parts.append("[scrv]\(screenChain)setsar=1,split=\(shown.count)" + shown.map { "[\(name)c\($0)]" }.joined())
        }
        let lanczos = "flags=lanczos+accurate_rnd+full_chroma_int"
        var firstSingle: Int?
        // Every scaler of a run is alive until ffmpeg ends, so each has one thread (see
        // FFmpeg.boundedScalerThreads): a video with many changes has thousands of them.
        let before = parts.count
        for (index, run) in runs.enumerated() {
            let trim = "trim=start_frame=\(run.first)" + (run.end.map { ":end_frame=\($0)" } ?? "") + ",setpts=PTS-STARTPTS"
            let frames = (run.end ?? (total + 2)) - run.first
            if run.end.map({ $0 - run.first == 1 }) == true { firstSingle = firstSingle ?? run.first }
            let output = "[\(name)o\(index)]"
            guard let place = run.state.screen else {
                parts.append("[\(name)s\(index)]\(trim)\(output)")
                continue
            }
            let p = "\(name)\(index)_"
            // The fill: the screen grown to cover the frame, centred, blurred and darkened.
            let cover = max(Double(w) / Double(full.width), Double(h) / Double(full.height))
            let coverWidth = max(w, Int((Double(full.width) * cover).rounded(.up))), coverHeight = max(h, Int((Double(full.height) * cover).rounded(.up)))
            parts.append("[\(name)c\(index)]\(trim),split=2[\(p)a][\(p)b]")
            parts.append("[\(p)b]scale=\(coverWidth):\(coverHeight):flags=bilinear,crop=\(w):\(h),"
                         + fillChain(width: w, height: h, gain: GraphicsMotion.fillDim, tags: .rec709) + "[\(p)f]")
            var screenChain = "[\(p)a]"
            if place.rect.size != full { screenChain += "scale=\(Int(place.rect.width)):\(Int(place.rect.height)):\(lanczos)," }
            screenChain += "format=yuv444p10le,setsar=1"
            parts += masked(screenChain, place: place, frames: frames, rate: fps, rateExpression: rateExpression, output: "[\(p)p]", name: "\(p)m")
            parts.append("[\(p)f][\(p)p]overlay=x=\(Int(place.rect.minX)):y=\(Int(place.rect.minY)):format=yuv444p10:eof_action=pass[\(p)g]")
            let window = run.state.window, speaker = run.state.speaker
            var speakerChain = "[\(name)s\(index)]\(trim)"
            if window != CGRect(origin: .zero, size: geometry.frame) {
                speakerChain += ",crop=\(Int(window.width)):\(Int(window.height)):\(Int(window.minX)):\(Int(window.minY))"
            }
            if window.size != speaker.rect.size {
                speakerChain += ",scale=\(Int(speaker.rect.width)):\(Int(speaker.rect.height)):\(lanczos)"
            }
            speakerChain += ",setsar=1"
            parts += masked(speakerChain, place: speaker, frames: frames, rate: fps, rateExpression: rateExpression, output: "[\(p)q]", name: "\(p)k")
            parts.append("[\(p)g][\(p)q]overlay=x=\(Int(speaker.rect.minX)):y=\(Int(speaker.rect.minY)):format=yuv444p10:shortest=1\(output)")
        }
        for index in before..<parts.count { parts[index] = FFmpeg.oneThreadScalers(parts[index]) }
        // concat times a run by its frames' mean spacing, so a one-frame run adds no time at
        // all; from the first one on, each frame is timed by its number on the frame grid.
        let retime = firstSingle.map { ",setpts='if(lt(N,\($0)),PTS,N/(\(rateExpression))/TB)'" } ?? ""
        parts.append(runs.indices.map { "[\(name)o\($0)]" }.joined() + "concat=n=\(runs.count):v=1:a=0\(retime),format=yuv420p10le[lyout]")
        return EffectStage(parts: parts)
    }

    /// `chain` with its corners rounded to `place`'s radius: a still mask in the alpha
    /// plane, repeated for every frame. Each pixel's cover of the shape, as Core Image's
    /// rounded rectangle draws it. No mask below half a pixel of radius.
    private static func masked(_ chain: String, place: LayoutPlace, frames: Int, rate: Double, rateExpression: String,
                               output: String, name: String) -> [String] {
        guard place.radius >= 0.5 else { return [chain + output] }
        let w = Double(place.rect.width), h = Double(place.rect.height), r = place.radius
        let distance = "hypot(max(abs(X+0.5-\(num(w / 2)))-\(num(w / 2 - r)),0),max(abs(Y+0.5-\(num(h / 2)))-\(num(h / 2 - r)),0))"
        let alpha = "mergeplanes=map0s=0:map0p=0:map1s=0:map1p=1:map2s=0:map2p=2:map3s=1:map3p=0:format=yuva444p10le"
        return [
            chain + "[\(name)p]",
            "color=c=black:s=\(Int(w))x\(Int(h)):r=\(rateExpression):d=\(num(0.5 / rate)),format=yuv444p10le,"
                + "geq=lum='1023*clip(\(num(r + 0.5))-\(distance),0,1)':cb=512:cr=512,\(FrameTags.rec709.filter),loop=loop=\(frames):size=1[\(name)m]",
            "[\(name)p][\(name)m]\(alpha)\(output)",
        ]
    }
}
