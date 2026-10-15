import CoreGraphics
import Foundation

// Export with graphics (graphics track G1 part 2, docs/plans/graphics-track.md):
// the move aside drawn by ffmpeg, each graphic rendered on its own by HyperFrames to a
// cached PNG sequence, and those sequences overlaid on the delivered picture.

// MARK: - The move aside in an export

extension FFmpeg {
    /// The move aside in an export: graph parts reading `[mvin]` and writing `[mvout]`, the
    /// picture `moveAside` draws in the preview. Only the frames around each panel are
    /// worked on: the video is cut into windows by frame, the panel windows go through the
    /// move and the rest pass straight through, and concat joins them again in order.
    ///
    /// In a window the frames are 10-bit 4:4:4 samples, where a blur, a blend and the
    /// fill's darker, less saturated matrix are the same sums Core Image does on the
    /// encoded values. The fill (blurred hard) is made at quarter size and the frost at
    /// half size, which looks the same and costs a fraction. What changes from frame to
    /// frame (how far the picture has moved, how wide its edge fades, how strong the fill
    /// and the frost are) comes from `GraphicsMotion`, the function the preview uses,
    /// through `sendcmd`, as the blur effects do. The two ramps are still images repeated
    /// for every frame; mergeplanes reads one frame of them ahead, so their gains go out a
    /// frame early (measured, and checked by `./test.sh`).
    static func moveStage(_ motion: GraphicsMotion, frame: CGSize, fps: Double, fpsExpression: String,
                          duration: Double, tags: FrameTags, name: String = "mv") throws -> EffectStage {
        let rate = max(1, fps)
        let total = Int((duration * rate).rounded())
        // The end screen's frames: from the one at its start to the last.
        let screenFirst = motion.screen.map { max(0, Int(($0.start * rate + 0.000001).rounded(.down))) }
        // Windows by frame: from a frame before each panel starts to two after it has
        // slid away, joined where they meet, and never into the end screen.
        var windows: [(first: Int, end: Int?, spans: [PanelSpan])] = []
        for span in motion.spans {
            let first = max(0, Int((span.start * rate).rounded(.down)) - 1)
            var end = Int(((span.end + GraphicsTrack.slide) * rate).rounded(.up)) + 2
            if let screenFirst { end = min(end, screenFirst) }
            guard end > first else { continue }
            if let last = windows.last, let lastEnd = last.end, first <= lastEnd {
                windows[windows.count - 1] = (last.first, max(lastEnd, end), last.spans + [span])
            } else {
                windows.append((first, end, [span]))
            }
        }
        // A window reaching the end runs to the last frame, whatever the exact count.
        if screenFirst == nil, let last = windows.last, let end = last.end, end >= total - 2 { windows[windows.count - 1].end = nil }

        enum Piece { case pass, panel(Int), screen(Double), split(Double) }
        var segments: [(first: Int, end: Int?, piece: Piece)] = []
        var cursor = 0
        /// The first frame that has a segment of its own, from which frames are retimed.
        var firstSingle: Int?
        for (index, window) in windows.enumerated() {
            if window.first > cursor { segments.append((cursor, window.first, .pass)) }
            if motion.short == .split {
                // The picture shrinks into the split frame: each frame of the move has its
                // own size and place; while it holds, the frames share one.
                let last = window.end ?? total
                var frame = window.first
                while frame < last {
                    let amount = motion.progress(at: Double(frame) / rate).amount
                    if amount < 0.0001 {
                        if case .pass? = segments.last?.piece, segments.last?.end == frame { segments[segments.count - 1].end = frame + 1 }
                        else { segments.append((frame, frame + 1, .pass)) }
                    } else if amount > 0.9999 {
                        if case .split(let held)? = segments.last?.piece, held > 0.9999, segments.last?.end == frame { segments[segments.count - 1].end = frame + 1 }
                        else { segments.append((frame, frame + 1, .split(1))) }
                    } else {
                        segments.append((frame, frame + 1, .split(amount)))
                        firstSingle = firstSingle ?? frame
                    }
                    frame += 1
                }
                if window.end == nil { segments[segments.count - 1].end = nil }
            } else {
                segments.append((window.first, window.end, .panel(index)))
            }
            cursor = window.end ?? Int.max
        }
        if let screenFirst {
            if screenFirst > cursor { segments.append((cursor, screenFirst, .pass)) }
            // While the picture moves, each frame has its own size and place; once it has
            // arrived, the rest of the video shares one.
            var index = max(cursor, screenFirst)
            while motion.screenProgress(at: Double(index) / rate) < 1 {
                let amount = motion.screenProgress(at: Double(index) / rate)
                segments.append((index, index + 1, amount > 0.0001 ? .screen(amount) : .pass))
                index += 1
            }
            segments.append((index, nil, .screen(1)))
            firstSingle = min(firstSingle ?? screenFirst, screenFirst)
        } else if cursor < Int.max {
            segments.append((cursor, nil, .pass))
        }

        // Square pixels throughout: a fill or frost scaled back from a quarter or half of a
        // width that does not divide (a Short's 406-wide window) would otherwise come back
        // with a sample aspect a hair off, which mergeplanes and concat refuse.
        var parts = ["[mvin]setsar=1,split=\(segments.count)" + segments.indices.map { "[\(name)s\($0)]" }.joined()]
        for (index, segment) in segments.enumerated() {
            let trim = "trim=start_frame=\(segment.first)" + (segment.end.map { ":end_frame=\($0)" } ?? "") + ",setpts=PTS-STARTPTS"
            let output = "[\(name)c\(index)]"
            switch segment.piece {
            case .pass:
                parts.append("[\(name)s\(index)]\(trim),format=yuv420p10le\(output)")
            case .panel(let window):
                let frames = (segment.end ?? (total + 2)) - segment.first
                parts += try moveWindow(motion, spans: windows[window].spans, first: segment.first, frames: frames,
                                        frame: frame, rate: rate, fpsExpression: fpsExpression, tags: tags,
                                        input: "[\(name)s\(index)]\(trim)", output: output, name: "\(name)w\(window)_")
            case .screen(let amount):
                parts += placedWindow(motion.screenPlacement(amount: amount, size: frame), gain: GraphicsMotion.fillDim * amount,
                                      frame: frame, tags: tags, input: "[\(name)s\(index)]\(trim)", output: output, name: "\(name)e\(index)_")
            case .split(let amount):
                parts += placedWindow(motion.splitPlacement(amount: amount, size: frame), gain: GraphicsMotion.fillDim * amount,
                                      frame: frame, tags: tags, input: "[\(name)s\(index)]\(trim)", output: output, name: "\(name)p\(index)_")
            }
        }
        // concat times a segment by its frames' mean spacing, so a one-frame segment adds no
        // time at all. From the first frame with a segment of its own on, each frame is
        // timed by its number on the frame grid this stage works on (the joined video
        // starts at 0).
        let retime = firstSingle.map { ",setpts='if(lt(N,\($0)),PTS,N/(\(fpsExpression))/TB)'" } ?? ""
        parts.append(segments.indices.map { "[\(name)c\($0)]" }.joined() + "concat=n=\(segments.count):v=1:a=0\(retime)[mvout]")
        return EffectStage(parts: parts)
    }

