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
    check(reread.version == 3 && reread.item(item.id)?.video(long.id)?.plan == ReleasePlan(day: "2026-10-17", platforms: [.youtube]),
          "a plan is kept in the Library file, version 3")
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
}
