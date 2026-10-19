import Foundation

// The information gap (docs/plans/thumbnail-science.md, part 2): a click comes from a
// question the viewer wants answered. The title says what the video is; the thumbnail
// adds what the title does not say (the result, a number, a surprise). A thumbnail that
// repeats the title opens no question. Pure: words in, words out.

/// What the thumbnail's words share with the video's title.
struct InformationGap: Equatable {
    /// The thumbnail's important words that the title also has, as the title writes them.
    var repeated: [String]
    /// Runs of words the thumbnail and the title share, as the title writes them, in the
    /// title's order.
    var phrases: [String]
    /// The thumbnail's important words that the title does not have, as the thumbnail
    /// writes them: what the thumbnail adds.
    var added: [String]
    /// The share of the thumbnail's important words that are in the title, 0 to 1.
    var overlap: Double
    /// Nil when the thumbnail adds enough to the title, or there is nothing to compare.
    var finding: PhoneCheck.Finding?

    /// What to do when the thumbnail repeats the title.
    static let advice = "Let the thumbnail say what the title does not: the result, a number, a surprise or a question."

    /// Small words that carry no meaning of their own; they do not count as a repeat.
    static let smallWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "for", "of", "to", "in", "on", "at", "by", "with", "from",
        "into", "onto", "about", "as", "up", "out", "off", "over", "than", "then", "this", "that", "these", "those", "it", "its",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "has", "have", "had", "will", "can", "could",
        "should", "would", "i", "me", "my", "mine", "we", "us", "our", "you", "your", "he", "she", "they", "them", "their",
        "how", "what", "why", "when", "where", "who", "which", "not", "no", "yes", "all", "just", "very", "too", "own",
        "part", "vs", "via",
    ]

    /// Compares a design's words (the tag, the title, and the lines read in the picture as
    /// one text) with the video's title.
    static func make(_ design: ThumbnailDesign, pictureWords: [String], title: String) -> InformationGap {
        make(thumbnail: [design.tag, design.title, pictureWords.joined(separator: " ")], title: title)
    }

    /// Compares the thumbnail's texts, in reading order, with the video's title. A shared
    /// run of words does not go from one text to the next.
    static func make(thumbnail: [String], title: String) -> InformationGap {
        let shown = thumbnail.flatMap { text -> [Token] in
            var words = tokens(text)
            if !words.isEmpty { words[words.count - 1].breakAfter = true }
            return words
        }
        let titled = tokens(title)
        let important = shown.filter(\.important)
        guard !important.isEmpty, titled.contains(where: \.important) else {
            return InformationGap(repeated: [], phrases: [], added: unique(important.map(\.text)), overlap: 0, finding: nil)
        }
        let titleStems = Set(titled.filter(\.important).map(\.stem))
        var seen = Set<String>(), repeated: [String] = [], added: [String] = [], counted = Set<String>(), shared = 0
        for word in important {
            if titleStems.contains(word.stem) {
                if seen.insert(word.stem).inserted, let written = titled.first(where: { $0.stem == word.stem }) { repeated.append(written.text) }
            } else if seen.insert(word.stem).inserted {
                added.append(word.text)
            }
            if counted.insert(word.stem).inserted, titleStems.contains(word.stem) { shared += 1 }
        }
        let overlap = Double(shared) / Double(counted.count)
        let phrases = sharedRuns(shown, titled)

        var finding: PhoneCheck.Finding?
        if added.isEmpty, counted.count >= 2 {
            finding = PhoneCheck.Finding(kind: .title, level: .fails, sizes: [], summary: "Only repeats the video title",
                                         message: "The thumbnail only repeats the title, so it opens no question. " + advice)
        } else if let first = phrases.first {
            finding = PhoneCheck.Finding(kind: .title, level: .weak, sizes: [],
                                         summary: "Repeats the video title: " + PhoneCheck.quoted(first, limit: 22),
                                         message: "The thumbnail repeats the title: " + phrases.map { "“\($0)”" }.joined(separator: ", ") + ". " + advice)
        } else if overlap > 0.5 {
            finding = PhoneCheck.Finding(kind: .title, level: .weak, sizes: [], summary: "Mostly the video title's words",
                                         message: "Most of the thumbnail's words are in the title: " + repeated.joined(separator: ", ") + ". " + advice)
        }
        return InformationGap(repeated: repeated, phrases: phrases, added: added, overlap: overlap, finding: finding)
    }

    /// A word as written, and the form used to compare it. A run of shared words stops at
    /// a break: punctuation like a colon or a bracket, or the end of a text.
    struct Token: Equatable {
        var text: String
        var stem: String
        var important: Bool
        var breakBefore = false
        var breakAfter = false
    }

    /// The words of `text`: letters and digits, without asterisks, quotes and punctuation.
    /// The stem is lower case without a possessive or a plural ending.
    static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "*" || $0 == "/" || $0 == "—" || $0 == "–" }).compactMap { piece in
            let word = String(piece).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard PhoneCheck.isWord(word) else { return nil }
            var stem = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            for ending in ["'s", "’s"] where stem.hasSuffix(ending) { stem = String(stem.dropLast(2)) }
            if stem.count > 4, stem.hasSuffix("ies") { stem = String(stem.dropLast(3)) + "y" }
            else if stem.count > 3, stem.hasSuffix("s"), !stem.hasSuffix("ss") { stem = String(stem.dropLast()) }
            let small = smallWords.contains(word.lowercased())
            return Token(text: word, stem: stem, important: !small,
                         breakBefore: piece.first.map { "([{“\"‘'".contains($0) } ?? false,
                         breakAfter: piece.last.map { ":;,.!?)]}”\"’".contains($0) } ?? false)
        }
    }

    /// The longest runs of words the two have in the same order, as the title writes them,
    /// in the title's order.
    /// Small words count in a run, but a run needs two important words or four words in
    /// all. A shorter run inside a longer one is left out.
    static func sharedRuns(_ shown: [Token], _ titled: [Token]) -> [String] {
        guard !shown.isEmpty, !titled.isEmpty else { return [] }
        var length = [[Int]](repeating: [Int](repeating: 0, count: titled.count + 1), count: shown.count + 1)
        var runs: [(start: Int, count: Int)] = []
        for i in 1...shown.count {
            for j in 1...titled.count where shown[i - 1].stem == titled[j - 1].stem {
                let joined = i > 1 && j > 1 && !shown[i - 2].breakAfter && !shown[i - 1].breakBefore
                    && !titled[j - 2].breakAfter && !titled[j - 1].breakBefore
                length[i][j] = joined ? length[i - 1][j - 1] + 1 : 1
            }
        }
        for i in 1...shown.count {
            for j in 1...titled.count where length[i][j] > 0 {
                // Only the end of a run: the next pair is not part of it.
                let ends = i == shown.count || j == titled.count || length[i + 1][j + 1] != length[i][j] + 1
                guard ends else { continue }
                let count = length[i][j], start = j - count
                guard titled[start..<j].filter(\.important).count >= 2 || count >= 4 else { continue }
                runs.append((start, count))
            }
        }
        runs.sort { $0.count > $1.count }
        var kept: [(start: Int, count: Int)] = []
        for run in runs where !kept.contains(where: { $0.start <= run.start && run.start + run.count <= $0.start + $0.count }) {
            kept.append(run)
        }
        kept.sort { $0.start < $1.start }
        return unique(kept.map { titled[$0.start..<($0.start + $0.count)].map(\.text).joined(separator: " ") })
    }

    private static func unique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }
    }
}
