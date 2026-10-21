// Checks for the release calendar. Run with ./test.sh calendar
import AppKit
import Foundation

@MainActor func calendarTests() async throws {
    print("Release plans: their rules and days")
    check(ReleasePlan(day: "2026-10-19").problem == nil && ReleasePlan(day: "2026-10-19").platforms == Platform.allCases,
          "a plan is one day, for all four platforms unless it says fewer")
    check(ReleasePlan(day: "2026-02-30").problem?.contains("2026-10-19") == true && ReleasePlan(day: "19 Oct").problem != nil
              && ReleasePlan(day: "2026-10-19", time: "25:00").problem?.contains("19:00") == true
              && ReleasePlan(day: "2026-10-19", platforms: []).problem?.contains("at least one") == true
              && ReleasePlan(day: "2026-10-19", platforms: [.youtube], ownDays: ["linkedin": "2026-10-20"]).problem?.contains("linkedin") == true,
          "a day that is not a date, a time that is not one, no platform, or an own day for a platform it does not go to is refused")
    let planned = ReleasePlan(day: "2026-10-23", time: "19:00", platforms: [.linkedin, .youtube], ownDays: ["linkedin": "2026-10-24"])
    check(planned.platforms == [.youtube, .linkedin] && planned.day(for: .linkedin) == "2026-10-24" && planned.day(for: .youtube) == "2026-10-23",
          "platforms keep their own order, and one can go out on its own day")
    let month = CalendarPage.monthDays(ReleasePlan.date("2026-10-18")!)
    check(month.count == 35 && ReleasePlan.day(month.first!) == "2026-09-28" && ReleasePlan.day(month.last!) == "2026-11-01",
          "October 2026 shows five weeks from Monday 28 September", "\(month.count) \(month.first.map(ReleasePlan.day) ?? "")")
    check(CalendarPage.weekDays(ReleasePlan.date("2026-10-18")!).map(ReleasePlan.day) == (12...18).map { "2026-10-\($0)" },
          "a week runs from Monday")
    check(ReleasePlan.spread(3, from: "2026-10-30", every: 2, time: nil, platforms: [.youtube]).map(\.day) == ["2026-10-30", "2026-11-01", "2026-11-03"],
          "a spread runs one every few days, across a month's end")

    print("\nPlans in the Library")
    let model = AppModel(recoveryURL: nil)
    model.loadLibrary(from: scratch.appendingPathComponent("calendar-library", isDirectory: true))
    let long = VideoPiece(id: UUID(), short: false, title: "Part 1")
    let shorts = (1...3).map { VideoPiece(id: UUID(), short: true, title: "Short \($0)") }
    let item = ContentItem(title: "System design", videos: [long] + shorts)
    model.performLibrary([.addIdea(item)])
    func row(_ id: UUID) -> VideoRow { model.videoRow(item.id, id)! }
    check(model.unplannedVideos().count == 4 && model.library.item(item.id)?.stage == .idea, "every video waits in Not planned")

    model.planRelease(item.id, row(long.id), ReleasePlan(day: "2026-10-17", platforms: [.youtube]))
    check(model.library.item(item.id)?.stage == .scheduled && model.libraryUndoTitle == "Undo Plan Release",
          "a planned release makes the item Scheduled, as one undo step")
    model.addPost(item.id, row(long.id), link: "https://youtu.be/abc")
    let reread = try Library.decode(model.library.encoded())
    check(reread.version == Library.currentVersion && reread.item(item.id)?.video(long.id)?.plan == ReleasePlan(day: "2026-10-17", platforms: [.youtube]),
          "a plan is kept in the Library file")
    var older = model.library; older.version = Library.currentVersion + 1
    check((try? Library.decode(older.encoded())) == nil, "an older YamVideo refuses it rather than drop the plans")

    if case .failure(let error) = model.planShorts(item.id, from: "2026-10-19", every: 2, time: "19:00", platforms: Platform.allCases) {
        check(false, "the Shorts can be spread", error.message)
    }
    check(shorts.map { row($0.id).stored?.plan?.day } == ["2026-10-19", "2026-10-21", "2026-10-23"] && model.unplannedVideos().isEmpty
              && model.libraryUndoTitle == "Undo Plan Shorts",
          "Plan All Shorts spreads them one every two days, as one undo step")
    let days = model.library.releases.map { "\($0.day) \($0.title) \($0.platforms.map(\.mark).joined()) \($0.posted.map(\.mark).joined())" }
    check(days == ["2026-10-17 Part 1 YT YT", "2026-10-19 Short 1 YTIGXin ", "2026-10-21 Short 2 YTIGXin ", "2026-10-23 Short 3 YTIGXin "],
          "the calendar lists each release by day, with its platforms and where it is posted", "\(days)")

    model.moveRelease(item.id, video: shorts[2].id, from: "2026-10-23", to: "2026-10-25")
    check(row(shorts[2].id).stored?.plan?.day == "2026-10-25" && row(shorts[2].id).stored?.plan?.time == "19:00",
          "dragging a release to another day moves it and keeps its time and platforms")
    var own = row(shorts[1].id).stored!.plan!
    own.ownDays = ["linkedin": "2026-10-22"]
    model.planRelease(item.id, row(shorts[1].id), own)
    let split = model.library.releases.filter { $0.video == shorts[1].id }
    check(split.map(\.day) == ["2026-10-21", "2026-10-22"] && split[1].platforms == [.linkedin],
          "a platform with its own day shows on that day by itself")
    model.moveRelease(item.id, video: shorts[1].id, from: "2026-10-22", to: "2026-10-21")
    check(row(shorts[1].id).stored?.plan?.ownDays == nil, "dragged back to the video's day, it goes out with the rest again")
    model.planRelease(item.id, row(shorts[0].id), nil)
    model.moveRelease(item.id, video: shorts[0].id, from: nil, to: "2026-10-20")
    check(row(shorts[0].id).stored?.plan == ReleasePlan(day: "2026-10-20"), "dropped from Not planned onto a day, it goes out there on all four")

    print("\nPlans for agents")
    func apply(_ commands: [[String: Any]]) async -> [String: Any] {
        await agentCall(model, ["method": "libraryApply", "client": "Claude", "requestID": UUID().uuidString,
                                "expectedRevision": model.library.revision, "commands": commands])
    }
    let reply = await apply([["type": "planRelease", "ideaID": item.id.uuidString, "videoID": shorts[0].id.uuidString,
                              "day": "2026-10-26", "clock": "18:30", "platforms": ["youtube", "instagram"]]])
    check(reply["ok"] as? Bool == true && row(shorts[0].id).stored?.plan == ReleasePlan(day: "2026-10-26", time: "18:30", platforms: [.youtube, .instagram]),
          "an agent plans a release as the owner says it", "\(reply)")
    equal(agentError(await apply([["type": "planRelease", "ideaID": item.id.uuidString, "videoID": shorts[0].id.uuidString,
                                   "day": "2026-10-26", "platforms": ["tiktok"]]])), "invalid_command", "an unknown platform is refused")
    equal(agentError(await apply([["type": "planRelease", "ideaID": item.id.uuidString, "videoID": shorts[0].id.uuidString]])), "invalid_request",
          "a plan needs its day")
    let state = agentResult(await agentCall(model, ["method": "library"]))
    let video = ((state["ideas"] as? [[String: Any]])?.first?["videos"] as? [[String: Any]])?.first { $0["id"] as? String == shorts[0].id.uuidString }
    check((video?["plan"] as? [String: Any])?["day"] as? String == "2026-10-26", "the library state shows each video's plan")
    _ = await apply([["type": "unplanRelease", "ideaID": item.id.uuidString, "videoID": shorts[0].id.uuidString]])
    check(row(shorts[0].id).stored?.plan == nil && model.unplannedVideos().count == 1, "unplanRelease puts it back in Not planned")

    let manual = (try? String(contentsOf: URL(fileURLWithPath: repository).appendingPathComponent("Resources/AgentsManual.md"), encoding: .utf8)) ?? ""
    check(manual.contains("### 4.16 Study new footage and plan the edit") && manual.contains("Files/Plan.md")
              && manual.contains("### 4.17 Plan the releases") && manual.contains("Plan at least two"),
          "the Agents Manual has the study-and-plan and release-planning recipes")
    check(manual.contains("setRhythm") && manual.contains("library.calendar"), "and says how agents read the slots and set the rhythm")

    try await rhythmTests()
}

