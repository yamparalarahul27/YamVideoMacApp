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
