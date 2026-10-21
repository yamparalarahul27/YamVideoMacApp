import Foundation

// The release calendar (phase 3 of docs/plans/distribution.md, section 15): when each video
// goes out, and where. A video's plan is a day (and an optional time) for every platform
// it goes to, or a day of its own for one of them. Days are calendar days as the owner
// says them ("2026-10-19"), so a plan never moves with a time zone or a clock change.

struct ReleasePlan: Codable, Equatable {
    /// "yyyy-MM-dd".
    var day: String
    /// "HH:mm", or nil for any time that day.
    var time: String?
    /// Where it goes out, in the platforms' own order.
    var platforms: [Platform]
    /// A platform that goes out on another day than `day`, by its raw value.
    var ownDays: [String: String]?

    init(day: String, time: String? = nil, platforms: [Platform] = Platform.allCases, ownDays: [String: String]? = nil) {
        self.day = day; self.time = time
        self.platforms = Platform.allCases.filter(platforms.contains)
        self.ownDays = ownDays?.isEmpty == true ? nil : ownDays
    }

    /// The day `platform` goes out on.
    func day(for platform: Platform) -> String { ownDays?[platform.rawValue] ?? day }

    /// The first thing wrong with the plan, or nil.
    var problem: String? {
        guard Self.date(day) != nil else { return "A release day is a date like 2026-10-19." }
        if let time, Self.minutes(time) == nil { return "A release time is like 19:00 (24-hour), or left out for any time that day." }
        guard !platforms.isEmpty else { return "A release goes out on at least one platform: youtube, instagram, x or linkedin." }
        for (key, value) in ownDays ?? [:] {
            guard let platform = Platform(rawValue: key), platforms.contains(platform) else {
                return "A platform's own day is for one of the platforms it goes out on; \(key) is not one."
            }
            guard Self.date(value) != nil else { return "\(platform.label)'s own day is a date like 2026-10-19." }
        }
        return nil
    }

    // MARK: Days

    /// The calendar the owner plans in: Gregorian, weeks from Monday, in the Mac's time zone.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        format.isLenient = false
        return format
    }()

    /// The start of `day` in the Mac's time zone, or nil when it is not a real date.
    static func date(_ day: String) -> Date? {
        guard day.count == 10, let date = dayFormat.date(from: day), dayFormat.string(from: date) == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func day(_ date: Date) -> String { dayFormat.string(from: date) }

    /// Minutes after midnight for "HH:mm", or nil.
    static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
        return hours * 60 + minutes
    }

    /// Plans for `count` videos, one every `every` days from `start`, each with the same
    /// time and platforms: how the owner usually spreads a long video's Shorts.
    static func spread(_ count: Int, from start: String, every: Int, time: String?, platforms: [Platform]) -> [ReleasePlan] {
        guard let first = date(start), count > 0 else { return [] }
        return (0..<count).compactMap { index in
            calendar.date(byAdding: .day, value: index * max(1, every), to: first).map {
                ReleasePlan(day: day($0), time: time, platforms: platforms)
            }
        }
    }
}

/// One video going out on one day: the platforms it goes to then, and which of them it
/// is already posted on.
struct Release: Identifiable, Equatable {
    var item: UUID
    var video: UUID
    var title: String
    var short: Bool
    var day: String
    var time: String?
    var platforms: [Platform]
    var posted: Set<Platform>

    var id: String { "\(video.uuidString) \(day)" }
}

extension Library {
    /// Every planned release, by day and then by time (any-time ones first), long videos
    /// before Shorts on the same day.
    var releases: [Release] {
        var result: [Release] = []
        for item in items {
            for video in item.videos {
                guard let plan = video.plan else { continue }
                let posted = Set(video.posts.compactMap(\.platform))
                var byDay: [String: [Platform]] = [:]
                for platform in plan.platforms { byDay[plan.day(for: platform), default: []].append(platform) }
                for (day, platforms) in byDay {
                    result.append(Release(item: item.id, video: video.id, title: video.title, short: video.short, day: day,
                                          time: plan.time, platforms: platforms, posted: posted))
                }
            }
        }
        return result.sorted {
            ($0.day, $0.time ?? "", $0.short ? 1 : 0, $0.title) < ($1.day, $1.time ?? "", $1.short ? 1 : 0, $1.title)
        }
    }

