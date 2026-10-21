import SwiftUI

// The Calendar module and an idea's release tree (phase 3 of docs/plans/distribution.md,
// section 15; mock-ups in docs/prototypes/release-calendar.html). A day shows what goes out
// on it: the long video and its Shorts, each with its icon, and each platform's logo,
// in colour once it is posted there. Drag a video to another day, or from Not planned
// onto a day to plan it; click one to change its plan.

/// A video dragged on the calendar: "item|video|day", the day empty from Not planned.
private func payload(_ item: UUID, _ video: UUID, _ day: String?) -> String { "\(item.uuidString)|\(video.uuidString)|\(day ?? "")" }

private func unpack(_ text: String) -> (item: UUID, video: UUID, day: String?)? {
    let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, let item = UUID(uuidString: parts[0]), let video = UUID(uuidString: parts[1]) else { return nil }
    return (item, video, parts[2].isEmpty ? nil : parts[2])
}

/// What a plan editor is open for.
struct PlanTarget: Identifiable, Equatable {
    var item: UUID
    var video: UUID
    /// The day clicked or dropped on, for a video with no plan yet.
    var day: String?
    var id: String { "\(item)\(video)" }
}

// MARK: - The page

struct CalendarView: View {
    @EnvironmentObject var model: AppModel
    enum Mode: String, CaseIterable, Identifiable { case schedule, month, week; var id: String { rawValue } }
    @State private var shown = Date()
    /// Schedule first: it says what goes out when. The last view chosen comes back.
    @AppStorage("calendarMode") private var mode = Mode.schedule
    @State private var idea: UUID?
    @State private var editing: PlanTarget?
    @State private var editingRhythm = false

