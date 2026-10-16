import AppKit
import CoreGraphics
import Foundation
import Vision

// Suggest Frames: the moments of the kept footage where the speaker looks best for a
// thumbnail (a smile, eyes open, facing the camera, a sharp face), found with Apple
// Vision. The thumbnail maker shows them to click; agents get them from `analyze` with
// kind `thumbnailFrames`, with a contact sheet to look at.

/// What Vision sees of the speaker's face in one frame. Each measure is from 0 to 1.
struct FaceLook: Equatable {
    /// A wide mouth with its corners up.
    var smile: Double
    /// Vision's face capture quality: sharp, lit and not covered.
    var quality: Double
    /// Both eyes open.
    var eyes: Double
    /// 1 when the face looks straight at the camera.
    var facing: Double
    /// The face, top-left origin: in the measured picture's pixels, and in the
    /// recording's own pixels in a suggestion.
    var face: CGRect

    /// How good the moment is for a thumbnail, from 0 to 1. Closed eyes rule a frame out.
    var score: Double {
        let base = smile * 0.45 + quality * 0.25 + eyes * 0.15 + facing * 0.15
        return eyes < 0.15 ? base * 0.3 : base
    }

    /// The measures from Vision's landmarks (points in the face box, y up) and its
    /// capture quality. The ranges come from real headshots: a mouth at rest is about
    /// 0.3 of the face box wide and a broad smile about 0.4.
    static func measure(lips: [CGPoint], leftEye: [CGPoint], rightEye: [CGPoint], nose: [CGPoint],
                        quality: Double, face: CGRect) -> FaceLook? {
        guard lips.count >= 6, leftEye.count >= 3, rightEye.count >= 3 else { return nil }
        func unit(_ value: Double) -> Double { min(1, max(0, value)) }
        let xs = lips.map { Double($0.x) }, ys = lips.map { Double($0.y) }
        let minX = xs.min()!, maxX = xs.max()!, bottom = ys.min()!, top = ys.max()!
        let corners = (ys[xs.firstIndex(of: minX)!] + ys[xs.firstIndex(of: maxX)!]) / 2
        let width = maxX - minX
        let lift = (corners - bottom) / max(0.001, top - bottom)
        let smile = 0.65 * unit((width - 0.30) / 0.10) + 0.35 * unit((lift - 0.40) / 0.35)
        func openness(_ points: [CGPoint]) -> Double {
            let x = points.map { Double($0.x) }, y = points.map { Double($0.y) }
            return (y.max()! - y.min()!) / max(0.001, x.max()! - x.min()!)
        }
        let eyes = unit(((openness(leftEye) + openness(rightEye)) / 2 - 0.18) / 0.17)
        func centre(_ points: [CGPoint]) -> Double { points.reduce(0) { $0 + Double($1.x) } / Double(points.count) }
        let left = centre(leftEye), right = centre(rightEye)
        let noseX = nose.isEmpty ? (left + right) / 2 : centre(nose)
        let facing = unit(1 - abs(noseX - (left + right) / 2) / max(0.001, abs(right - left)) / 0.25)
        return FaceLook(smile: smile, quality: unit((quality - 0.30) / 0.35), eyes: eyes, facing: facing, face: face)
    }
}

/// One suggested moment for the thumbnail.
struct FrameSuggestion: Identifiable {
    var id: Double { time }
    /// Edited-recording seconds: the thumbnail design's time.
    var time: Double
    /// Source seconds of the recording.
    var source: Double
    var look: FaceLook
    /// A square picture round the face, for the maker's list.
    var picture: CGImage?
}

enum FrameAnalyzer {
    /// The largest face in `image`, measured; nil when Vision finds none.
    static func look(at image: CGImage) -> FaceLook? {
        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([landmarks, quality])
        guard let face = (landmarks.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let marks = face.landmarks, let lips = marks.outerLips?.normalizedPoints,
              let left = marks.leftEye?.normalizedPoints, let right = marks.rightEye?.normalizedPoints else { return nil }
        let captured = (quality.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width })?.faceCaptureQuality ?? 0
        let w = Double(image.width), h = Double(image.height), b = face.boundingBox
        let box = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        return FaceLook.measure(lips: lips, leftEye: left, rightEye: right, nose: marks.nose?.normalizedPoints ?? [],
                                quality: Double(captured), face: box)
    }

    /// The edited time of a source time, when it plays and is not within `edge` seconds of
    /// a cut (frames at a cut often show a blink or a half word).
    static func edited(_ source: Double, in timeline: ClipTimeline, edge: Double = 0.12) -> Double? {
        var offset = 0.0
        for segment in timeline.segments {
            if source >= segment.start + edge && source < segment.end - edge {
                return offset + (source - segment.start) / segment.speed
            }
            offset += segment.duration
        }
        return nil
    }