    /// The releases on each day of `days`.
    func releases(on days: [String]) -> [String: [Release]] {
        let wanted = Set(days)
        return Dictionary(grouping: releases.filter { wanted.contains($0.day) }, by: \.day)
    }
}

/// The days the calendar shows: whole weeks from Monday, around a month or one week.
enum CalendarPage {
    /// Every day of the weeks that hold `month`'s days (a date in the month).
    static func monthDays(_ month: Date) -> [Date] {
        let calendar = ReleasePlan.calendar
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let first = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start,
              let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end),
              let end = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.end else { return [] }
        var days: [Date] = []
        var day = first
        while day < end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// The seven days of the week that holds `date`, from Monday.
    static func weekDays(_ date: Date) -> [Date] {
        let calendar = ReleasePlan.calendar
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

// MARK: - The rhythm, empty slots and missed posts

/// A day of the week, as the owner says it.
enum Weekday: String, Codable, CaseIterable, Identifiable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday
    var id: String { rawValue }
    /// `Calendar`'s number for it: 1 is Sunday.
    var number: Int { self == .sunday ? 1 : (Self.allCases.firstIndex(of: self) ?? 0) + 2 }
    var label: String { rawValue.capitalized }
    var short: String { String(label.prefix(3)) }

    init?(_ date: Date) {
        let number = ReleasePlan.calendar.component(.weekday, from: date)
        guard let day = Self.allCases.first(where: { $0.number == number }) else { return nil }
        self = day
    }
}

/// The owner's release rhythm (Style.md): the day a long video goes out and how many
/// weeks apart, the days the Shorts go out, the time, and how far ahead to plan. The
/// calendar shows each day in it that has nothing planned as an empty slot.
struct ReleaseRhythm: Codable, Equatable {
    /// Nil: no long-video slots.
    var longDay: Weekday? = .thursday
    /// Weeks from one long video to the next: 1 every week, 2 every other week.
    var longEvery = 2
    /// A day in a week that has a long video ("yyyy-MM-dd"). Nil counts from the latest
    /// long video planned on `longDay`.
    var longFrom: String?
    var shortDays: [Weekday] = [.tuesday, .saturday]
    /// "HH:mm", or nil for any time.
    var time: String? = "19:00"
    /// How far ahead the owner plans.
    var aheadWeeks = 8

    init(longDay: Weekday? = .thursday, longEvery: Int = 2, longFrom: String? = nil, shortDays: [Weekday] = [.tuesday, .saturday],
         time: String? = "19:00", aheadWeeks: Int = 8) {
        self.longDay = longDay; self.longEvery = longEvery; self.longFrom = longFrom
        self.shortDays = Weekday.allCases.filter(shortDays.contains); self.time = time; self.aheadWeeks = aheadWeeks
    }

    private enum CodingKeys: String, CodingKey { case longDay, longEvery, longFrom, shortDays, time, aheadWeeks }

    /// Keys left out keep their defaults, so an agent can send only what changes from them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReleaseRhythm()
        self.init(longDay: c.contains(.longDay) ? try c.decodeIfPresent(Weekday.self, forKey: .longDay) : fallback.longDay,
                  longEvery: try c.decodeIfPresent(Int.self, forKey: .longEvery) ?? fallback.longEvery,
                  longFrom: try c.decodeIfPresent(String.self, forKey: .longFrom),
                  shortDays: try c.decodeIfPresent([Weekday].self, forKey: .shortDays) ?? fallback.shortDays,
                  time: c.contains(.time) ? try c.decodeIfPresent(String.self, forKey: .time) : fallback.time,
                  aheadWeeks: try c.decodeIfPresent(Int.self, forKey: .aheadWeeks) ?? fallback.aheadWeeks)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(longDay, forKey: .longDay)
        try c.encode(longEvery, forKey: .longEvery)
        try c.encodeIfPresent(longFrom, forKey: .longFrom)
        try c.encode(shortDays, forKey: .shortDays)
        try c.encode(time, forKey: .time)
        try c.encode(aheadWeeks, forKey: .aheadWeeks)
    }