    private var calendar: Calendar { ReleasePlan.calendar }
    private var days: [Date] { mode == .month ? CalendarPage.monthDays(shown) : CalendarPage.weekDays(shown) }
    private var today: String { ReleasePlan.day(Date()) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                if mode == .schedule {
                    ScheduleList(idea: idea, today: today) { editing = $0 }
                } else {
                    UpNext(idea: idea, today: today) { editing = $0 }
                    Divider()
                    grid
                }
            }
            .frame(minWidth: 640)
            notPlanned
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
        }
        .sheet(item: $editing) { target in
            PlanEditor(target: target) { editing = nil }.environmentObject(model)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            if mode != .schedule {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.help("Earlier")
                Button("Today") { shown = Date() }
                Button { step(1) } label: { Image(systemName: "chevron.right") }.help("Later")
            }
            Spacer()
            Button { editingRhythm = true } label: { Label("Rhythm", systemImage: "metronome") }
                .help("When your videos usually go out: \(model.library.rhythmInUse.summary). Days in it with nothing planned show as empty slots.")
                .popover(isPresented: $editingRhythm, arrowEdge: .bottom) {
                    RhythmEditor { editingRhythm = false }.environmentObject(model)
                }
            Picker("Show", selection: $mode) {
                Text("Schedule").tag(Mode.schedule)
                Text("Month").tag(Mode.month)
                Text("Week").tag(Mode.week)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Idea", selection: $idea) {
                Text("All ideas").tag(UUID?.none)
                ForEach(model.library.items.filter { $0.project != nil || !$0.videos.isEmpty }) { item in
                    Text(item.title).lineLimit(1).tag(UUID?.some(item.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .help("Show one idea's videos")
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var title: String {
        switch mode {
        case .schedule: return "Schedule"
        case .month: return shown.formatted(.dateTime.month(.wide).year())
        case .week:
            guard let first = days.first, let last = days.last else { return "" }
            return "\(first.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }

    private func step(_ direction: Int) {
        shown = calendar.date(byAdding: mode == .month ? .month : .weekOfYear, value: direction, to: shown) ?? shown
    }

    /// The month or week, filling the height: past days faded, today outlined, and the
    /// rhythm's empty slots from today on.
    private var grid: some View {
        let keys = days.map(ReleasePlan.day)
        let releases = model.library.releases(on: keys)
        let slots = idea == nil ? Dictionary(grouping: model.library.emptySlots(from: today, through: keys.last ?? today), by: \.day) : [:]
        let rows = max(1, days.count / 7)
        let columns = Array(repeating: GridItem(.flexible(minimum: 80), spacing: 0), count: 7)
        let todayShown = keys.contains(today)
        return GeometryReader { geo in
            let rowHeight = max(mode == .week ? 300 : 104, (geo.size.height - 24) / Double(rows))
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(Weekday.allCases) { weekday in
                            let isToday = todayShown && ReleasePlan.date(today).flatMap(Weekday.init) == weekday
                            Text(isToday ? "\(weekday.short) · today" : weekday.short)
                                .font(.caption.weight(isToday ? .bold : .regular))
                                .foregroundStyle(isToday ? Color.accentColor : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                                .frame(height: 24)
                        }
                        ForEach(days, id: \.self) { date in
                            let key = ReleasePlan.day(date)
                            DayCell(date: date, today: today,
                                    inMonth: mode == .week || calendar.isDate(date, equalTo: shown, toGranularity: .month),
                                    releases: (releases[key] ?? []).filter { idea == nil || $0.item == idea },
                                    slots: slots[key] ?? [], height: rowHeight, open: { editing = $0 })
                        }
                    }
                }
            }
        }
    }

    private var notPlanned: some View {
        let waiting = model.unplannedVideos(idea: idea)
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not planned · \(waiting.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if waiting.isEmpty {
                    Text("Every video is planned or posted.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(waiting, id: \.row.id) { entry in
                    Button { editing = PlanTarget(item: entry.item.id, video: entry.row.id, day: ReleasePlan.day(Date())) } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: entry.row.short ? "iphone" : "film").font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.row.title).font(.caption.weight(.semibold)).lineLimit(2)
                                Text("\(entry.row.short ? "Short" : "Long video") · \(entry.item.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                        .background(Color.primary.opacity(entry.row.short ? 0.06 : 0.11), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .draggable(payload(entry.item.id, entry.row.id, nil))
                    .help("Drag onto a day or an empty slot, or click to plan it")
                }
                Text("Drag a video onto a day or an empty slot to plan it for all four platforms; click it to choose.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
            }
            .padding(10)
        }
    }
}

/// Drop a video here to move it to `day`, or to plan it there from Not planned.
private struct DropDay: ViewModifier {
    @EnvironmentObject var model: AppModel
    let day: String
    @Binding var targeted: Bool
    func body(content: Content) -> some View {
        content.dropDestination(for: String.self) { texts, _ in
            guard let moved = texts.first.flatMap(unpack) else { return false }
            model.moveRelease(moved.item, video: moved.video, from: moved.day, to: day)
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct DayCell: View {
    let date: Date
    let today: String
    let inMonth: Bool
    let releases: [Release]
    let slots: [EmptySlot]
    let height: Double
    let open: (PlanTarget) -> Void
    @State private var targeted = false

    var body: some View {
        let key = ReleasePlan.day(date)
        let gap = ReleasePlan.days(from: today, to: key) ?? 0
        let isToday = gap == 0, past = gap < 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(date.formatted(.dateTime.day()))
                    .font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : inMonth ? (past ? Color.secondary : Color.primary) : Color.secondary.opacity(0.5))
                    .padding(.horizontal, isToday ? 6 : 0)
                    .background(isToday ? Color.accentColor : .clear, in: Capsule())
                Spacer(minLength: 0)
                if let tag = tag(gap) {
                    Text(tag).font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(gap == 0 || gap == 1 ? Color.accentColor : Color.secondary)
                }
            }
            ForEach(releases) { release in
                ReleaseChip(release: release, today: today)
                    .opacity(past && release.missing(today: today).isEmpty ? 0.55 : 1)
                    .onTapGesture { open(PlanTarget(item: release.item, video: release.video, day: release.day)) }
                    .draggable(payload(release.item, release.video, release.day))
            }
            ForEach(slots) { slot in SlotBox(slot: slot) }
            if isToday && releases.isEmpty && slots.isEmpty {
                Text("Nothing goes out today").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(targeted ? Color.accentColor.opacity(0.14) : isToday ? Color.accentColor.opacity(0.07)
                    : past ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textBackgroundColor))
        .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: isToday ? 2 : 0))
        .clipped()
        .modifier(DropDay(day: key, targeted: $targeted))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (isToday ? ", today" : ""))
    }

    /// Yesterday, Today and Tomorrow always; the next two weeks where something is on.
    private func tag(_ gap: Int) -> String? {
        switch gap {
        case -1, 0, 1: return ReleasePlan.relative(ReleasePlan.day(date), today: today)
        case 2...14 where !releases.isEmpty || !slots.isEmpty: return "in \(gap) days"
        default: return nil
        }
    }
}

extension Release {
    /// The platforms it is planned for and not posted on, once its day has passed.
    func missing(today: String) -> [Platform] {
        day < today ? platforms.filter { !posted.contains($0) } : []
    }
}

extension ReleaseRhythm {
    /// "a long video every other Thursday, Shorts on Tuesday and Saturday, at 19:00".
    var summary: String {
        var parts: [String] = []
        if let longDay {
            let every = longEvery == 1 ? "every" : longEvery == 2 ? "every other" : "every \(longEvery) weeks on"
            parts.append("a long video \(every) \(longDay.label)")
        }
        if !shortDays.isEmpty {
            parts.append("Shorts on " + ListFormatter.localizedString(byJoining: shortDays.map(\.label)))
        }
        if parts.isEmpty { return "no rhythm" }
        return parts.joined(separator: ", ") + (time.map { " at \($0)" } ?? "")
    }
}

/// "X and LinkedIn not posted", or "Not posted yet" when none of it is.
private func missingText(_ missing: [Platform], of release: Release) -> String {
    missing.count == release.platforms.count ? "Not posted yet"
        : ListFormatter.localizedString(byJoining: missing.map(\.label)) + " not posted"
}

/// One video on a day, on a calm chip: a long video with a film icon and its label, a
/// Short with a phone icon; the platforms' logos give the colour. A missed post says which
/// platforms are still to do, in red.
struct ReleaseChip: View {
    let release: Release
    var today = ReleasePlan.day(Date())

    var body: some View {
        let missing = release.missing(today: today)
        let past = release.day < today
        VStack(alignment: .leading, spacing: 3) {
            if release.short {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "iphone").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(release.title).font(.caption.weight(.semibold)).lineLimit(2)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "film")
                    Text("LONG VIDEO" + (release.time.map { " · \($0)" } ?? ""))
                }
                .font(.system(size: 9, weight: .heavy)).foregroundStyle(.secondary)
                Text(release.title).font(.caption.weight(.semibold)).lineLimit(2)
            }
            HStack(spacing: 4) {
                if release.short, let time = release.time { Text(time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                PlatformMarks(platforms: release.platforms, posted: release.posted, past: past)
            }
            if !missing.isEmpty {
                Label(missingText(missing, of: release), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 9.5, weight: .bold)).foregroundStyle(.red).lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(release.short ? 0.07 : 0.14), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(release.short ? 0.12 : 0.3)))
        .contentShape(Rectangle())
        .help("\(release.title) · \(release.short ? "Short" : "Long video") · click to change, drag to move")
    }
}