/// The rhythm, its empty slots, missed posts and the Schedule: what lets the owner see
/// what goes out when at a glance.
@MainActor private func rhythmTests() async throws {
    print("\nThe rhythm and the Schedule")
    func plan(_ day: String, _ platforms: [Platform] = Platform.allCases, own: [String: String]? = nil) -> ReleasePlan {
        ReleasePlan(day: day, time: "19:00", platforms: platforms, ownDays: own)
    }
    let part1 = VideoPiece(id: UUID(), short: false, title: "Part 1", posts: [VideoPost(link: "https://youtu.be/p1")], plan: plan("2026-10-08"))
    let part2 = VideoPiece(id: UUID(), short: false, title: "Part 2", plan: plan("2026-10-22"))
    let posted = VideoPiece(id: UUID(), short: true, title: "Posted", posts: [VideoPost(link: "https://youtube.com/shorts/a"),
                                                                              VideoPost(link: "https://www.instagram.com/reel/a/")],
                            plan: plan("2026-10-17"))
    let saturday = VideoPiece(id: UUID(), short: true, title: "Saturday", plan: plan("2026-10-24"))
    let sahi = VideoPiece(id: UUID(), short: false, title: "Sahi", plan: plan("2026-11-05", own: ["linkedin": "2026-11-06"]))
    let wednesday = VideoPiece(id: UUID(), short: true, title: "Wednesday", plan: plan("2026-11-04"))
    let idea = ContentItem(title: "Rhythm", videos: [part1, part2, posted, saturday, sahi, wednesday])
    var library = Library(items: [idea])

    let rhythm = library.rhythmInUse
    check(rhythm.longDay == .thursday && rhythm.longEvery == 2 && rhythm.shortDays == [.tuesday, .saturday] && rhythm.time == "19:00"
              && rhythm.aheadWeeks == 8 && library.rhythm == nil,
          "with none set, the rhythm is Style.md's: a long video every other Thursday, Shorts on Tuesday and Saturday at 19:00")
    equal(library.longAnchor(rhythm), "2026-11-05", "every other week counts from the latest long video on a Thursday")
    let slots = library.emptySlots(from: "2026-10-21", through: "2026-11-22").map { "\($0.day) \($0.long ? "long" : "short")" }
    equal(slots, ["2026-10-27 short", "2026-10-31 short", "2026-11-03 short", "2026-11-10 short", "2026-11-14 short",
                  "2026-11-17 short", "2026-11-19 long", "2026-11-21 short"],
          "empty slots: Short days without a Short, and every other Thursday without a long video")
    check(!slots.contains("2026-11-07 short") && !slots.contains("2026-10-29 long") && !slots.contains("2026-11-12 long"),
          "a Short on another day of the week fills one of its slots, and off weeks have no long-video slot")
    equal(library.emptySlots(from: "2026-11-01", through: "2026-10-01"), [], "an empty range has no slots")

    library.rhythm = ReleaseRhythm(longDay: .monday, longEvery: 1, shortDays: [.friday], time: nil)
    let weekly = library.emptySlots(from: "2026-11-09", through: "2026-11-15")
    check(weekly.map(\.day) == ["2026-11-09", "2026-11-13"] && weekly.first?.long == true && weekly.allSatisfy { $0.time == nil },
          "the owner's own rhythm: a long video every Monday, a Short every Friday, any time")
    library.rhythm = ReleaseRhythm(longDay: nil, shortDays: [])
    equal(library.emptySlots(from: "2026-11-09", through: "2026-11-15"), [], "no days in the rhythm, no slots")
    library.rhythm = nil

    let missed = library.missed(before: "2026-10-21")
    check(missed.count == 2 && missed[0].release.title == "Posted" && missed[0].missing == [.x, .linkedin]
              && missed[1].release.title == "Part 1" && missed[1].missing == [.instagram, .x, .linkedin],
          "a past release not posted on a platform it was planned for needs the owner, newest first", "\(missed.map(\.release.title))")
    equal(library.missed(before: "2026-10-08").count, 0, "nothing is missed before its day has passed")

    check(ReleasePlan.relative("2026-10-21", today: "2026-10-21") == "Today" && ReleasePlan.relative("2026-10-22", today: "2026-10-21") == "Tomorrow"
              && ReleasePlan.relative("2026-10-20", today: "2026-10-21") == "Yesterday" && ReleasePlan.relative("2026-10-27", today: "2026-10-21") == "In 6 days"
              && ReleasePlan.relative("2026-10-17", today: "2026-10-21") == "4 days ago" && ReleasePlan.relative("2026-11-02", today: "2026-10-31") == "In 2 days",
          "a day is said in words: Today, Tomorrow, In 6 days, 4 days ago, across a month's end")
    equal(ReleasePlan.weekStart("2026-10-25"), "2026-10-19", "a week starts on Monday")

    let weeks = library.schedule(today: "2026-10-21")
    check(weeks.first?.start == "2026-10-19" && weeks.count == 9, "the Schedule runs from this week to eight weeks ahead", "\(weeks.count)")
    let first = weeks[0].entries.map(\.id)
    check(first.count == 2 && weeks[0].entries.allSatisfy { $0.day >= "2026-10-21" },
          "this week starts from today: what went out before is posted or needs the owner")
    let novemberWeek = weeks.first { $0.start == "2026-11-02" }?.entries ?? []
    check(novemberWeek.map(\.day) == ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"],
          "a week lists its days in order, with the empty slots among the releases", "\(novemberWeek.map(\.day))")
    let ideaOnly = library.schedule(today: "2026-10-21", idea: idea.id).flatMap(\.entries)
    check(!ideaOnly.contains { if case .slot = $0 { return true } else { return false } }, "one idea's Schedule has no channel slots")

    print("\nThe rhythm in the Library")
    let model = AppModel(recoveryURL: nil)
    model.loadLibrary(from: scratch.appendingPathComponent("rhythm-library", isDirectory: true))
    model.performLibrary([.addIdea(idea)])
    let mine = ReleaseRhythm(longDay: .wednesday, longEvery: 1, longFrom: "2026-10-07", shortDays: [.friday], time: "18:00", aheadWeeks: 4)
    model.performLibrary([.setRhythm(mine)])
    check(model.library.rhythm == mine && model.libraryUndoTitle == "Undo Release Rhythm", "the owner sets the rhythm, as one undo step")
    model.libraryUndo()
    check(model.library.rhythm == nil, "undo takes it back to the default")
    model.libraryRedo()
    check(model.library.rhythm == mine, "and redo sets it again")
    let saved = try Library.decode(model.library.encoded())
    check(saved.version == 4 && saved.rhythm == mine, "the rhythm is kept in the Library file, version 4")
    if case .success = model.performLibrary([.setRhythm(ReleaseRhythm(longEvery: 0))]) { check(false, "a long video every 0 weeks is refused") }
    if case .success = model.performLibrary([.setRhythm(ReleaseRhythm(time: "7pm"))]) { check(false, "a time like 7pm is refused") }
    check(model.library.rhythm == mine, "a rhythm that is not valid is refused and changes nothing")

    func apply(_ commands: [[String: Any]]) async -> [String: Any] {
        await agentCall(model, ["method": "libraryApply", "client": "Claude", "requestID": UUID().uuidString,
                                "expectedRevision": model.library.revision, "commands": commands])
    }
    let reply = await apply([["type": "setRhythm", "rhythm": ["shortDays": ["monday", "thursday"], "aheadWeeks": 6]]])
    check(reply["ok"] as? Bool == true && model.library.rhythm == ReleaseRhythm(shortDays: [.monday, .thursday], aheadWeeks: 6),
          "an agent sets the rhythm; what it leaves out takes the default", "\(reply)")
    equal(agentError(await apply([["type": "setRhythm", "rhythm": ["longEvery": 9]]])), "invalid_command", "and a rhythm out of range is refused")
    let calendar = agentResult(await agentCall(model, ["method": "library"]))["calendar"] as? [String: Any] ?? [:]
    check(calendar["rhythmSet"] as? Bool == true && (calendar["rhythm"] as? [String: Any])?["longDay"] as? String == "thursday"
              && calendar["emptySlots"] is [Any] && calendar["missed"] is [Any] && calendar["today"] as? String == ReleasePlan.day(Date()),
          "the library state gives agents the rhythm, the empty slots and the missed posts")
    _ = await apply([["type": "setRhythm"]])
    check(model.library.rhythm == nil, "setRhythm with no rhythm goes back to the default")
    check(AgentCatalog.current.libraryCommands.contains { $0.type == "setRhythm" } && LibraryWireCommand.types.contains("setRhythm"),
          "the catalog lists setRhythm")
}