    /// A zoomed-out Short: graph parts reading `[mvin]` (the picture) and writing `[zoout]`
    /// (the stage), what `zoomOut` draws in the preview. The picture sits at the top of the
    /// taller stage; below, the fill of the move aside, made from the picture grown to
    /// cover the stage; the picture's bottom edge fades into it through a still ramp in the
    /// alpha plane, repeated for every frame.
    static func zoomStage(picture: CGSize, stage: CGSize, fps: Double, fpsExpression: String,
                          duration: Double, tags: FrameTags, name: String = "zo") -> EffectStage {
        let w = Int(stage.width), h = Int(stage.height), ph = Int(picture.height)
        let cover = Int((picture.width * stage.height / picture.height).rounded())
        let frames = Int((duration * max(1, fps)).rounded(.up)) + 2
        let fade = ShortFormat.zoomFade * GraphicsMotion.unit(stage)
        let alpha = "mergeplanes=map0s=0:map0p=0:map1s=0:map1p=1:map2s=0:map2p=2:map3s=1:map3p=0:format=yuva444p10le"
        return EffectStage(parts: [
            "[mvin]setsar=1,format=yuv444p10le,split=2[\(name)a][\(name)b]",
            "[\(name)b]scale=\(cover):\(h):flags=bilinear,crop=\(w):\(h),"
                + fillChain(width: w, height: h, gain: GraphicsMotion.fillDim, tags: tags) + "[\(name)f]",
            "color=c=black:s=\(w)x\(h):r=\(fpsExpression):d=\(num(0.5 / max(1, fps))),format=yuv444p10le,"
                + "geq=lum='1023*clip((\(ph)-Y-0.5)/\(num(fade)),0,1)':cb=512:cr=512,\(tags.filter),loop=loop=\(frames):size=1[\(name)g]",
            "[\(name)a]pad=\(w):\(h):0:0:color=black,setsar=1[\(name)p]",
            "[\(name)p][\(name)g]\(alpha)[\(name)m]",
            "[\(name)f][\(name)m]overlay=x=0:y=0:format=yuv444p10:eof_action=pass,format=yuv420p10le[zoout]",
        ])
    }