    /// The first thing wrong with it, or nil.
    var problem: String? {
        guard (1...8).contains(longEvery) else { return "A long video comes every 1 to 8 weeks." }
        if let longFrom, ReleasePlan.date(longFrom) == nil { return "longFrom is a date like 2026-10-22." }
        if let time, ReleasePlan.minutes(time) == nil { return "The rhythm's time is like 19:00 (24-hour), or left out." }
        guard (1...52).contains(aheadWeeks) else { return "Plan from 1 to 52 weeks ahead." }
        return nil
    }
}

/// A day in the rhythm with nothing of its kind planned.
struct EmptySlot: Identifiable, Equatable {
    var day: String
    var long: Bool
    var time: String?
    var id: String { day + (long ? " long" : " short") }
}

/// A release whose day has passed on a platform it is not posted on yet.
struct MissedRelease: Identifiable, Equatable {
    var release: Release
    var missing: [Platform]
    var id: String { release.id }
}

/// One week of the Schedule: its releases and empty slots, by day.
struct ScheduleWeek: Identifiable, Equatable {
    enum Entry: Identifiable, Equatable {
        case release(Release)
        case slot(EmptySlot)
        var id: String {
            switch self {
            case .release(let release): return "r " + release.id
            case .slot(let slot): return "s " + slot.id
            }
        }
        var day: String {
            switch self {
            case .release(let release): return release.day
            case .slot(let slot): return slot.day
            }
        }
    }
    /// The Monday it starts on.
    var start: String
    var entries: [Entry]
    var id: String { start }
}

extension ReleasePlan {
    /// Whole days from `today` to `day`: 1 is tomorrow, -1 yesterday.
    static func days(from today: String, to day: String) -> Int? {
        guard let a = date(today), let b = date(day) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    /// "Today", "Tomorrow", "In 3 days", "Yesterday", "4 days ago".
    static func relative(_ day: String, today: String) -> String {
        guard let gap = days(from: today, to: day) else { return day }
        switch gap {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case let n where n > 1: return "In \(n) days"
        default: return "\(-gap) days ago"
        }
    }

    /// The Monday of the week that holds `day`.
    static func weekStart(_ day: String) -> String? {
        guard let date = date(day), let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        return Self.day(start)
    }
}

extension Library {
    /// The rhythm the calendar uses: the owner's, or Style.md's default.
    var rhythmInUse: ReleaseRhythm { rhythm ?? ReleaseRhythm() }

    /// A day in a week that has a long video: the rhythm's own, or the latest long video
    /// planned on the rhythm's day.
    func longAnchor(_ rhythm: ReleaseRhythm) -> String? {
        if let from = rhythm.longFrom { return from }
        guard let longDay = rhythm.longDay else { return nil }
        return releases.filter { !$0.short && ReleasePlan.date($0.day).flatMap(Weekday.init) == longDay }.map(\.day).max()
    }

