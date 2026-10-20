import SwiftUI

// The Calendar module and an idea's release tree (phase 3 of docs/plans/distribution.md,
// section 15; mock-ups in docs/prototypes/release-calendar.html). A day shows what goes out
// on it: the long video in purple, Shorts in the accent colour, and a mark for each
// platform, filled once it is posted. Drag a video to another day, or from Not planned
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
    enum Mode: String, CaseIterable, Identifiable { case month, week; var id: String { rawValue } }
    @State private var shown = Date()
    @State private var mode = Mode.month
    @State private var idea: UUID?
    @State private var editing: PlanTarget?

    private var calendar: Calendar { ReleasePlan.calendar }
    private var days: [Date] { mode == .month ? CalendarPage.monthDays(shown) : CalendarPage.weekDays(shown) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                grid
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
            Button { step(-1) } label: { Image(systemName: "chevron.left") }.help("Earlier")
            Button("Today") { shown = Date() }
            Button { step(1) } label: { Image(systemName: "chevron.right") }.help("Later")
            Spacer()
            Picker("Show", selection: $mode) {
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
            .frame(maxWidth: 240)
            .help("Show one idea's videos")
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var title: String {
        if mode == .month { return shown.formatted(.dateTime.month(.wide).year()) }
        guard let first = days.first, let last = days.last else { return "" }
        return "\(first.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private func step(_ direction: Int) {
        shown = calendar.date(byAdding: mode == .month ? .month : .weekOfYear, value: direction, to: shown) ?? shown
    }

    private var grid: some View {
        let keys = days.map(ReleasePlan.day)
        let releases = model.library.releases(on: keys)
        let columns = Array(repeating: GridItem(.flexible(minimum: 80), spacing: 0), count: 7)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { name in
                    Text(name).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 4)
                }
                ForEach(days, id: \.self) { date in
                    let key = ReleasePlan.day(date)
                    DayCell(date: date, inMonth: mode == .week || calendar.isDate(date, equalTo: shown, toGranularity: .month),
                            releases: (releases[key] ?? []).filter { idea == nil || $0.item == idea },
                            tall: mode == .week, open: { editing = $0 })
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.row.title).font(.caption.weight(.semibold)).lineLimit(2)
                            Text("\(entry.item.title) · \(entry.row.short ? "Short" : "Long video")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background((entry.row.short ? Color.accentColor : Color.purple).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .draggable(payload(entry.item.id, entry.row.id, nil))
                    .help("Drag onto a day, or click to plan it")
                }
                Text("Drag a video onto a day to plan it for all four platforms; click it to choose.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
            }
            .padding(10)
        }
    }
}

private struct DayCell: View {
    @EnvironmentObject var model: AppModel
    let date: Date
    let inMonth: Bool
    let releases: [Release]
    let tall: Bool
    let open: (PlanTarget) -> Void
    @State private var targeted = false

    var body: some View {
        let key = ReleasePlan.day(date)
        let today = ReleasePlan.calendar.isDateInToday(date)
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(.dateTime.day()))
                .font(.caption.weight(today ? .bold : .regular))
                .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                .padding(.horizontal, today ? 6 : 0)
                .background(today ? Color.accentColor : .clear, in: Capsule())
            ForEach(releases) { release in
                ReleaseChip(release: release)
                    .onTapGesture { open(PlanTarget(item: release.item, video: release.video, day: release.day)) }
                    .draggable(payload(release.item, release.video, release.day))
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: tall ? 360 : 104, alignment: .topLeading)
        .background(targeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .textBackgroundColor))
        .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .dropDestination(for: String.self) { texts, _ in
            guard let moved = texts.first.flatMap(unpack) else { return false }
            model.moveRelease(moved.item, video: moved.video, from: moved.day, to: key)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
    }
}

/// One video on a day: its title, its time, and a mark for each platform.
struct ReleaseChip: View {
    let release: Release

    var body: some View {
        let tint = release.short ? Color.accentColor : Color.purple
        VStack(alignment: .leading, spacing: 2) {
            Text(release.title).font(.caption.weight(.semibold)).lineLimit(1)
            HStack(spacing: 3) {
                if let time = release.time { Text(time).font(.caption2.monospacedDigit()) }
                PlatformMarks(platforms: release.platforms, posted: release.posted, tint: tint)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .help("\(release.title) · \(release.short ? "Short" : "Long video") · click to change, drag to move")
    }
}

/// YT IG X in: outlined while planned, filled once posted there.
struct PlatformMarks: View {
    let platforms: [Platform]
    let posted: Set<Platform>
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(platforms) { platform in
                let done = posted.contains(platform)
                Text(platform.mark)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(done ? Color(nsColor: .textBackgroundColor) : tint)
                    .padding(.horizontal, 3).padding(.vertical, 0.5)
                    .background(done ? tint : .clear, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(0.8), lineWidth: 0.8))
                    .help("\(platform.label)\(done ? ": posted" : "")")
            }
        }
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
        let tint = long ? Color.purple : Color.accentColor
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
                        PlatformMarks(platforms: plan.platforms, posted: posted, tint: tint)
                    } else if !row.posts.isEmpty {
                        Text("Posted").font(.caption2).foregroundStyle(.green)
                    } else {
                        Text("Not planned").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(long ? 0.6 : 0.25)))
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