    /// Frames with the picture at one place: the fill, as in the move aside, with the
    /// picture scaled (Lanczos, as the preview) and laid over it. The end screen's frame
    /// and a Short's split frame both move this way.
    private static func placedWindow(_ place: (x: Int, y: Int, width: Int, height: Int), gain: Double, frame: CGSize,
                                     tags: FrameTags, input: String, output: String, name: String) -> [String] {
        let w = Int(frame.width), h = Int(frame.height)
        return [
            "\(input),format=yuv444p10le,split=2[\(name)a][\(name)b]",
            "[\(name)b]" + fillChain(width: w, height: h, gain: gain, tags: tags) + "[\(name)f]",
            "[\(name)a]scale=\(place.width):\(place.height):flags=lanczos+accurate_rnd+full_chroma_int,setsar=1[\(name)p]",
            "[\(name)f][\(name)p]overlay=x=\(place.x):y=\(place.y):format=yuv444p10:eof_action=pass,format=yuv420p10le\(output)",
        ]
    }

    /// The fill behind a moved picture, on 10-bit 4:4:4 frames: the frame grown by
    /// `fillScale` and cut back to the frame, at quarter size, blurred, darkened and
    /// desaturated by `gain`, then brought back up.
    static func fillChain(width w: Int, height h: Int, gain: Double, tags: FrameTags) -> String {
        let unit = GraphicsMotion.unit(CGSize(width: w, height: h))
        let black = tags.fullRange ? 0 : 64
        let quarter = (w: Int((Double(w) / 4).rounded()), h: Int((Double(h) / 4).rounded()))
        let grown = (w: Int((Double(w) * GraphicsMotion.fillScale / 4).rounded()), h: Int((Double(h) * GraphicsMotion.fillScale / 4).rounded()))
        let chroma = String(format: "(val-512)*%.6f+512", gain * GraphicsMotion.fillSaturation)
        return "scale=\(grown.w):\(grown.h):flags=bilinear,"
            + "gblur=sigma=\(num(GraphicsMotion.fillBlur * unit / 4)):steps=3,crop=\(quarter.w):\(quarter.h),"
            + String(format: "lutyuv=y='(val-%d)*%.6f+%d'", black, gain, black) + ":u='\(chroma)':v='\(chroma)',scale=\(w):\(h):flags=bilinear,setsar=1"
    }

