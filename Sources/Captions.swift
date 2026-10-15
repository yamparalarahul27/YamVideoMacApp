import Foundation

// Captions on the edited timeline. A subtitle file is timed against the source recording;
// once sections are cut, reordered or sped up, each caption has to move with its footage,
// both for the file uploaded to YouTube and for captions burned into an export.

/// One caption: source or edited seconds, and its text (lines kept).
struct Caption: Equatable {
    var start: Double
    var end: Double
    var text: String
}

enum Captions {
    /// Files whose timing this can read and rewrite. ASS and SSA keep their source timing.
    static let retimable: Set<String> = ["srt", "vtt"]

    /// Reads SRT or WebVTT cues. Styling inside the text is kept as it is.
    static func parse(_ text: String) throws -> [Caption] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var captions: [Caption] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let sides = lines[index].components(separatedBy: "-->")
            guard sides.count == 2, let start = time(sides[0]),
                  let end = time(sides[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else {
                throw FFmpegError(message: "Could not read the caption timing \"\(lines[index])\".")
            }
            let body = lines[(index + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if end > start, !body.isEmpty { captions.append(Caption(start: start, end: end, text: body)) }
        }
        return captions.sorted { $0.start < $1.start }
    }

    /// "00:01:02,500", "01:02.500" or "1:02:03.5" in seconds.
    private static func time(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!) else { return nil }
        let units = parts.dropLast().compactMap { Double($0) }
        guard units.count == parts.count - 1 else { return nil }
        return units.reduce(0) { $0 * 60 + $1 } * 60 + seconds
    }

    /// SubRip, numbered from 1.
    static func srt(_ captions: [Caption]) -> String {
        captions.enumerated().map { index, caption in
            "\(index + 1)\n\(stamp(caption.start)) --> \(stamp(caption.end))\n\(caption.text)\n"
        }.joined(separator: "\n")
    }

    private static func stamp(_ seconds: Double) -> String {
        let millis = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
    }

    /// Moves source-timed captions onto the edited timeline: each part of a caption that
    /// survives the cuts shows while its footage plays, faster or slower with its section.
    /// Parts shorter than a twentieth of a second are dropped; a caption whose footage is
    /// cut away entirely is dropped too.
    static func edited(_ captions: [Caption], timeline: ClipTimeline) -> [Caption] {
        var result: [Caption] = []
        var offset = 0.0
        for segment in timeline.segments {
            for caption in captions {
                let from = max(caption.start, segment.start), to = min(caption.end, segment.end)
                guard to - from >= 0.05 else { continue }
                let start = offset + (from - segment.start) / segment.speed
                let end = offset + (to - segment.start) / segment.speed
                result.append(Caption(start: start, end: end, text: caption.text))
            }
            offset += segment.duration
        }
        result.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        // One caption split by a cut that lands back to back plays as one.
        var merged: [Caption] = []
        for caption in result {
            if let last = merged.last, last.text == caption.text, abs(last.end - caption.start) < 0.001 {
                merged[merged.count - 1].end = caption.end
            } else {
                merged.append(caption)
            }
        }
        return merged
    }

    /// The recording's captions as an edited-time SRT, or nil when the file cannot be
    /// retimed (ASS, unreadable).
    static func editedSRT(_ subtitles: URL, timeline: ClipTimeline) -> String? {
        guard retimable.contains(subtitles.pathExtension.lowercased()),
              let text = try? String(contentsOf: subtitles, encoding: .utf8),
              let captions = try? parse(text) else { return nil }
        return srt(edited(captions, timeline: timeline))
    }
}

extension FFmpeg {
    /// The caption file an export burns in. Without edits it is the staged copy of the
    /// file itself. With cut, moved or retimed sections, captions are burned after the
    /// sections are joined, so an SRT or VTT is moved onto the edited timeline first
    /// (written under a content name, as staged files are); ASS keeps its source timing.
    static func burnedCaptions(_ subtitles: URL, segments: [TimelineSegment]?) -> URL {
        let staged = stagedSubtitlesURL(for: subtitles)
        guard let segments, let srt = Captions.editedSRT(subtitles, timeline: ClipTimeline(segments: segments)) else { return staged }
        let data = Data(srt.utf8)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yamvideo-subs-edited-\(ColorCube.sha256(data).prefix(16))").appendingPathExtension("srt")
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        return url
    }
}
