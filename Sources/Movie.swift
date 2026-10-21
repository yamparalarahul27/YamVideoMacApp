import Foundation

enum MovieCanvas: String, Codable, CaseIterable, Identifiable {
    case firstClip, widescreen, portrait, square
    var id: String { rawValue }
    var label: String {
        switch self {
        case .firstClip: return "Match first clip"
        case .widescreen: return "16:9 · Landscape"
        case .portrait: return "9:16 · Portrait"
        case .square: return "1:1 · Square"
        }
    }
}

struct MovieSettings: Codable, Equatable {
    var canvas: MovieCanvas = .firstClip
}

struct MoviePlan {
    let clips: [VideoItem]
    let size: CGSize
    let fps: Double
    let fpsExpression: String
    var duration: Double { clips.reduce(0) { $0 + $1.editedDuration } }

    init(items: [VideoItem], movieSettings: MovieSettings, settings: ExportSettings) throws {
        clips = items.filter(\.includedInMovie)
        guard !clips.isEmpty else { throw FFmpegError(message: "Include at least one recording in the movie.") }
        guard clips.allSatisfy({ $0.info != nil && $0.editedDuration > 0 && FileManager.default.fileExists(atPath: $0.url.path) }) else {
            throw FFmpegError(message: "A movie source is missing or still loading. Locate it before previewing or exporting.")
        }
        let first = clips[0]
        let info = first.info!
        let base: CGSize
        switch movieSettings.canvas {
        case .firstClip: base = (first.crop ?? info.fullFrame).evenClamped(in: info.fullFrame).size
        case .widescreen: base = CGSize(width: 1920, height: 1080)
        case .portrait: base = CGSize(width: 1080, height: 1920)
        case .square: base = CGSize(width: 1080, height: 1080)
        }
        size = FFmpeg.scaledSize(for: base, limit: settings.sizeLimit) ?? base
        fps = info.fps
        fpsExpression = info.fpsExpression
    }

    func offset(of id: UUID) -> Double {
        var offset = 0.0
        for clip in clips {
            if clip.id == id { return offset }
            offset += clip.editedDuration
        }
        return offset
    }
}