    /// One panel window of the move, its frames timed from 0. On the 16:9 video the picture
    /// slides left; under a Short's bottom sheet it lifts; under a full shade it stays put
    /// and only the frost comes in.
    private static func moveWindow(_ motion: GraphicsMotion, spans: [PanelSpan], first: Int, frames: Int,
                                   frame: CGSize, rate: Double, fpsExpression: String, tags: FrameTags,
                                   input: String, output: String, name: String) throws -> [String] {
        let w = Int(frame.width), h = Int(frame.height), unit = GraphicsMotion.unit(frame)
        let vertical = motion.short != nil
        let moves = motion.short != .shade
        let along = vertical ? Double(h) : Double(w)
        let black = tags.fullRange ? 0 : 64
        let offset = Double(first) / rate
        func gate(_ spans: [PanelSpan]) -> String {
            "enable='" + spans.map {
                "between(t,\(num($0.start - offset - 1 / rate)),\(num($0.end + GraphicsTrack.slide - offset + 1 / rate)))"
            }.joined(separator: "+") + "'"
        }
        /// A still ramp in the luma plane, repeated for every frame, through a gain the
        /// commands set.
        func ramp(_ expression: String, gain target: String, initial: String) -> String {
            "color=c=black:s=\(w)x\(h):r=\(fpsExpression):d=\(num(0.5 / rate)),format=yuv444p10le,"
                + "geq=lum='\(expression)':cb=512:cr=512,\(tags.filter),loop=loop=\(frames + 2):size=1,lutyuv@\(target)=y='val*\(initial)'"
        }
        let alpha = "mergeplanes=map0s=0:map0p=0:map1s=0:map1p=1:map2s=0:map2p=2:map3s=1:map3p=0:format=yuva444p10le"
        let axis = vertical ? "y" : "x"

        // Panels of one look share a frost: the same ramp, the same blur.
        var frosts: [(ramp: (from: Double, to: Double, blur: Double), spans: [PanelSpan])] = []
        for span in spans {
            guard let ramp = motion.frostRamp(for: span) else { continue }
            if let index = frosts.firstIndex(where: { $0.ramp == ramp }) { frosts[index].spans.append(span) }
            else { frosts.append((ramp, [span])) }
        }

        // The commands, frame by frame, wherever a value changes.
        var lines: [String] = []
        var shown: [String: String] = [:]
        func send(_ time: Double, _ target: String, _ option: String, _ value: String) {
            guard shown["\(target) \(option)"] != value else { return }
            shown["\(target) \(option)"] = value
            lines.append(String(format: "%.6f %@ %@ %@;", max(0, time), target, option, value))
        }
        let darkFill = (y: "(val-\(black))*0.000000+\(black)", c: "(val-512)*0.000000+512")
        shown["lutyuv@\(name)f y"] = darkFill.y
        shown["lutyuv@\(name)f u"] = darkFill.c
        shown["lutyuv@\(name)f v"] = darkFill.c
        shown["overlay@\(name)x \(axis)"] = "0"
        shown["lutyuv@\(name)a y"] = "val*1000000"
        for index in frosts.indices { shown["lutyuv@\(name)r\(index) y"] = "val*0" }
        let saturation = GraphicsMotion.fillSaturation
        for index in 0..<frames {
            let (amount, span) = motion.progress(at: Double(first + index) / rate)
            let now = (Double(index) - 0.5) / rate, early = (Double(index) - 1.5) / rate
            if moves {
                let shift = vertical ? motion.lift(amount: amount, size: frame) : Int((Double(w) * GraphicsTrack.shiftFraction * amount).rounded())
                send(now, "overlay@\(name)x", axis, String(-shift))
                let gain = GraphicsMotion.fillDim * amount
                send(now, "lutyuv@\(name)f", "y", String(format: "(val-%d)*%.6f+%d", black, gain, black))
                send(now, "lutyuv@\(name)f", "u", String(format: "(val-512)*%.6f+512", gain * saturation))
                send(now, "lutyuv@\(name)f", "v", String(format: "(val-512)*%.6f+512", gain * saturation))
                // The edge fade is `edgeFade × amount` wide: the full-width ramp over amount.
                send(early, "lutyuv@\(name)a", "y", amount > 0.000001 ? String(format: "val*%.6f", 1 / amount) : "val*1000000")
            }
            for (frost, entry) in frosts.enumerated() {
                let strength = span.flatMap(motion.frostRamp(for:)).map { $0 == entry.ramp } == true ? amount : 0
                send(early, "lutyuv@\(name)r\(frost)", "y", String(format: "val*%.6f", strength))
            }
        }
        let script = Data((lines.joined(separator: "\n") + "\n").utf8)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YamVideo-move", isDirectory: true)
        let file = folder.appendingPathComponent("\(ColorCube.sha256(script)).cmd")
        if (try? Data(contentsOf: file)) != script {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: file, options: .atomic)
        }

        let half = (w: Int((Double(w) / 2).rounded()), h: Int((Double(h) / 2).rounded()))
        var parts: [String]
        if moves {
            // The fill: the frame grown by `fillScale` and cut back to the frame, at quarter
            // size, blurred, darkened, then brought back up. The moved picture's far edge
            // (right, or bottom in a Short) fades into it.
            let quarter = (w: Int((Double(w) / 4).rounded()), h: Int((Double(h) / 4).rounded()))
            let grown = (w: Int((Double(w) * GraphicsMotion.fillScale / 4).rounded()), h: Int((Double(h) * GraphicsMotion.fillScale / 4).rounded()))
            let edge = vertical ? "(H-Y-0.5)" : "(W-X-0.5)"
            parts = [
                "\(input),format=yuv444p10le,sendcmd=f='\(file.path)',split=2[\(name)a][\(name)b]",
                "[\(name)b]scale=\(grown.w):\(grown.h):flags=bilinear,"
                    + "gblur=sigma=\(num(GraphicsMotion.fillBlur * unit / 4)):steps=3,crop=\(quarter.w):\(quarter.h),"
                    + "lutyuv@\(name)f=y='\(darkFill.y)':u='\(darkFill.c)':v='\(darkFill.c)',scale=\(w):\(h):flags=bilinear,setsar=1[\(name)f]",
                ramp("1023*clip(\(edge)/\(num(GraphicsMotion.edgeFade * unit)),0,1)", gain: "\(name)a", initial: "1000000") + "[\(name)g]",
                "[\(name)a][\(name)g]\(alpha)[\(name)m]",
                "[\(name)f][\(name)m]overlay@\(name)x=x=0:y=0:format=yuv444p10:eof_action=pass[\(name)0]",
            ]
        } else {
            parts = ["\(input),format=yuv444p10le,sendcmd=f='\(file.path)'[\(name)0]"]
        }
        let position = vertical ? "Y" : "X"
        for (index, frost) in frosts.enumerated() {
            let from = frost.ramp.from * along, width = max(0.5, (frost.ramp.to - frost.ramp.from) * along)
            parts += [
                "[\(name)\(index)]split=2[\(name)\(index)p][\(name)\(index)q]",
                "[\(name)\(index)q]scale=\(half.w):\(half.h):flags=bilinear,"
                    + "gblur=sigma=\(num(frost.ramp.blur * unit / 2)):steps=3:\(gate(frost.spans)),scale=\(w):\(h):flags=bilinear,setsar=1[\(name)z\(index)]",
                ramp("1023*clip((\(position)+0.5-\(num(from)))/\(num(width)),0,1)", gain: "\(name)r\(index)", initial: "0") + "[\(name)h\(index)]",
                "[\(name)z\(index)][\(name)h\(index)]\(alpha)[\(name)k\(index)]",
                "[\(name)\(index)p][\(name)k\(index)]overlay=x=0:y=0:format=yuv444p10:eof_action=pass:\(gate(frost.spans))[\(name)\(index + 1)]",
            ]
        }
        parts.append("[\(name)\(frosts.count)]format=yuv420p10le\(output)")
        return parts
    }
}