/// A day in the rhythm with nothing planned: drop a video on it.
private struct SlotBox: View {
    let slot: EmptySlot
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(slot.long ? "Long video" : "Short") slot" + (slot.time.map { " · \($0)" } ?? ""))
                .font(.caption2.weight(.semibold)).foregroundStyle(.primary)
            Text("Empty · drag one here").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
        .help("An empty \(slot.long ? "long video" : "Short") slot in your rhythm. Drag a video from Not planned onto it.")
    }
}

/// The platforms' logos: in colour once posted there, grey while still to come, and grey
/// with a red "!" once its day has passed without it.
struct PlatformMarks: View {
    let platforms: [Platform]
    let posted: Set<Platform>
    var past = false
    var large = false

    var body: some View {
        HStack(spacing: large ? 7 : 4) {
            ForEach(platforms) { platform in
                let done = posted.contains(platform)
                PlatformStatusLogo(platform: platform, posted: done, missed: past && !done, size: large ? 17 : 12)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Up next

/// The next few releases and empty slots, said in words, and how far ahead is planned.
private struct UpNext: View {
    @EnvironmentObject var model: AppModel
    let idea: UUID?
    let today: String
    let open: (PlanTarget) -> Void

    var body: some View {
        let entries = Array(model.library.schedule(today: today, idea: idea).flatMap(\.entries).prefix(4))
        HStack(alignment: .top, spacing: 8) {
            ForEach(entries) { entry in UpNextCard(entry: entry, today: today, open: open) }
            if entries.isEmpty {
                Text("Nothing planned from today. Drag a video from Not planned onto a day.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            AheadCard(today: today)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct UpNextCard: View {
    let entry: ScheduleWeek.Entry
    let today: String
    let open: (PlanTarget) -> Void
    @State private var targeted = false

    var body: some View {
        let day = entry.day
        let weekday = ReleasePlan.date(day).flatMap(Weekday.init)?.short ?? ""
        Group {
            switch entry {
            case .release(let release):
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ReleasePlan.relative(day, today: today)) · \(weekday)\(release.time.map { " \($0)" } ?? "")".uppercased())
                        .font(.system(size: 9.5, weight: .heavy)).foregroundStyle(day == today || ReleasePlan.days(from: today, to: day) == 1 ? Color.accentColor : .secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: release.short ? "iphone" : "film").font(.caption2)
                        Text(release.title).font(.caption.weight(.semibold)).lineLimit(2)
                    }
                    PlatformMarks(platforms: release.platforms, posted: release.posted)
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                .background(Color.primary.opacity(release.short ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(release.short ? 0.1 : 0.3)))
                .contentShape(Rectangle())
                .onTapGesture { open(PlanTarget(item: release.item, video: release.video, day: release.day)) }
            case .slot(let slot):
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ReleasePlan.relative(day, today: today)) · \(weekday)\(slot.time.map { " \($0)" } ?? "")".uppercased())
                        .font(.system(size: 9.5, weight: .heavy))
                    Text("\(slot.long ? "Long video" : "Short") slot is empty").font(.caption.weight(.semibold))
                    Text("Drag a \(slot.long ? "long video" : "Short") here from Not planned").font(.caption2).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                .background(targeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.8), style: StrokeStyle(lineWidth: 1.3, dash: [5, 3])))
                .modifier(DropDay(day: slot.day, targeted: $targeted))
            }
        }
    }
}

/// How far ahead releases are planned, against the rhythm's planning horizon.
private struct AheadCard: View {
    @EnvironmentObject var model: AppModel
    let today: String

    var body: some View {
        let weeks = model.library.rhythmInUse.aheadWeeks
        let last = model.library.lastPlannedDay.flatMap { $0 >= today ? $0 : nil }
        let ahead = last.flatMap { ReleasePlan.days(from: today, to: $0) } ?? 0
        let enough = ahead >= weeks * 7
        let goal = ReleasePlan.date(today).flatMap { ReleasePlan.calendar.date(byAdding: .day, value: weeks * 7, to: $0) }
        VStack(alignment: .leading, spacing: 4) {
            Text("PLANNED AHEAD").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(enough ? Color.green : Color.primary.opacity(0.7))
                        .frame(width: geo.size.width * min(1, Double(ahead) / Double(max(1, weeks * 7))))
                }
            }
            .frame(height: 6)
            Text(last.flatMap(ReleasePlan.date).map { "Until \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? "Nothing planned")
                .font(.caption.weight(.semibold))
            Text("Your rhythm plans \(weeks) weeks ahead" + (goal.map { ", to \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? "") + ".")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(8)
        .frame(width: 190, alignment: .topLeading)
        .frame(minHeight: 74, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Schedule

/// What goes out when, as a list: what needs you first, then this week, next week and
/// on, with the rhythm's empty slots, and what went out earlier folded away.
private struct ScheduleList: View {
    @EnvironmentObject var model: AppModel
    let idea: UUID?
    let today: String
    let open: (PlanTarget) -> Void
    @State private var showEarlier = false

    var body: some View {
        let missed = model.library.missed(before: today, idea: idea)
        let weeks = model.library.schedule(today: today, idea: idea)
        let missedIDs = Set(missed.map(\.id))
        let monthAgo = ReleasePlan.date(today).flatMap { ReleasePlan.calendar.date(byAdding: .day, value: -28, to: $0) }.map(ReleasePlan.day) ?? today
        let earlier = model.library.releases.filter { $0.day < today && $0.day >= monthAgo && !missedIDs.contains($0.id)
            && (idea == nil || $0.item == idea) }.reversed()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                if !missed.isEmpty {
                    heading("Needs you", "\(missed.count)")
                    ForEach(missed) { item in
                        ScheduleRow(entry: .release(item.release), today: today, missing: item.missing, open: open)
                    }
                }
                ForEach(weeks) { week in
                    heading(title(week), subtitle(week))
                    if week.start <= today, !week.entries.contains(where: { $0.day == today }) {
                        TodayRow(today: today)
                    }
                    if week.entries.isEmpty {
                        Text("Nothing planned").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    ForEach(week.entries) { entry in ScheduleRow(entry: entry, today: today, open: open) }
                }
                if !earlier.isEmpty {
                    DisclosureGroup(isExpanded: $showEarlier) {
                        VStack(spacing: 5) {
                            ForEach(Array(earlier)) { release in ScheduleRow(entry: .release(release), today: today, open: open) }
                        }
                        .padding(.top, 5)
                    } label: {
                        Text("Earlier · \(earlier.count) posted").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 14)
                }
                legend.padding(.top, 12)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.callout.weight(.bold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 12).padding(.bottom, 2)
    }

    private func title(_ week: ScheduleWeek) -> String {
        switch weekOffset(week) {
        case 0: return "This week"
        case 1: return "Next week"
        default: return range(week)
        }
    }

    private func subtitle(_ week: ScheduleWeek) -> String {
        let offset = weekOffset(week)
        let base = offset <= 1 ? range(week) : "in \(offset) weeks"
        // A video with a platform on another day counts once.
        let releases = week.entries.compactMap { entry -> Release? in if case .release(let r) = entry { return r } else { return nil } }
        let longs = Set(releases.filter { !$0.short }.map(\.video)).count
        let shorts = Set(releases.filter(\.short).map(\.video)).count
        let empty = week.entries.filter { if case .slot = $0 { return true } else { return false } }.count
        var parts = [base]
        if longs + shorts > 0 { parts.append([longs > 0 ? "\(longs) long" : nil, shorts > 0 ? "\(shorts) Short\(shorts == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")) }
        if empty > 0 { parts.append("\(empty) empty slot\(empty == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func weekOffset(_ week: ScheduleWeek) -> Int {
        guard let start = ReleasePlan.weekStart(today), let days = ReleasePlan.days(from: start, to: week.start) else { return 0 }
        return days / 7
    }

    private func range(_ week: ScheduleWeek) -> String {
        guard let start = ReleasePlan.date(week.start), let end = ReleasePlan.calendar.date(byAdding: .day, value: 6, to: start) else { return week.start }
        let sameMonth = ReleasePlan.calendar.isDate(start, equalTo: end, toGranularity: .month)
        return sameMonth ? "\(start.formatted(.dateTime.day()))–\(end.formatted(.dateTime.day().month(.abbreviated)))"
            : "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("Long video", systemImage: "film")
            Label("Short", systemImage: "iphone")
            HStack(spacing: 4) { PlatformMarks(platforms: [.youtube], posted: [.youtube]); Text("posted") }
            HStack(spacing: 4) { PlatformMarks(platforms: [.youtube], posted: []); Text("planned") }
            HStack(spacing: 4) { PlatformMarks(platforms: [.youtube], posted: [], past: true); Text("not posted, day passed") }
            Text("Dashed: an empty slot in your rhythm")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct TodayRow: View {
    let today: String
    var body: some View {
        HStack(spacing: 12) {
            DateBadge(day: today)
            Text("Today").font(.callout.weight(.bold)).foregroundStyle(Color.accentColor).frame(width: 96, alignment: .leading)
            Text("Nothing goes out today").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.55)))
    }
}

/// The day's number, big, and its weekday.
private struct DateBadge: View {
    let day: String
    var color = Color.primary
    var body: some View {
        let date = ReleasePlan.date(day)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(date?.formatted(.dateTime.day()) ?? day).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(date.flatMap(Weekday.init)?.short ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 62, alignment: .leading)
    }
}

/// One release or empty slot in the Schedule.
private struct ScheduleRow: View {
    @EnvironmentObject var model: AppModel
    let entry: ScheduleWeek.Entry
    let today: String
    /// For Needs you: the platforms still to post.
    var missing: [Platform] = []
    let open: (PlanTarget) -> Void
    @State private var targeted = false

    var body: some View {
        switch entry {
        case .release(let release): releaseRow(release)
        case .slot(let slot): slotRow(slot)
        }
    }

    private func releaseRow(_ release: Release) -> some View {
        let attention = !missing.isEmpty
        let isToday = release.day == today
        let tint: Color = attention ? .red : isToday || ReleasePlan.days(from: today, to: release.day) == 1 ? .accentColor : .primary
        let fill: Color = attention ? Color.red.opacity(0.08) : Color.primary.opacity(release.short ? 0.05 : 0.1)
        let edge: Color = attention ? Color.red.opacity(0.45) : Color.primary.opacity(release.short ? 0.06 : 0.28)
        let planned = model.library.item(release.item)?.video(release.video)?.plan?.platforms.count ?? release.platforms.count
        let idea = model.library.item(release.item)?.title ?? ""
        let split = release.platforms.count < planned
            ? "Only " + ListFormatter.localizedString(byJoining: release.platforms.map(\.label)) + " this day · " + idea : idea
        let detail = attention ? missingText(missing, of: release) : split
        let detailColor: Color = attention ? .red : .secondary
        return HStack(spacing: 12) {
            DateBadge(day: release.day)
            VStack(alignment: .leading, spacing: 1) {
                Text(ReleasePlan.relative(release.day, today: today)).font(.callout.weight(.bold)).foregroundStyle(tint)
                Text(release.time ?? "any time").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)
            Badge(text: release.short ? "SHORT" : "LONG VIDEO", symbol: release.short ? "iphone" : "film", long: !release.short)
            VStack(alignment: .leading, spacing: 1) {
                Text(release.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(detailColor).lineLimit(1)
            }
            Spacer(minLength: 8)
            PlatformMarks(platforms: release.platforms, posted: release.posted, past: release.day < today, large: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(fill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(edge))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture { open(PlanTarget(item: release.item, video: release.video, day: release.day)) }
        .draggable(payload(release.item, release.video, release.day))
        .modifier(DropDay(day: release.day, targeted: $targeted))
        .help(attention ? "Click to paste the post's link for each platform" : "Click to change its plan; drag it to another day")
    }

    private func slotRow(_ slot: EmptySlot) -> some View {
        HStack(spacing: 12) {
            DateBadge(day: slot.day, color: .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(ReleasePlan.relative(slot.day, today: today)).font(.callout.weight(.bold)).foregroundStyle(.secondary)
                Text(slot.time ?? "any time").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)
            Text(slot.long ? "LONG VIDEO SLOT" : "SHORT SLOT").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            VStack(alignment: .leading, spacing: 1) {
                Text("Empty").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Text("Drag a \(slot.long ? "long video" : "Short") here from Not planned").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(targeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.3, dash: [5, 3])))
        .modifier(DropDay(day: slot.day, targeted: $targeted))
    }
}

private struct Badge: View {
    let text: String
    let symbol: String
    let long: Bool
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9.5, weight: .heavy))
            .foregroundStyle(long ? Color(nsColor: .textBackgroundColor) : Color.primary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(long ? Color.primary.opacity(0.9) : Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .frame(width: 112, alignment: .leading)
    }
}

// MARK: - The rhythm

/// When the videos usually go out: the long video's day and weeks apart, the Shorts' days,
/// the time, and how far ahead to plan.
struct RhythmEditor: View {
    @EnvironmentObject var model: AppModel
    let done: () -> Void
    @State private var rhythm = ReleaseRhythm()
    @State private var timed = true
    @State private var time = Date()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Release rhythm").font(.headline)
            Text("The days your videos usually go out. A day in it with nothing planned shows as an empty slot.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Long video").foregroundStyle(.secondary)
                    HStack {
                        Picker("Long video", selection: $rhythm.longDay) {
                            Text("None").tag(Weekday?.none)
                            ForEach(Weekday.allCases) { Text($0.label).tag(Weekday?.some($0)) }
                        }
                        .labelsHidden().fixedSize()
                        Picker("Every", selection: $rhythm.longEvery) {
                            Text("every week").tag(1)
                            Text("every other week").tag(2)
                            Text("every 3 weeks").tag(3)
                            Text("every 4 weeks").tag(4)
                        }
                        .labelsHidden().fixedSize().disabled(rhythm.longDay == nil)
                    }
                }
                GridRow {
                    Text("Shorts").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(Weekday.allCases) { day in
                            let on = rhythm.shortDays.contains(day)
                            Button {
                                let days = on ? rhythm.shortDays.filter { $0 != day } : rhythm.shortDays + [day]
                                rhythm.shortDays = Weekday.allCases.filter(days.contains)
                            } label: {
                                Text(day.short).font(.callout.weight(on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.white : .primary)
                                    .frame(width: 42, height: 24)
                                    .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .help(on ? "Shorts go out on \(day.label); click to stop" : "Click to add \(day.label)")
                        }
                    }
                }
                GridRow {
                    Text("Time").foregroundStyle(.secondary)
                    HStack {
                        Toggle("at", isOn: $timed)
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().disabled(!timed)
                    }
                }
                GridRow {
                    Text("Plan ahead").foregroundStyle(.secondary)
                    Stepper("\(rhythm.aheadWeeks) weeks", value: $rhythm.aheadWeeks, in: 1...52)
                }
            }
            if rhythm.longDay != nil, rhythm.longEvery > 1 {
                Text(anchorNote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Use Default") {
                    if model.library.rhythm != nil { model.performLibrary([.setRhythm(nil)]) }
                    done()
                }
                .help("A long video every other Thursday and Shorts on Tuesday and Saturday at 19:00, eight weeks ahead")
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 470)
        .onAppear(perform: load)
    }

    private var anchorNote: String {
        guard let anchor = model.library.longAnchor(rhythm).flatMap(ReleasePlan.date) else {
            return "It counts from this week until a long video is planned."
        }
        return "It counts from the long video in the week of \(anchor.formatted(.dateTime.day().month(.abbreviated)))."
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        rhythm = model.library.rhythmInUse
        timed = rhythm.time != nil
        if let minutes = rhythm.time.flatMap(ReleasePlan.minutes) {
            time = ReleasePlan.calendar.date(byAdding: .minute, value: minutes, to: ReleasePlan.calendar.startOfDay(for: Date())) ?? Date()
        }
    }

    private func save() {
        var result = rhythm
        let parts = ReleasePlan.calendar.dateComponents([.hour, .minute], from: time)
        result.time = timed ? String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) : nil
        if result != model.library.rhythmInUse || model.library.rhythm == nil && result != ReleaseRhythm() {
            if case .failure(let error) = model.performLibrary([.setRhythm(result)]) { model.statusMessage = error.message }
        }
        done()
    }
}

// MARK: - The plan of one video

struct PlanEditor: View {
    @EnvironmentObject var model: AppModel
    let target: PlanTarget
    let done: () -> Void
    @State private var day = Date()
    @State private var timed = false
    @State private var time = Date()
    @State private var platforms = Set(Platform.allCases)
    @State private var own: [Platform: Date] = [:]
    @State private var link = ""
    @State private var loaded = false

    private var row: VideoRow? { model.videoRow(target.item, target.video) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let row {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.headline).lineLimit(2)
                    Text("\(model.library.item(target.item)?.title ?? "") · \(row.short ? "Short" : "Long video")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Day").foregroundStyle(.secondary)
                        HStack {
                            DatePicker("Day", selection: $day, displayedComponents: .date).labelsHidden()
                            Toggle("at", isOn: $timed)
                            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().disabled(!timed)
                        }
                    }
                    GridRow {
                        Text("Platforms").foregroundStyle(.secondary)
                        HStack {
                            ForEach(Platform.allCases) { platform in
                                Toggle(platform.label, isOn: Binding(get: { platforms.contains(platform) },
                                                                     set: { if $0 { platforms.insert(platform) } else { platforms.remove(platform); own[platform] = nil } }))
                            }
                        }
                    }
                    GridRow(alignment: .top) {
                        Text("Own day").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Platform.allCases.filter(platforms.contains)) { platform in
                                HStack {
                                    Toggle(platform.label, isOn: Binding(get: { own[platform] != nil },
                                                                         set: { own[platform] = $0 ? day : nil }))
                                        .frame(width: 110, alignment: .leading)
                                    if own[platform] != nil {
                                        DatePicker(platform.label, selection: Binding(get: { own[platform] ?? day }, set: { own[platform] = $0 }),
                                                   displayedComponents: .date).labelsHidden()
                                    } else {
                                        Text("the same day").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    GridRow {
                        Text("Posted").foregroundStyle(.secondary)
                        HStack {
                            TextField("Paste the post's link", text: $link).textFieldStyle(.roundedBorder).frame(width: 260)
                            Button("Mark Posted") { markPosted(row) }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if !row.posts.isEmpty {
                    HStack(spacing: 5) { ForEach(Array(row.posts.enumerated()), id: \.offset) { _, post in PostChip(post: post) } }
                }
                HStack {
                    if row.stored?.plan != nil {
                        Button("Not Planned") { if case .success = model.planRelease(target.item, row, nil) { done() } }
                    }
                    Spacer()
                    Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                    Button("Save") { save(row) }.keyboardShortcut(.defaultAction).disabled(platforms.isEmpty)
                }
            } else {
                Text("This video is no longer in the Library.").foregroundStyle(.secondary)
                Button("Close", action: done)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let row else { return }
        loaded = true
        if let plan = row.stored?.plan {
            day = ReleasePlan.date(plan.day) ?? Date()
            if let text = plan.time, let minutes = ReleasePlan.minutes(text) {
                timed = true
                time = ReleasePlan.calendar.date(byAdding: .minute, value: minutes, to: ReleasePlan.calendar.startOfDay(for: Date())) ?? Date()
            }
            platforms = Set(plan.platforms)
            for (key, value) in plan.ownDays ?? [:] {
                if let platform = Platform(rawValue: key), let date = ReleasePlan.date(value) { own[platform] = date }
            }
        } else if let given = target.day.flatMap(ReleasePlan.date) {
            day = given
        }
    }

    private var plan: ReleasePlan {
        let parts = ReleasePlan.calendar.dateComponents([.hour, .minute], from: time)
        let clock = timed ? String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) : nil
        var days: [String: String] = [:]
        for (platform, date) in own where platforms.contains(platform) && ReleasePlan.day(date) != ReleasePlan.day(day) {
            days[platform.rawValue] = ReleasePlan.day(date)
        }
        return ReleasePlan(day: ReleasePlan.day(day), time: clock, platforms: Array(platforms), ownDays: days)
    }

    private func save(_ row: VideoRow) {
        switch model.planRelease(target.item, row, plan) {
        case .success: done()
        case .failure(let error): if error.message == "Nothing changed." { done() } else { model.statusMessage = error.message }
        }
    }

    private func markPosted(_ row: VideoRow) {
        if case .failure(let error) = model.addPost(target.item, row, link: link) { model.statusMessage = error.message } else { link = "" }
    }
}

// MARK: - An idea's release tree

/// The long video on the left, a branch to each of its Shorts, and for each one its day,
/// its platforms and where it stands. Click one to change its plan.
struct ReleaseTreeSection: View {
    @EnvironmentObject var model: AppModel
    let item: ContentItem
    @State private var editing: PlanTarget?
    @State private var spreading = false

    var body: some View {
        let rows = model.videoRows(item)
        let long = rows.filter { !$0.short }, shorts = rows.filter(\.short).sorted(by: order)
        InspectorSection("Release plan") {
            if rows.isEmpty {
                Text("No videos yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) { ForEach(long) { row in node(row, long: true) } }
                        .frame(width: 230)
                    if !shorts.isEmpty {
                        Branches(count: shorts.count).frame(width: 34)
                        VStack(alignment: .leading, spacing: 6) { ForEach(shorts) { row in node(row, long: false) } }
                    }
                }
                HStack {
                    Button("Plan All Shorts…") { spreading = true }
                        .disabled(!shorts.contains { $0.stored?.plan == nil && $0.posts.isEmpty })
                        .help("One Short every few days, from a day you choose")
                    Button("Open in Calendar") { model.showModule(.calendar) }
                }
                .controlSize(.small)
            }
        }
        .sheet(item: $editing) { target in PlanEditor(target: target) { editing = nil }.environmentObject(model) }
        .sheet(isPresented: $spreading) { SpreadShortsSheet(item: item) { spreading = false }.environmentObject(model) }
    }

    /// Planned first, by day, then the rest in the project's order.
    private func order(_ a: VideoRow, _ b: VideoRow) -> Bool {
        switch (a.stored?.plan?.day, b.stored?.plan?.day) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        default: return false
        }
    }

    private func node(_ row: VideoRow, long: Bool) -> some View {
        let tint = Color.primary
        let plan = row.stored?.plan
        let posted = Set(row.posts.compactMap(\.platform))
        return Button { editing = PlanTarget(item: item.id, video: row.id, day: plan?.day) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.caption.weight(.semibold)).lineLimit(2)
                    Text(long ? "Long video" : "Short").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    if let plan {
                        Text(dayText(plan)).font(.caption2.monospacedDigit())
                        PlatformMarks(platforms: plan.platforms, posted: posted, past: plan.day < ReleasePlan.day(Date()))
                    } else if !row.posts.isEmpty {
                        Text("Posted").font(.caption2).foregroundStyle(.green)
                    } else {
                        Text("Not planned").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(long ? 0.35 : 0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to plan when and where it goes out")
    }

    private func dayText(_ plan: ReleasePlan) -> String {
        let date = ReleasePlan.date(plan.day)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? plan.day
        return plan.time.map { "\(date) · \($0)" } ?? date
    }
}

/// The lines from the long video to each Short.
private struct Branches: View {
    let count: Int
    var body: some View {
        Canvas { context, size in
            guard count > 0 else { return }
            let start = CGPoint(x: 0, y: size.height / 2)
            for index in 0..<count {
                let y = size.height * (CGFloat(index) + 0.5) / CGFloat(count)
                var path = Path()
                path.move(to: start)
                path.addCurve(to: CGPoint(x: size.width, y: y), control1: CGPoint(x: size.width / 2, y: start.y),
                              control2: CGPoint(x: size.width / 2, y: y))
                context.stroke(path, with: .color(.secondary.opacity(0.5)), lineWidth: 1.2)
            }
        }
    }
}

/// Plan All Shorts: one Short every few days from a day, at a time, on the platforms.
private struct SpreadShortsSheet: View {
    @EnvironmentObject var model: AppModel
    let item: ContentItem
    let done: () -> Void
    @State private var start = Date()
    @State private var every = 2
    @State private var timed = false
    @State private var time = Date()
    @State private var platforms = Set(Platform.allCases)

    var body: some View {
        let waiting = model.videoRows(item).filter { $0.short && $0.stored?.plan == nil && $0.posts.isEmpty }.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan \(waiting) Short\(waiting == 1 ? "" : "s")").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("From").foregroundStyle(.secondary)
                    DatePicker("From", selection: $start, displayedComponents: .date).labelsHidden()
                }
                GridRow {
                    Text("Every").foregroundStyle(.secondary)
                    Stepper(every == 1 ? "day" : "\(every) days", value: $every, in: 1...14)
                }
                GridRow {
                    Text("Time").foregroundStyle(.secondary)
                    HStack {
                        Toggle("at", isOn: $timed)
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().disabled(!timed)
                    }
                }
                GridRow {
                    Text("Platforms").foregroundStyle(.secondary)
                    HStack {
                        ForEach(Platform.allCases) { platform in
                            Toggle(platform.label, isOn: Binding(get: { platforms.contains(platform) },
                                                                 set: { if $0 { platforms.insert(platform) } else { platforms.remove(platform) } }))
                        }
                    }
                }
            }
            Text("The Shorts that are not planned or posted go out in the project's order.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Plan") {
                    let parts = ReleasePlan.calendar.dateComponents([.hour, .minute], from: time)
                    let clock = timed ? String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) : nil
                    switch model.planShorts(item.id, from: ReleasePlan.day(start), every: every, time: clock, platforms: Array(platforms)) {
                    case .success: done()
                    case .failure(let error): model.statusMessage = error.message
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(platforms.isEmpty || waiting == 0)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