extension FFmpeg {
    /// Each recording gets its own filters, then is fitted onto one canvas. Sources are
    /// repeated as inputs only when needed by their edit graph; audio is normalized and
    /// silence fills recordings without sound. One graph avoids lossy intermediate files.
    static func movieArguments(plan: MoviePlan, settings: ExportSettings, output: URL, palette: URL? = nil,
                               palettePass: Bool = false) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-y"]
        for clip in plan.clips { arguments += ["-i", clip.url.path] }
        if let palette { arguments += ["-i", palette.path] }
        let withAudio = settings.audio != .none && settings.format == .mp4 && !palettePass
        // Each recording's music comes after the palette, and mixes under its own voice.
        var music: [Int: (mix: MusicMix, input: Int)] = [:]
        if withAudio {
            for (i, clip) in plan.clips.enumerated() {
                guard let mix = clip.exportMusic(settings) else { continue }
                music[i] = (mix, arguments.filter { $0 == "-i" }.count)
                arguments += musicInputs(mix)
            }
        }
        var graphs: [String] = []
        for (i, clip) in plan.clips.enumerated() {
            let info = clip.info!
            let crop = (clip.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
            var filters: [String] = []
            if crop != info.fullFrame {
                filters.append("crop=\(Int(crop.width)):\(Int(crop.height)):\(Int(crop.minX)):\(Int(crop.minY))")
            }
            // Normalize before zoompan: it emits one frame per input, so changing its
            // output rate alone changes speed. A downstream fps filter can also pad
            // zoompan's EOF timestamp excessively on some FFmpeg versions.
            filters.append("fps=\(plan.fpsExpression)")
            if let zoom = zoomFilter(shots: clip.zoomShots, frame: crop.size, cropOrigin: crop.origin, fpsExpression: plan.fpsExpression) { filters.append(zoom) }
            // Whole-frame effects blur the recording before it is fitted, so the bars stay
            // solid; each recording's are timed from its own start.
            let head = videoHead(info: info, settings: settings, color: clip.colorFilters(settings))
            let effects = effectStage(clip.blurEffects, info: info, crop: crop, converted: !head.isEmpty,
                                      fps: plan.fps, name: "fx\(i)_")
            var delivery: [String] = []
            delivery += ["scale=\(Int(plan.size.width)):\(Int(plan.size.height)):force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos",
                        "pad=\(Int(plan.size.width)):\(Int(plan.size.height)):(ow-iw)/2:(oh-ih)/2:color=black",
                        "setsar=1", "setpts=PTS-STARTPTS"]
            // Each recording is normalised on its own — tone mapping, then its own colour
            // stage — before anything mixes it with the others.
            let graph = editedFilterGraph(head: head,
                                          segments: clip.segments, audio: withAudio && info.hasAudio,
                                          regions: clip.blurBoxes.map { $0.clamped(in: info.fullFrame) },
                                          style: settings.blurStyle, strength: settings.blurStrength, tail: filters,
                                          fpsExpression: info.fpsExpression, effects: effects, delivery: delivery)!
            // Namespace every internal pad so independent per-recording graphs coexist.
            let expression = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]")
            var spec = graph.isComplex ? graph.spec : "[0:v]\(graph.spec)[vout]"
            for match in expression.matches(in: spec, range: NSRange(spec.startIndex..., in: spec)).reversed() {
                let name = (spec as NSString).substring(with: match.range(at: 1))
                let replacement: String
                if name == "0:v" { replacement = "[\(i):v:0]" }
                else if name == "0:a:0" { replacement = "[\(i):a:0]" }
                else { replacement = "[c\(i)_\(name)]" }
                spec = (spec as NSString).replacingCharacters(in: match.range, with: replacement)
            }
            graphs.append(spec)
            let videoLabel = "c\(i)_" + (graph.outputLabel ?? "vout")
            graphs.append("[\(videoLabel)]null[mv\(i)]")
            if withAudio {
                let duration = String(format: "%.6f", clip.editedDuration)
                if info.hasAudio {
                    let audioLabel = clip.segments == nil ? "\(i):a:0" : "c\(i)_timelinea"
                    let voice = music[i] == nil ? "ma\(i)" : "mv\(i)voice"
                    graphs.append("[\(audioLabel)]aresample=48000:async=1:first_pts=0,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=duration=\(duration),asetpts=PTS-STARTPTS[\(voice)]")
                    if let (mix, input) = music[i] {
                        graphs += musicGraph(mix, firstInput: input, voice: voice, output: "ma\(i)", prefix: "m\(i)_")
                    }
                } else {
                    graphs.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(duration),asetpts=PTS-STARTPTS[ma\(i)]")
                }
            }
        }
        let inputs = plan.clips.indices.map { withAudio ? "[mv\($0)][ma\($0)]" : "[mv\($0)]" }.joined()
        graphs.append(inputs + "concat=n=\(plan.clips.count):v=1:a=\(withAudio ? 1 : 0)[movie]" + (withAudio ? "[sound]" : ""))
        var tail: [String] = []
        if settings.format.isAnimation, let rate = settings.frameRate.value, rate < plan.fps { tail.append("fps=\(Int(rate))") }
        if palettePass {
            tail.append("palettegen=max_colors=\(settings.gifColors.rawValue):stats_mode=diff")
        }
        let finalLabel: String
        if !tail.isEmpty { graphs.append("[movie]" + tail.joined(separator: ",") + "[final]"); finalLabel = "final" }
        else { finalLabel = "movie" }
        if palette != nil {
            graphs.append("[\(finalLabel)][\(plan.clips.count):v]paletteuse=dither=\(settings.gifDither.filterValue):diff_mode=rectangle[gif]")
        }
        arguments += ["-filter_complex", graphs.joined(separator: ";"), "-map", "[\(palette == nil ? finalLabel : "gif")]"]
        if withAudio { arguments += ["-map", "[sound]"] }
        if palettePass {
            arguments += ["-an", "-frames:v", "1"]
        } else {
            // Reuse the existing format-specific output options without rebuilding them.
            let first = plan.clips[0]
            var normalized = settings
            if normalized.audio == .copy { normalized.audio = .aac }
            // Tagged Rec.709 whenever any recording was converted to it; an untouched
            // recording is assumed to be Rec.709 already.
            let converted = plan.clips.contains {
                !videoHead(info: $0.info!, settings: settings, color: $0.colorFilters(settings)).isEmpty || $0.blurEffects.contains(where: \.isVisible)
            }
            let template = exportArguments(input: first.url, output: output, info: first.info!,
                                            crop: first.info!.fullFrame, settings: normalized, tagRec709: converted)
            let firstCodec = template.firstIndex(of: "-c:v") ?? template.firstIndex(of: "-an")!
            var options = Array(template[firstCodec..<template.count - 1])
            if let metadata = options.firstIndex(of: "-map_metadata") { options.removeSubrange(metadata..<metadata + 2) }
            // Template audio reflects only the first source. The assembled movie always
            // has the normalized audio track whenever audio was requested.
            if withAudio {
                if let an = options.firstIndex(of: "-an") { options.remove(at: an) }
                if !options.contains("-c:a") { options += ["-c:a", "aac", "-b:a", "192k"] }
            }
            // [sound] leaves the complex graph, and ffmpeg refuses -af on such a stream,
            // so the template's loudness filter moves into the graph.
            if let af = options.firstIndex(of: "-af") {
                let filter = options[af + 1]
                options.removeSubrange(af...af + 1)
                if withAudio, let graph = arguments.firstIndex(of: "-filter_complex"),
                   let map = arguments.lastIndex(of: "[sound]") {
                    arguments[graph + 1] += ";[sound]\(filter)[normalsound]"
                    arguments[map] = "[normalsound]"
                }
            }
            arguments += options
        }
        if palettePass { arguments += ["-progress", "pipe:1", "-nostats"] }
        arguments.append(output.path)
        return arguments
    }

    static func exportMovie(plan: MoviePlan, settings: ExportSettings, output: URL,
                            onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let executable = ffmpegPath else { throw FFmpegError(message: "ffmpeg was not found.") }
        for clip in plan.clips {
            if let problem = clip.colorStage(settings).problem { throw FFmpegError(message: "\(clip.name): \(problem)") }
            if let info = clip.info, let problem = effectProblem(clip.blurEffects, info: info, settings: settings) {
                throw FFmpegError(message: "\(clip.name): \(problem)")
            }
        }
        if settings.format == .webp, await !supportsWebP() { throw FFmpegError(message: "This ffmpeg build cannot export WebP.") }
        for clip in plan.clips { await MusicSpeech.prepare(clip) }
        let palette = settings.format == .gif ? paletteURL(for: output) : nil
        defer { if let palette { try? FileManager.default.removeItem(at: palette) } }
        if let palette {
            try await runPass(executable, movieArguments(plan: plan, settings: settings, output: palette, palettePass: true),
                              writing: palette, duration: plan.duration, from: 0, to: 0.3, onProgress: onProgress)
        }
        // A long graph (many changes of layout, or the music's duck) goes to a file.
        try await runPass(executable, try spilledGraph(movieArguments(plan: plan, settings: settings, output: output, palette: palette)),
                          writing: output, duration: plan.duration, from: palette == nil ? 0 : 0.3, to: 1, onProgress: onProgress)
        onProgress(1)
    }
}