/// The colour tags frames carry after the head: Rec.709 limited range once anything
/// converted them, otherwise the source's own. ffmpeg makes the inputs of a blend agree on
/// these and converts one to match the other, so graphics and the move's ramps take the
/// picture's tags: the picture itself is never converted on their account.
struct FrameTags: Equatable {
    var colorspace: String
    var range: String
    var fullRange: Bool { range == "pc" }
    /// Labels a stream with these tags without touching its samples.
    var filter: String { "setparams=colorspace=\(colorspace):range=\(range)" }

    static let rec709 = FrameTags(colorspace: "bt709", range: "tv")
    private static let named: Set<String> = ["gbr", "bt709", "fcc", "bt470bg", "smpte170m", "smpte240m", "ycgco",
                                             "bt2020nc", "bt2020c", "smpte2085", "ictcp"]

    init(colorspace: String, range: String) { self.colorspace = colorspace; self.range = range }

    init(info: MediaInfo, converted: Bool) {
        guard !converted else { self = .rec709; return }
        colorspace = info.colorSpace.flatMap { Self.named.contains($0) ? $0 : nil } ?? "unknown"
        range = info.colorRange == "pc" ? "pc" : info.colorRange == "tv" ? "tv" : "unknown"
    }
}

// MARK: - Render units

/// One graphic, or one panel span, rendered on its own for an export: what the engine's
/// `unit` mode draws.
struct GraphicsUnit: Equatable {
    /// The engine's unit ID within `track`.
    var id: String
    var name: String
    /// Only what this unit needs, timed from `origin`.
    var track: GraphicsTrack
    /// The edited time of the unit's first frame. It sits on the export's frame grid, so
    /// every beat lands on the frame it lands on in the preview.
    var origin: Double
    var duration: Double
}

extension GraphicsTrack {
    /// Panel graphics in the groups that share one panel, by the rule `panelSpans` uses.
    func panelGroups() -> [[Graphic]] {
        var groups: [[Graphic]] = []
        var end = -Double.infinity
        for graphic in items.sorted(by: { $0.start < $1.start }) where graphic.kind.zone == .panel {
            if !groups.isEmpty, graphic.start - end < Self.panelMergeGap {
                groups[groups.count - 1].append(graphic)
                end = max(end, graphic.end)
            } else {
                groups.append([graphic]); end = graphic.end
            }
        }
        return groups
    }

    /// What an export renders at `fps`: one unit per graphic and one per panel span, as
    /// `plan()` in graphics.js lists them. Each carries only the data it draws, so changing
    /// one graphic renders one unit again. A panel graphic keeps the other graphics of its
    /// panel, without their text, because whether it opens the panel changes its timing.
    func renderUnits(fps: Double) -> [GraphicsUnit] {
        let rate = max(1, fps)
        func onGrid(_ time: Double) -> Double { (time * rate + 0.000001).rounded(.down) / rate }
        func trimmed(_ graphics: [Graphic], keeping id: UUID?, origin: Double) -> GraphicsTrack {
            GraphicsTrack(style: style, items: graphics.map { graphic in
                // Rounded to microseconds, so the same graphic one whole frame later has
                // the same data and reuses its frames.
                var copy = graphic
                copy.start = ((graphic.start - origin) * 1_000_000).rounded() / 1_000_000
                copy.end = ((graphic.end - origin) * 1_000_000).rounded() / 1_000_000
                if copy.id != id { copy.props = [:] }
                return copy
            }, canvas: canvas)
        }
        let groups = panelGroups()
        var units: [GraphicsUnit] = []
        for graphic in items.sorted(by: { $0.start < $1.start }) {
            let origin = onGrid(graphic.start)
            let mates = graphic.kind.zone == .panel ? (groups.first { $0.contains { $0.id == graphic.id } } ?? [graphic]) : [graphic]
            let track = trimmed(mates, keeping: graphic.id, origin: origin)
            units.append(GraphicsUnit(id: graphic.id.uuidString, name: graphic.kind.label, track: track,
                                      origin: origin, duration: track.items.first { $0.id == graphic.id }?.end ?? graphic.end - origin))
        }
        for group in groups {
            let origin = onGrid(group[0].start)
            let track = trimmed(group, keeping: nil, origin: origin)
            units.append(GraphicsUnit(id: "panel-0", name: "Panel", track: track,
                                      origin: origin, duration: (track.items.map(\.end).max() ?? 0) + Self.slide))
        }
        // Overlaid in this order: a panel's shade goes under the graphics that start with it,
        // as the preview draws it.
        return units.sorted { ($0.origin, $0.id.hasPrefix("panel-") ? 0 : 1, $0.id) < ($1.origin, $1.id.hasPrefix("panel-") ? 0 : 1, $1.id) }
    }
}

