import Foundation

// Style.md (docs/plans/distribution.md, section 13): the channel's editing taste as rules,
// one Markdown file in the Library folder that every agent reads before it edits. Rules
// sit under `## ` headings, one `- ` line each, ending with where they came from in
// `*(…)*`. The owner edits it in the app or any text editor; agents add a rule only after
// the owner says yes.

enum StyleDoc {
    static let textLimit = 100_000
    static let ruleLimit = 400

    /// A new Library's Style.md: the headings, ready for rules.
    static let starter = """
    # Style

    How videos on this channel are edited. Every agent reads this before it edits.
    A rule is added only after the owner says yes. Each rule says where it came from.

    ## Every video

    ## Talking head

    ## Screen walkthrough

    ## Graphics

    ## Shorts

    ## Thumbnails

    """

    struct Section: Equatable {
        var name: String
        var rules: [String]
    }

    /// The headings and their rules, in order.
    static func sections(_ text: String) -> [Section] {
        var result: [Section] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                result.append(Section(name: String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), rules: []))
            } else if trimmed.hasPrefix("- "), !result.isEmpty {
                result[result.count - 1].rules.append(String(trimmed.dropFirst(2)))
            }
        }
        return result
    }

    /// A rule without its source: "Captions never over the face *(15 Oct)*" reads
    /// "Captions never over the face".
    static func bare(_ rule: String) -> String {
        guard let range = rule.range(of: " *(", options: .backwards), rule.hasSuffix(")*") else { return rule }
        return String(rule[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Why `text` cannot be Style.md, or nil.
    static func problem(_ text: String) -> String? {
        text.count > textLimit ? "Style.md is at most \(textLimit) characters; this is \(text.count)." : nil
    }

    /// `text` with `rule` added as the last rule under `section`; a section that is not
    /// there yet is added at the end. The source, when given, follows in `*(…)*`.
    static func adding(_ rule: String, to section: String, source: String?, in text: String) throws -> String {
        let clean = rule.trimmingCharacters(in: .whitespaces)
        let heading = section.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains(where: \.isNewline), clean.count <= ruleLimit else {
            throw EditError.invalid("A rule is one line of up to \(ruleLimit) characters.")
        }
        guard !heading.isEmpty, !heading.contains(where: \.isNewline), heading.count <= 80 else {
            throw EditError.invalid("A section is a heading of one line, like Shorts or Thumbnails.")
        }
        if let source, source.contains(where: \.isNewline) || source.count > 120 { throw EditError.invalid("A rule's source is one short line.") }
        if sections(text).contains(where: { $0.name.caseInsensitiveCompare(heading) == .orderedSame && $0.rules.contains { bare($0) == bare(clean) } }) {
            throw EditError.invalid("Style.md already has that rule under \(heading).")
        }
        let note = source.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : " *(\($0))*" } ?? ""
        let line = "- " + clean + note
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("## ") && trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(heading) == .orderedSame
        }) {
            let end = lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") } ?? lines.count
            let lastRule = lines[(start + 1)..<end].lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            lines.insert(line, at: (lastRule ?? start) + 1)
            // Keep a blank line between the rules and the next heading.
            let after = (lastRule ?? start) + 2
            if after < lines.count, lines[after].trimmingCharacters(in: .whitespaces).hasPrefix("#") { lines.insert("", at: after) }
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines += ["", "## " + heading, line, ""]
        }
        let result = lines.joined(separator: "\n")
        if let problem = problem(result) { throw EditError.invalid(problem) }
        return result
    }

    /// `text` without the rule whose words (without its source) are `rule`.
    static func removing(_ rule: String, in text: String) throws -> String {
        let target = bare(rule.trimmingCharacters(in: .whitespaces))
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("- ") && bare(String(trimmed.dropFirst(2))) == target
        }) else { throw EditError.notFound("Style.md has no rule \"\(target.prefix(80))\".") }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }
}
