import CoreGraphics
import Foundation

// The eye path (docs/plans/thumbnail-science.md, part 3): where a viewer looks first on a
// thumbnail. The eye goes to a face first, then to the biggest and clearest words, and
// colour pulls it too. The words the owner marks with asterisks are the important part:
// they must be first or second on the path. Pure: from what the phone check measures.

/// One stop of the eye on the thumbnail.
struct EyeStop: Codable, Equatable {
    enum Kind: String, Codable { case face, accent, title, tag, picture }
    var kind: Kind
    /// The words; empty for the face.
    var text: String
    /// Where it is, in stage pixels (1920×1080).
    var box: ThumbnailLayout.Box
    /// How strongly it pulls the eye: the letter size in stage pixels, times its clarity
    /// and its colour; for the face, its height. The face is first whatever its pull.
    var pull: Double
}

enum EyePath {
    /// A run in the accent colour pulls more than white or dark words of the same size, and
    /// a band of the accent more still.
    static let colourPull = (accent: 1.15, band: 1.3)
    /// The most stops to show: more marks make the picture hard to read.
    static let shown = 5

    /// The stops in the order the eye takes them: the face (when it shows), then each run
    /// of words by its pull. `contrasts` has one value for each run of `layout`.
    static func make(layout: ThumbnailLayout, contrasts: [Double?], face: CGRect?) -> [EyeStop] {
        var words: [EyeStop] = []
        for (index, run) in layout.runs.enumerated() {
            let text = run.text.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let first = run.boxes.first else { continue }
            let box = run.boxes.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            // Low contrast hides words: below the limit that reads at a glance, they pull less.
            let contrast = index < contrasts.count ? contrasts[index] : nil
            let clarity = contrast.map { min(1, $0 / PhoneCheck.contrastLimits.reads) } ?? 1
            let colour = run.background != nil && run.kind != .tag ? colourPull.band
                : run.kind == .accent ? colourPull.accent : 1
            let kind: EyeStop.Kind
            switch run.kind {
            case .tag: kind = .tag
            case .title: kind = .title
            case .accent: kind = .accent
            case .picture: kind = .picture
            }
            words.append(EyeStop(kind: kind, text: text, box: ThumbnailLayout.Box(box), pull: run.size * clarity * colour))
        }
        // The biggest pull first; at the same pull, the larger area.
        words.sort { ($0.pull, $0.box.w * $0.box.h) > ($1.pull, $1.box.w * $1.box.h) }
        guard let face else { return words }
        return [EyeStop(kind: .face, text: "", box: ThumbnailLayout.Box(face), pull: face.height)] + words
    }

    /// A weak finding when the important words (the accent words) are not first or second
    /// on the path; nil when they are, or when no words are marked.
    static func finding(_ path: [EyeStop]) -> PhoneCheck.Finding? {
        guard let index = path.firstIndex(where: { $0.kind == .accent }), index > 1 else { return nil }
        let words = PhoneCheck.quoted(path[index].text, limit: 22)
        let ahead = path[..<index].map { stop -> String in
            switch stop.kind {
            case .face: return "the face"
            case .tag: return "the tag"
            case .picture: return "the picture's words"
            case .title, .accent: return PhoneCheck.quoted(stop.text, limit: 22)
            }
        }
        return PhoneCheck.Finding(kind: .eyePath, level: .weak, sizes: [],
                                  summary: "Eye path: \(words) is \(ordinal(index + 1))",
                                  message: "The eye goes to the face first, then to the biggest and clearest words. Your coloured words "
                                  + "\(words) come \(ordinal(index + 1)), after " + list(ahead) + ". Make them bigger or clearer "
                                  + "(Highlight helps), or make the other words smaller.")
    }

    static func ordinal(_ number: Int) -> String {
        switch number {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(number)th"
        }
    }

    private static func list(_ parts: [String]) -> String {
        parts.count <= 1 ? parts.joined() : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}