// MARK: - HyperFrames

/// HyperFrames (HeyGen, Apache-2.0) draws each unit's page to PNG frames with alpha, in a
/// headless Chrome it downloads. Neither is bundled. The owner downloads both once, from
/// the Export sheet, into the app's own folder; nothing is fetched without that consent.
/// It runs with telemetry, update checks and self-install off.
enum HyperFrames {
    static let version = "0.8.159"
    static let downloadSize = "about 220 MB"
    static let minimumNode = 22

    enum Status: Equatable, Sendable {
        case ready
        /// Why Node.js cannot run it.
        case needsNode(String)
        case needsDownload
    }

    static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_HYPERFRAMES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/HyperFrames/\(version)", isDirectory: true)
    }
    static var script: URL { folder.appendingPathComponent("node_modules/hyperframes/bin/hyperframes.mjs") }
    /// Written once the package and its browser are both in place.
    static var readyMarker: URL { folder.appendingPathComponent(".yamvideo-ready") }

    static let missingMessage = "Graphics need HyperFrames to export. Download it in the Export sheet's Graphics "
        + "section (\(downloadSize), once), or turn off Draw graphics to export without them."

    /// A GUI app does not inherit the shell's PATH, so the usual places are probed: the
    /// nodejs.org installer, Homebrew, MacPorts, Volta and nvm (newest first).
    private static var nodeCandidates: [String] {
        var candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/opt/local/bin/node"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/.volta/bin/node")
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/node" }
        }
        return candidates
    }

    /// The first Node.js new enough for HyperFrames, or why there is none.
    static func findNode() async -> Result<String, FFmpegError> {
        var older: [String] = []
        for path in nodeCandidates where FileManager.default.isExecutableFile(atPath: path) {
            guard let result = try? await Shell.run(path, ["--version"]), result.status == 0 else { continue }
            let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let major = Int(text.dropFirst().split(separator: ".").first ?? ""), major >= minimumNode { return .success(path) }
            older.append(text)
        }
        return .failure(FFmpegError(message: older.isEmpty
            ? "Exporting graphics needs Node.js \(minimumNode) or later. Install it from nodejs.org, then try again."
            : "Exporting graphics needs Node.js \(minimumNode) or later; this Mac has \(older[0]). Update it from nodejs.org, then try again."))
    }

    static func status() async -> Status {
        if case .failure(let error) = await findNode() { return .needsNode(error.message) }
        let manager = FileManager.default
        return manager.fileExists(atPath: readyMarker.path) && manager.fileExists(atPath: script.path) ? .ready : .needsDownload
    }

    /// Node first on PATH, then ffmpeg's folder; no telemetry, update checks or self-install.
    static func environment(node: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var path = [(node as NSString).deletingLastPathComponent]
        if let ffmpeg = FFmpeg.ffmpegPath { path.append((ffmpeg as NSString).deletingLastPathComponent) }
        environment["PATH"] = (path + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        environment["HYPERFRAMES_NO_TELEMETRY"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        environment["HYPERFRAMES_NO_UPDATE_CHECK"] = "1"
        environment["HYPERFRAMES_NO_AUTO_INSTALL"] = "1"
        return environment
    }

    /// Downloads HyperFrames with npm, then its browser. Only ever called on the owner's
    /// click. A failed download leaves the previous state as it was.
    static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        let node = try await findNode().get()
        let npm = URL(fileURLWithPath: (node as NSString).deletingLastPathComponent)
            .appendingPathComponent("npm").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: npm.path) else {
            throw FFmpegError(message: "npm was not found next to Node.js (\(node)). Reinstall Node.js from nodejs.org.")
        }
        let manager = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try Data(#"{"private": true}"#.utf8).write(to: staging.appendingPathComponent("package.json"))
        let environment = environment(node: node)
        progress("Downloading HyperFrames \(version)…")
        let installed = try await Shell.run(node, [npm.path, "install", "--no-audit", "--no-fund", "--save-exact",
                                                   "--prefix", staging.path, "hyperframes@\(version)"], environment: environment)
        guard installed.status == 0 else { throw failure("npm could not download HyperFrames", installed) }
        try? manager.removeItem(at: folder)
        try manager.moveItem(at: staging, to: folder)
        progress("Downloading the browser HyperFrames draws with…")
        let browser = try await Shell.run(node, [script.path, "browser", "ensure"], environment: environment)
        guard browser.status == 0 else { throw failure("HyperFrames could not download its browser", browser) }
        try Data(version.utf8).write(to: readyMarker)
    }

    /// Draws one unit page to `output`, a folder of frame_000001.png… with alpha.
    static func render(page: URL, to output: URL, fps: String, scale: Int, node: String) async throws {
        var arguments = [script.path, "render", page.path, "--format", "png-sequence", "--fps", fps,
                         "-o", output.path, "--quiet"]
        if scale == 2 { arguments += ["--resolution", "landscape-4k"] }
        let result = try await Shell.run(node, arguments, environment: environment(node: node))
        try Task.checkCancellation()
        guard result.status == 0 else { throw failure("HyperFrames could not draw a graphic", result) }
    }

    private static func failure(_ what: String, _ result: ShellResult) -> FFmpegError {
        let text = (result.stderrText + "\n" + result.stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = text.split(separator: "\n").suffix(3).joined(separator: "\n")
        return FFmpegError(message: tail.isEmpty ? "\(what) (exit \(result.status))." : "\(what): \(tail)")
    }
}

// MARK: - Rendering units, with a cache

enum GraphicsRender {
    /// One unit to draw for an export, and where its frames are kept.
    struct Job: Equatable {
        var unit: GraphicsUnit
        var fps: String
        /// 1 draws the 1920×1080 design size; 2 draws 3840×2160, for 4K exports.
        var scale: Int
        var key: String
        var folder: URL

        static let pattern = "frame_%06d.png"
        static let firstFrame = "frame_000001.png"
        var isRendered: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.firstFrame).path) }
    }

    static var cache: URL {
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_GRAPHICS_CACHE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/GraphicsRender", isDirectory: true)
    }

    /// Changes whenever the engine's files do, so a new engine never reuses old frames.
    static let engineStamp: String = {
        guard let resources = GraphicsEngine.resources else { return "no-engine" }
        var data = Data()
        let fonts = ((try? FileManager.default.contentsOfDirectory(atPath: resources.appendingPathComponent("fonts").path)) ?? [])
            .sorted().map { "fonts/\($0)" }
        for name in ["graphics.js", "graphics.css", "gsap.min.js", "page.html"] + fonts {
            data.append(Data(name.utf8))
            data.append((try? Data(contentsOf: resources.appendingPathComponent(name))) ?? Data())
        }
        return ColorCube.sha256(data)
    }()

    /// The units of `track` for frames at `fps` delivered `outputWidth` pixels wide. The key
    /// covers everything a unit's frames depend on: the engine, HyperFrames, the unit's data,
    /// its images (path, size and date), its length, the frame rate and the drawing size.
    static func jobs(for track: GraphicsTrack, fps: String, outputWidth: Double) -> [Job] {
        let rate = FFmpeg.rate(fps)
        let scale = outputWidth > 2400 ? 2 : 1
        return track.renderUnits(fps: rate).map { unit in
            let data = (try? unit.track.engineData(duration: unit.duration, fps: fps)) ?? Data()
            var material = [engineStamp, HyperFrames.version, unit.id, fps, String(scale),
                            String(format: "%.6f", unit.duration), String(decoding: data, as: UTF8.self)]
            for graphic in unit.track.items {
                JSONValue.object(graphic.props).visit { key, value in
                    guard key == "image", let path = value.string else { return }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                    let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
                    let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    material.append("\(path) \(size) \(date)")
                }
            }
            let key = ColorCube.sha256(Data(material.joined(separator: "\n").utf8))
            return Job(unit: unit, fps: fps, scale: scale, key: key, folder: cache.appendingPathComponent(key, isDirectory: true))
        }
    }

    /// Draws every job not in the cache yet, reporting 0…1 by length drawn. Each unit is
    /// drawn into a work folder and moved into the cache only when complete, so a cancelled
    /// or failed render leaves nothing half-made behind. Returns how many were drawn.
    @discardableResult
    static func render(_ jobs: [Job], progress: @escaping @Sendable (Double) -> Void,
                       draw: (Job, _ page: URL, _ frames: URL) async throws -> Void) async throws -> Int {
        let missing = jobs.filter { !$0.isRendered }
        guard !missing.isEmpty else { return 0 }
        let manager = FileManager.default
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        let total = max(0.001, missing.map(\.unit.duration).reduce(0, +))
        var drawn = 0.0
        progress(0)
        for job in missing {
            try Task.checkCancellation()
            let work = cache.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: work) }
            let page = work.appendingPathComponent("page", isDirectory: true)
            let frames = work.appendingPathComponent("frames", isDirectory: true)
            _ = try GraphicsEngine.writePage(job.unit.track, duration: job.unit.duration, fps: job.fps, mode: "unit",
                                             unit: job.unit.id, origin: 0, pageDuration: job.unit.duration, to: page)
            try await draw(job, page, frames)
            try Task.checkCancellation()
            guard manager.fileExists(atPath: frames.appendingPathComponent(Job.firstFrame).path) else {
                throw FFmpegError(message: "No frames were drawn for the \(job.unit.name.lowercased()).")
            }
            try? manager.removeItem(at: job.folder)
            try manager.moveItem(at: frames, to: job.folder)
            drawn += job.unit.duration
            progress(min(1, drawn / total))
        }
        return missing.count
    }

    /// Marks the jobs' frames as used now, then removes frames no export has used for
    /// `keepDays` days.
    static func touchAndPrune(_ jobs: [Job], keepDays: Double = 30) {
        let manager = FileManager.default
        let now = Date()
        for job in jobs where job.isRendered {
            try? manager.setAttributes([.modificationDate: now], ofItemAtPath: job.folder.path)
        }
        guard let entries = try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(date) > keepDays * 86_400 { try? manager.removeItem(at: entry) }
        }
    }
}

