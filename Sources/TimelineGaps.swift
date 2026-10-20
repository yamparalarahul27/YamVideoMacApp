import Foundation

/// Space on the timeline in front of a section, left where a section was deleted, trimmed
/// or moved away, so the rest of the row stays where it was while you cut. Only the
/// timeline shows it: playback and every export join the sections, as they always have.
/// Close Gaps joins them on the timeline too.
struct SectionGap: Codable, Equatable {
    /// The section after the space.
    var section: UUID
    /// Seconds of space, as the timeline draws them.
    var length: Double

    /// Shorter than this is no gap: rounding, not space anyone left.
    static let minimum = 0.0005
    /// The most space in front of one section: a day.
    static let maximum = 86_400.0
}

extension [UUID: Double] {
    /// The gaps in section order, without empty ones or ones for sections that are gone.
    func sectionGaps(in timeline: ClipTimeline) -> [SectionGap] {
        timeline.segments.compactMap { segment in
            guard let length = self[segment.id], length >= SectionGap.minimum else { return nil }
            return SectionGap(section: segment.id, length: Swift.min(SectionGap.maximum, length))
        }
    }
}

extension [SectionGap] {
    var lengths: [UUID: Double] {
        Dictionary(map { ($0.section, $0.length) }, uniquingKeysWith: +)
    }
}

/// How the timeline lays the sections out when it leaves space: each section's start on
/// the row, in seconds from the left, with the gaps in. Edited time — what plays and what
/// every other row is measured in — has no gaps.
struct TimelineGapLayout: Equatable {
    /// Each gap at the edited time where it opens, in order.
    private(set) var gaps: [(at: Double, length: Double)] = []

    init() {}

    init(timeline: ClipTimeline, gaps lengths: [UUID: Double]) {
        var offset = 0.0
        for segment in timeline.segments {
            if let length = lengths[segment.id], length >= SectionGap.minimum { gaps.append((offset, length)) }
            offset += segment.duration
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.gaps.count == b.gaps.count && zip(a.gaps, b.gaps).allSatisfy { $0.at == $1.at && $0.length == $1.length }
    }

    var isEmpty: Bool { gaps.isEmpty }
    /// The edited times where gaps open.
    var openings: [Double] { gaps.map { $0.at } }
    /// All the space the timeline adds.
    var total: Double { gaps.reduce(0) { $0 + $1.length } }

    /// Where an edited time sits on the row. A time where a gap opens is the next section's
    /// first frame, so it sits after the gap; an `end` there is the last frame before it.
    func display(_ time: Double, end: Bool = false) -> Double {
        var shifted = time
        for gap in gaps {
            guard end ? gap.at < time - 1e-9 : gap.at <= time + 1e-9 else { break }
            shifted += gap.length
        }
        return shifted
    }

    /// The edited time at a place on the row. Anywhere in a gap is the moment the sections
    /// on either side of it meet.
    func edited(_ display: Double) -> Double {
        var shift = 0.0
        for gap in gaps {
            let opens = gap.at + shift
            if display < opens { return display - shift }
            if display < opens + gap.length { return gap.at }
            shift += gap.length
        }
        return display - shift
    }

    /// Whether a place on the row is in a gap.
    func inGap(_ display: Double) -> Bool {
        var shift = 0.0
        for gap in gaps {
            let opens = gap.at + shift
            if display < opens { return false }
            if display < opens + gap.length { return true }
            shift += gap.length
        }
        return false
    }
}

/// The rule the timeline edits by: a section you delete, trim or move leaves space, and
/// nothing else moves. Each section that stays keeps its place on the row where it can;
/// one that has to move only goes as far as it must, and the ones after it use up space
/// before they move.
enum SectionPlaces {
    /// Each section's start on the row.
    static func starts(_ timeline: ClipTimeline, gaps: [UUID: Double]) -> [UUID: Double] {
        var place = 0.0
        var starts: [UUID: Double] = [:]
        for segment in timeline.segments {
            place += gaps[segment.id] ?? 0
            starts[segment.id] = place
            place += segment.duration
        }
        return starts
    }

    /// The gaps that hold the sections of `new` where they were in `old`. A section whose
    /// source start moved (its start was trimmed) keeps its end in place; the others keep
    /// their start. `pinned` places a section by hand, as a drag drops it. New sections,
    /// like the right half of a split, follow the section before them.
    static func gaps(after old: ClipTimeline, _ oldGaps: [UUID: Double], new: ClipTimeline,
                     pinned: [UUID: Double] = [:]) -> [UUID: Double] {
        let oldStarts = starts(old, gaps: oldGaps)
        let oldSegments = Dictionary(old.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var place = 0.0
        var gaps: [UUID: Double] = [:]
        for segment in new.segments {
            var target: Double?
            if let pin = pinned[segment.id] {
                target = pin
            } else if let was = oldSegments[segment.id], let start = oldStarts[segment.id] {
                target = abs(was.start - segment.start) > 0.000001 ? start + was.duration - segment.duration : start
            }
            if let target, target - place >= SectionGap.minimum {
                gaps[segment.id] = min(SectionGap.maximum, target - place)
                place = target
            }
            place += segment.duration
        }
        return gaps
    }
}

extension ProjectClip {
    /// The recording as the player and exports see it: gaps are only on the timeline.
    static func withoutGaps(_ item: VideoItem) -> ProjectClip {
        var clip = ProjectClip(item)
        clip.gaps = nil
        return clip
    }
}