    /// The rhythm's days from `from` through `through` that still need a video. A long-video
    /// week is filled by a long video on any day of it. A week needs as many Shorts as the
    /// rhythm has Short days; its Short days with no Short are empty while it has fewer.
    func emptySlots(from: String, through: String) -> [EmptySlot] {
        let rhythm = rhythmInUse, calendar = ReleasePlan.calendar
        guard let first = ReleasePlan.date(from), let last = ReleasePlan.date(through), first <= last else { return [] }
        let all = releases
        let anchor = longAnchor(rhythm).flatMap(ReleasePlan.weekStart).flatMap(ReleasePlan.date)
            ?? ReleasePlan.weekStart(from).flatMap(ReleasePlan.date)
        var slots: [EmptySlot] = []
        var weekStart = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        while weekStart <= last {
            let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
            let keys = Set(days.map(ReleasePlan.day))
            let week = all.filter { keys.contains($0.day) }
            if let longDay = rhythm.longDay, let anchor,
               let weeks = calendar.dateComponents([.weekOfYear], from: anchor, to: weekStart).weekOfYear,
               weeks % max(1, rhythm.longEvery) == 0, !week.contains(where: { !$0.short }),
               let day = days.first(where: { Weekday($0) == longDay }), day >= first, day <= last {
                slots.append(EmptySlot(day: ReleasePlan.day(day), long: true, time: rhythm.time))
            }
            var missing = rhythm.shortDays.count - Set(week.filter(\.short).map(\.video)).count
            for day in days where missing > 0 {
                guard let weekday = Weekday(day), rhythm.shortDays.contains(weekday) else { continue }
                let key = ReleasePlan.day(day)
                guard !week.contains(where: { $0.short && $0.day == key }) else { continue }
                missing -= 1
                if day >= first && day <= last { slots.append(EmptySlot(day: key, long: false, time: rhythm.time)) }
            }
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { break }
            weekStart = next
        }
        return slots.sorted { ($0.day, $0.long ? 0 : 1) < ($1.day, $1.long ? 0 : 1) }
    }

    /// Releases before `today` still not posted on a platform they were planned for,
    /// newest first; only `idea`'s when given.
    func missed(before today: String, idea: UUID? = nil) -> [MissedRelease] {
        releases.filter { $0.day < today && (idea == nil || $0.item == idea) }.compactMap { release in
            let missing = release.platforms.filter { !release.posted.contains($0) }
            return missing.isEmpty ? nil : MissedRelease(release: release, missing: missing)
        }
        .sorted { $0.release.day > $1.release.day }
    }

    /// The last day anything is planned on, or nil.
    var lastPlannedDay: String? { releases.map(\.day).max() }

    /// The Schedule from the week of `today`: each week's releases and, with no idea
    /// chosen, the rhythm's empty slots, up to the rhythm's planning horizon or the last
    /// release, whichever is later.
    func schedule(today: String, idea: UUID? = nil) -> [ScheduleWeek] {
        guard let todayDate = ReleasePlan.date(today), let start = ReleasePlan.weekStart(today),
              let horizon = ReleasePlan.calendar.date(byAdding: .day, value: rhythmInUse.aheadWeeks * 7, to: todayDate) else { return [] }
        let last = max(ReleasePlan.day(horizon), lastPlannedDay ?? today)
        // Before today, a release is either posted (Earlier) or missed (Needs you).
        let shown = releases.filter { $0.day >= today && $0.day <= last && (idea == nil || $0.item == idea) }
        let slots = idea == nil ? emptySlots(from: today, through: last) : []
        var entries = shown.map(ScheduleWeek.Entry.release) + slots.map(ScheduleWeek.Entry.slot)
        entries.sort { a, b in
            (a.day, a.sortRank) < (b.day, b.sortRank)
        }
        var weeks: [ScheduleWeek] = []
        var week = start
        while week <= last {
            guard let date = ReleasePlan.date(week), let next = ReleasePlan.calendar.date(byAdding: .day, value: 7, to: date) else { break }
            let end = ReleasePlan.day(next)
            weeks.append(ScheduleWeek(start: week, entries: entries.filter { $0.day >= week && $0.day < end }))
            week = end
        }
        return weeks
    }
}

private extension ScheduleWeek.Entry {
    /// Long videos before Shorts, and a day's releases before its empty slots.
    var sortRank: Int {
        switch self {
        case .release(let release): return release.short ? 1 : 0
        case .slot(let slot): return slot.long ? 2 : 3
        }
    }
}