    /// The indices of the best `count` scores, at least `spacing` seconds apart, best first.
    static func pick(_ items: [(time: Double, score: Double)], count: Int, spacing: Double) -> [Int] {
        var chosen: [Int] = []
        for index in items.indices.sorted(by: { items[$0].score > items[$1].score }) {
            guard chosen.count < count else { break }
            if chosen.allSatisfy({ abs(items[$0].time - items[index].time) >= spacing }) { chosen.append(index) }
        }
        return chosen
    }

    /// Frames ffmpeg writes as JPEG files into `folder`, with their source times.
    static func frames(_ arguments: [String], into folder: URL, start: Double = 0) async throws -> [(source: Double, url: URL)] {
        guard let ffmpeg = FFmpeg.ffmpegPath else { throw FFmpegError(message: "Locate ffmpeg first.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "info"] + arguments
                                         + ["-q:v", "4", folder.appendingPathComponent("f%05d.jpg").path])
        try Task.checkCancellation()
        guard result.status == 0 else { throw FFmpegError(message: "Could not read the recording's frames: \(result.stderrText.suffix(400))") }
        // showinfo prints each frame's time in order; the files are numbered in the same order.
        let times = result.stderrText.components(separatedBy: "\n").compactMap { line -> Double? in
            guard line.contains("showinfo"), let range = line.range(of: "pts_time:") else { return nil }
            return Double(line[range.upperBound...].prefix { "0123456789.-".contains($0) })
        }
        return times.enumerated().map { index, time in
            (start + time, folder.appendingPathComponent(String(format: "f%05d.jpg", index + 1)))
        }
    }

    private static func image(_ url: URL) -> CGImage? {
        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The best moments of the kept footage for a thumbnail, best first: the key frames
    /// (about one a second) are read and measured, then ten frames a second round the
    /// best of them, and the best frame of each moment is kept. Moments are at least
    /// `spacing` seconds of the edit apart.
    static func analyze(_ clip: VideoItem, count: Int = 8, spacing: Double = 3) async throws -> [FrameSuggestion] {
        guard clip.info != nil else { throw FFmpegError(message: "Load the recording first.") }
        let timeline = clip.timeline
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YamVideo-frames-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let keys = try await frames(["-skip_frame", "nokey", "-i", clip.url.path, "-an", "-vf", "scale=640:-2,showinfo",
                                     "-fps_mode", "passthrough"], into: folder.appendingPathComponent("keys"))
        var coarse: [(time: Double, source: Double, score: Double)] = []
        for frame in keys {
            try Task.checkCancellation()
            guard let time = edited(frame.source, in: timeline), let picture = image(frame.url), let look = look(at: picture) else { continue }
            coarse.append((time, frame.source, look.score))
        }
        let windows = pick(coarse.map { ($0.time, $0.score) }, count: count * 2, spacing: spacing).map { coarse[$0] }

        var refined: [FrameSuggestion] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let from = max(0, window.source - 0.6)
            let near = try await frames(["-ss", String(format: "%.3f", from), "-t", "1.2", "-i", clip.url.path, "-an",
                                         "-vf", "fps=10,scale=960:-2,showinfo"], into: folder.appendingPathComponent("w\(index)"), start: from)
            var best: (suggestion: FrameSuggestion, score: Double)?
            for frame in near {
                guard let time = edited(frame.source, in: timeline), let picture = image(frame.url), var look = look(at: picture),
                      look.score > (best?.score ?? -1) else { continue }
                let crop = crop(picture, around: look.face)
                let k = Double(clip.info?.width ?? picture.width) / Double(picture.width)
                look.face = CGRect(x: look.face.minX * k, y: look.face.minY * k, width: look.face.width * k, height: look.face.height * k)
                best = (FrameSuggestion(time: time, source: frame.source, look: look, picture: crop), look.score)
            }
            if let best { refined.append(best.suggestion) }
        }
        return pick(refined.map { ($0.time, $0.look.score) }, count: count, spacing: spacing).map { refined[$0] }
    }

    /// A square round the face, 1.8 times its size, at 240 px.
    static func crop(_ image: CGImage, around face: CGRect, size: Int = 240) -> CGImage? {
        let side = max(face.width, face.height) * 1.8
        let square = CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let part = image.cropping(to: square),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(part, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }

    /// The suggestions' faces in a grid, each labelled with its number and edited time, so
    /// an agent can look at them all in one picture.
    static func sheet(_ suggestions: [FrameSuggestion], columns: Int = 4) -> CGImage? {
        let cell = 240, label = 34
        let rows = max(1, (suggestions.count + columns - 1) / columns)
        let width = columns * cell, height = rows * (cell + label)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        for (index, suggestion) in suggestions.enumerated() {
            let x = (index % columns) * cell, top = height - (index / columns) * (cell + label)
            if let picture = suggestion.picture {
                context.draw(picture, in: CGRect(x: x, y: top - cell, width: cell, height: cell))
            }
            let text = String(format: "%d  %@  %.0f%%", index + 1, PublishInfo.timestamp(suggestion.time), suggestion.look.score * 100)
            NSAttributedString(string: text, attributes: attributes).draw(at: CGPoint(x: x + 8, y: top - cell - label + 8))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
