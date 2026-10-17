import Foundation

// Graphics that cover the whole picture (zone `cover`): kinetic text, big words shown on
// the times they are spoken, and section cards, a section's title over a seek bar that
// shows how far into the video it starts. Both sit over a near-black or a dimmed picture,
// for design videos that move from one part to the next.

enum CoverBackground {
    static let values = ["solid", "dim"]

    static func problem(_ props: [String: JSONValue], name: String) -> String? {
        if let background = props["background"], !(background.string.map(values.contains) ?? false) {
            return "A \(name)'s background is solid (near black) or dim (the picture, darkened)."
        }
        return nil
    }
}

enum KineticText {
    static let maximumWords = 24
    static let maximumWordLength = 40
    static let maximumText = 160
    static let layouts = ["line", "stack"]
    /// The last word shows at least this long before the words leave.
    static let lastWordHold = 0.25

    /// The transcript's words spoken from `start` to `end` of the edited recording, each
    /// with `at`, seconds after `start`: the words of a kinetic text over that time.
    static func words(_ transcript: Transcript?, timeline: ClipTimeline, from start: Double, to end: Double) -> [JSONValue] {
        guard let transcript else { return [] }
        var words: [JSONValue] = []
        for word in transcript.words {
            guard let edited = timeline.time(forSource: word.start), edited >= start - 0.05, edited < end - lastWordHold else { continue }
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            words.append(.object(["text": .string(String(text.prefix(maximumWordLength))),
                                  "at": .number((max(0, edited - start) * 1000).rounded() / 1000)]))
        }
        return Array(words.prefix(maximumWords))
    }

    /// The first thing wrong with a kinetic text's props, or nil.
    static func problem(props: [String: JSONValue], length: Double) -> String? {
        if let words = props["words"] {
            guard let list = words.array else {
                return "A kinetic text's words are a list of {text, at}, or \"transcript\" to take them from what is said."
            }
            guard (1...maximumWords).contains(list.count) else { return "A kinetic text shows 1 to \(maximumWords) words." }
            var last = -1.0
            for word in list {
                guard let object = word.object, let text = object["text"]?.string,
                      !text.trimmingCharacters(in: .whitespaces).isEmpty, text.count <= maximumWordLength, !text.contains("\n") else {
                    return "Each word of a kinetic text is one line of 1 to \(maximumWordLength) characters."
                }
                guard let at = object["at"]?.number, at >= last, at < length - lastWordHold + 0.000001 else {
                    return String(format: "A kinetic text's words come in order, each at least %.2f s before it ends (it shows for %.2f s).", lastWordHold, length)
                }
                last = at
            }
        } else {
            guard let text = props["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "A kinetic text needs words: a list of {text, at}, \"transcript\", or text."
            }
            guard text.count <= maximumText, text.split(whereSeparator: \.isWhitespace).count <= maximumWords else {
                return "A kinetic text's text is at most \(maximumText) characters and \(maximumWords) words."
            }
        }
        if let layout = props["layout"], !(layout.string.map(layouts.contains) ?? false) {
            return "A kinetic text's layout is line (one centred line that wraps) or stack (one word on each line)."
        }
        return CoverBackground.problem(props, name: "kinetic text")
    }
}

enum SectionCard {
    static let maximumTitle = 40
    static let maximumKicker = 30
    static let lengths = 1.0...8.0

    /// The first thing wrong with a section card's props, or nil. Its place in the video
    /// (`progress`, `marks`) is the app's to write, so it is not checked here.
    static func problem(props: [String: JSONValue], length: Double) -> String? {
        guard let title = props["title"]?.string, !title.trimmingCharacters(in: .whitespaces).isEmpty,
              title.count <= maximumTitle, !title.contains("\n") else {
            return "A section card needs a title: one line of \(maximumTitle) characters or fewer."
        }
        if let kicker = props["kicker"] {
            guard let text = kicker.string, text.count <= maximumKicker, !text.contains("\n") else {
                return "A section card's kicker is one line of \(maximumKicker) characters or fewer."
            }
        }
        guard length >= lengths.lowerBound - 0.000001, length <= lengths.upperBound + 0.000001 else {
            return String(format: "A section card shows for %.0f to %.0f seconds.", lengths.lowerBound, lengths.upperBound)
        }
        return CoverBackground.problem(props, name: "section card")
    }
}

extension VideoItem {
    /// `track` with each section card's place written into its props: `progress`, how far
    /// into the video (or into `short`) it starts, and `marks`, where every section card in
    /// it starts, both from 0 to 1. Worked out when drawn, so a cut never leaves them stale.
    func placingSections(_ track: GraphicsTrack, short: Short?) -> GraphicsTrack {
        guard track.items.contains(where: { $0.kind == .sectionCard }) else { return track }
        let from = short?.start ?? 0
        let length = short?.length ?? editedDuration
        guard length > 0 else { return track }
        func fraction(_ time: Double) -> Double { (min(1, max(0, (time - from) / length)) * 10_000).rounded() / 10_000 }
        let marks = track.items.filter { $0.kind == .sectionCard && $0.start >= from - 0.0005 && $0.start < from + length }
            .map { fraction($0.start) }.sorted()
        var placed = track
        for index in placed.items.indices where placed.items[index].kind == .sectionCard {
            placed.items[index].props["progress"] = .number(fraction(placed.items[index].start))
            placed.items[index].props["marks"] = .array(marks.map { .number($0) })
        }
        return placed
    }
}