// MARK: - The graphics over an export

extension VideoItem {
    /// The graphics an export draws under `settings`: none when they are switched off.
    func exportGraphics(_ settings: ExportSettings) -> GraphicsTrack? {
        settings.drawsGraphics ? graphics : nil
    }
}

extension FFmpeg {
    static func rate(_ expression: String) -> Double {
        let parts = expression.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.first ?? 30
    }

    /// One input per unit: its frames at the export's rate, starting at its origin.
    static func graphicsInputs(_ jobs: [GraphicsRender.Job]) -> [String] {
        jobs.flatMap { job in
            ["-framerate", job.fps, "-itsoffset", String(format: "%.6f", job.unit.origin), "-start_number", "1",
             "-i", job.folder.appendingPathComponent(GraphicsRender.Job.pattern).path]
        }
    }

    /// The rendered graphics over the delivered picture: graph parts reading `[gfin]` and
    /// writing `[gfout]`, for inputs `firstInput` onwards. Each unit is scaled to the
    /// frame's width and pinned to the top, the way the preview fits the 1920×1080 stage,
    /// and converted to the frame's own matrix and range.
    static func graphicsStage(_ jobs: [GraphicsRender.Job], frame: CGSize, firstInput: Int,
                              matrix: String, tags: FrameTags) -> EffectStage? {
        guard let first = jobs.first else { return nil }
        let stage = first.unit.track.canvas.size
        let w = Int(frame.width), h = Int((frame.width * stage.height / stage.width / 2).rounded()) * 2
        var parts: [String] = []
        var current = "gfin"
        for index in jobs.indices {
            parts.append("[\(firstInput + index):v]scale=\(w):\(h):flags=lanczos:out_color_matrix=\(matrix)"
                         + ":out_range=\(tags.fullRange ? "pc" : "tv"),format=yuva420p,\(tags.filter)[gf\(index)]")
            let next = index == jobs.count - 1 ? "gfout" : "gfo\(index)"
            // Without repeatlast=0 the unit's last frame would stay on screen after it ends.
            parts.append("[\(current)][gf\(index)]overlay=x=0:y=0:eof_action=pass:repeatlast=0[\(next)]")
            current = next
        }
        return EffectStage(parts: parts)
    }

    /// Why a recording's graphics cannot be exported as asked, if they cannot. Graphics are
    /// drawn in standard colour; over HDR kept as HDR they would come out wrong.
    static func graphicsProblem(_ graphics: GraphicsTrack?, info: MediaInfo, settings: ExportSettings) -> String? {
        guard let graphics, !graphics.items.isEmpty, info.isHDR, !settings.toneMapHDR else { return nil }
        return "Graphics are drawn in standard colour. Turn on Convert HDR to SDR to export this \(info.hdrLabel ?? "HDR") recording with its graphics."
    }
}
