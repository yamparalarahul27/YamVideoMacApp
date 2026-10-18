import Foundation

// The owner's actions on the Calendar and on an idea's release tree. Every one is a Library
// change (`putVideo` with the video's plan), so it undoes with the Library and agents see
// it. See ReleaseCalendar.swift for the plans and CalendarView.swift for the views.

@MainActor
extension AppModel {
    /// A video of an item, as the Library page lists it.
    func videoRow(_ itemID: UUID, _ videoID: UUID) -> VideoRow? {
        library.item(itemID).flatMap { item in videoRows(item).first { $0.id == videoID } }
    }

    /// Sets a video's plan, or takes it away with nil, as one undo step.
    @discardableResult
    func planRelease(_ itemID: UUID, _ row: VideoRow, _ plan: ReleasePlan?) -> Result<LibraryReceipt, EditError> {
        if let problem = plan?.problem { return .failure(.invalid(problem)) }
        var piece = row.stored ?? VideoPiece(id: row.id, short: row.short, recording: row.recording, title: row.title)
        guard piece.plan != plan else { return .failure(.invalid("Nothing changed.")) }
        piece.plan = plan
        return performLibrary([.putVideo(id: itemID, video: piece)], label: plan == nil ? "Not Planned" : "Plan Release")
    }

    /// Moves what goes out on `day` to `newDay`: the video's own day, or, for a platform
    /// that has a day of its own, that platform's day. A video from the Not planned list
    /// (no `day`) gets a plan for all four platforms.
    func moveRelease(_ itemID: UUID, video videoID: UUID, from day: String?, to newDay: String) {
        guard let row = videoRow(itemID, videoID) else { return }
        guard let old = row.stored?.plan else {
            report(planRelease(itemID, row, ReleasePlan(day: newDay)))
            return
        }
        guard let day, day != newDay else { return }
        var plan = old
        var own = plan.ownDays ?? [:]
        if day == plan.day {
            plan.day = newDay
            // A platform whose own day is the new day goes out with the rest again.
            for (key, value) in own where value == newDay { own[key] = nil }
        } else {
            for platform in plan.platforms where own[platform.rawValue] == day {
                own[platform.rawValue] = newDay == plan.day ? nil : newDay
            }
        }
        plan.ownDays = own.isEmpty ? nil : own
        report(planRelease(itemID, row, plan))
    }

    /// Plans an item's Shorts that are not planned or posted yet, in the project's order:
    /// one every `every` days from `start`, at `time`, on `platforms`. One undo step.
    @discardableResult
    func planShorts(_ itemID: UUID, from start: String, every: Int, time: String?, platforms: [Platform]) -> Result<LibraryReceipt, EditError> {
        guard let item = library.item(itemID) else { return .failure(.notFound("No idea \(itemID).")) }
        let waiting = videoRows(item).filter { $0.short && $0.stored?.plan == nil && $0.posts.isEmpty }
        guard !waiting.isEmpty else { return .failure(.invalid("Every Short is planned or posted already.")) }
        let plans = ReleasePlan.spread(waiting.count, from: start, every: every, time: time, platforms: platforms)
        if let problem = plans.first?.problem { return .failure(.invalid(problem)) }
        let commands: [LibraryCommand] = zip(waiting, plans).map { row, plan in
            var piece = row.stored ?? VideoPiece(id: row.id, short: true, recording: row.recording, title: row.title)
            piece.plan = plan
            return .putVideo(id: itemID, video: piece)
        }
        return performLibrary(commands, label: "Plan Shorts")
    }

    /// Videos with no plan and no post, newest idea first; only `idea`'s when given.
    func unplannedVideos(idea: UUID? = nil) -> [(item: ContentItem, row: VideoRow)] {
        library.items.filter { idea == nil || $0.id == idea }.flatMap { item in
            videoRows(item).filter { $0.stored?.plan == nil && $0.posts.isEmpty }.map { (item, $0) }
        }
    }

    private func report(_ result: Result<LibraryReceipt, EditError>) {
        if case .failure(let error) = result, error.message != "Nothing changed." { statusMessage = error.message }
    }
}

extension Platform {
    /// The short mark the calendar shows for it.
    var mark: String {
        switch self {
        case .youtube: return "YT"
        case .instagram: return "IG"
        case .x: return "X"
        case .linkedin: return "in"
        }
    }
}
