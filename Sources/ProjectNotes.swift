import AppKit
import Foundation

// A project's Why notes, its history of changes, and Video.md (docs/plans/distribution.md,
// section 13): the file YamVideo writes next to a saved project at every save and export,
// so the owner and any agent can read what the video is, how it was edited and why.

extension VideoProject {
    /// The same project without its history, to tell whether anything that matters changed.
    var withoutLog: VideoProject {
        var copy = self
        copy.log = nil
        return copy
    }
}

enum VideoNotes {
    /// "AppStore.yamvideo" is described in "AppStore Video.md" beside it.
    static func file(forProject url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " Video.md")
    }

    static let changesShown = 60

    private static func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated)) }
    private static func moment(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated).hour().minute()) }

    /// Video.md for `project`, saved at `file`. `item` is the Library item it belongs to,
    /// for its idea, exports and posts.
    static func markdown(_ project: VideoProject, file: URL, item: ContentItem?, styleChanged: Date?, now: Date = Date()) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        var lines = ["# \(name) — Video notes", "",
                     "*YamVideo writes this file when the project is saved or exported. Edit the Why notes in YamVideo "
                        + "(File → Project Notes…); changes made here are replaced.*", "",
                     "- **Project:** \(file.lastPathComponent)"]
        if let item {
            lines.append("- **Idea:** \(item.title)" + (item.topic.map { " (\($0))" } ?? ""))
        } else {
            lines.append("- **Idea:** not linked to an idea in the Library")
        }
        if let styleChanged { lines.append("- **Style:** Style.md, changed \(day(styleChanged))") }
        lines.append("- **Updated:** \(moment(now))")

        let captions: String = {
            switch project.settings.captions {
            case .burnIn?: return "burned in"
            case .upload?: return "uploaded as a file"
            case .off?: return "off"
            case nil: return "as the recording's subtitle file says"
            }
        }()
        for clip in project.clips {
            let timeline = clip.timeline
            lines += ["", "## \(clip.url.lastPathComponent)"]
            if let source = clip.info?.duration {
                let cut = timeline.segments.count > 1 || abs(timeline.duration - source) > 0.05
                lines.append("- Length: " + (cut ? "\(PublishInfo.timestamp(source)) → **\(PublishInfo.timestamp(timeline.duration))** after cuts (\(timeline.segments.count) sections)"
                                                 : "\(PublishInfo.timestamp(source)), uncut"))
            }
            var extras = ["Captions \(captions)"]
            if let profile = clip.color?.inputProfile, profile != .auto { extras.append("colour \(profile.rawValue)") }
            if !clip.zoomShots.isEmpty { extras.append("\(clip.zoomShots.count) zoom\(clip.zoomShots.count == 1 ? "" : "s")") }
            if !clip.blurRegions.isEmpty { extras.append("\(clip.blurRegions.count) blurred area\(clip.blurRegions.count == 1 ? "" : "s")") }
            if let markers = clip.markers, !markers.isEmpty { extras.append("\(markers.count) marker\(markers.count == 1 ? "" : "s")") }
            if clip.screen != nil { extras.append("with a screen recording") }
            lines.append("- " + extras.joined(separator: " · "))
            if let graphics = clip.graphics, !graphics.items.isEmpty {
                let named = graphics.items.sorted { $0.start < $1.start }.compactMap { graphic -> String? in
                    let title = graphic.props["title"]?.string ?? graphic.props["name"]?.string
                    return title.map { "\($0) (\(PublishInfo.timestamp(graphic.start)))" }
                }
                lines.append("- Graphics (\(graphics.style.look.rawValue), accent \(graphics.style.accent)): "
                             + (named.isEmpty ? "\(graphics.items.count)" : named.joined(separator: " · ")))
            }
            let long = item?.video(clip.id)
            let title = clip.publish?.title.trimmingCharacters(in: .whitespaces) ?? ""
            var youtube = title.isEmpty ? "- Long video: no YouTube title yet" : "- Long video: \"\(title)\""
            if let exported = long?.exports.last { youtube += " · exported \(day(exported.exported))" }
            if let posts = long?.posts, !posts.isEmpty { youtube += " · " + posted(posts) }
            lines.append(youtube)
            if let shorts = clip.shorts, !shorts.isEmpty {
                lines += ["", "### Shorts", "", "| Short | From – to | Length | Look | Exported | Posted |", "|---|---|---|---|---|---|"]
                for (index, short) in shorts.enumerated() {
                    let piece = item?.video(short.id)
                    var look = [short.zoomLevel < 0.999 ? "zoom \(String(format: "%.2f", short.zoomLevel))" : "full frame",
                                "panels \(short.panels.rawValue)", "captions \(short.captions.rawValue)"]
                    if short.screen != .off { look.append("screen \(short.screen.rawValue)") }
                    let cells = [short.title.isEmpty ? "Short \(index + 1)" : short.title.replacingOccurrences(of: "|", with: "/"),
                                 "\(PublishInfo.timestamp(short.start)) – \(PublishInfo.timestamp(short.end))",
                                 PublishInfo.timestamp(short.length), look.joined(separator: ", "),
                                 piece?.exports.last.map { day($0.exported) } ?? "—",
                                 piece.map { posted($0.posts) }.flatMap { $0.isEmpty ? nil : $0 } ?? "—"]
                    lines.append("| " + cells.joined(separator: " | ") + " |")
                }
            }
        }

        lines += ["", "## Why", ""]
        let notes = project.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append(notes.isEmpty ? "Nothing written yet. Write why the video is edited this way in File → Project Notes…, or ask an agent to add a note." : notes)

        lines += ["", "## Changes, in order", ""]
        let log = project.log ?? []
        if log.isEmpty {
            lines.append("No changes recorded yet.")
        } else {
            if log.count > changesShown { lines.append("- … \(log.count - changesShown) earlier steps") }
            for entry in log.suffix(changesShown) { lines.append("- \(moment(entry.date)) · \(entry.by) · \(entry.label)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func posted(_ posts: [VideoPost]) -> String {
        posts.map { $0.platform.map { "on \($0.label)" } ?? "posted" }.joined(separator: ", ")
    }
}

@MainActor
extension AppModel {
    /// Adds a step to the project's history. The same step repeated by the owner within
    /// two minutes (typing a title, nudging a slider) stays one line; an agent's steps are
    /// each their own.
    func logChange(_ kind: ChangeLogEntry.Kind, origin: EditOrigin, label: String, now: Date = Date()) {
        if origin.isHuman, let last = changeLog.last, last.kind == kind, last.by == origin.label, last.label == label,
           now.timeIntervalSince(last.date) < 120 {
            changeLog[changeLog.count - 1].date = now
        } else {
            changeLog.append(ChangeLogEntry(date: now, by: origin.label, label: label, kind: kind))
        }
        if changeLog.count > ChangeLogEntry.limit { changeLog.removeFirst(changeLog.count - ChangeLogEntry.limit) }
    }

    /// Where Video.md goes for the open project, once it is saved.
    var videoNotesFile: URL? { projectURL.map(VideoNotes.file(forProject:)) }

    /// Writes Video.md beside the saved project. A failure is said, never stops a save.
    func writeVideoNotes() {
        guard let projectURL, let file = videoNotesFile else { return }
        let styleDate = styleFile.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let text = VideoNotes.markdown(project, file: projectURL, item: openProjectIdea, styleChanged: styleDate)
        do { try Data(text.utf8).write(to: file, options: .atomic) }
        catch { statusMessage = "Could not write \(file.lastPathComponent): \(error.localizedDescription)" }
    }

    /// After an export: the step goes into the history, the Library hears of it, and
    /// Video.md is brought up to date.
    func finishedExport(_ json: URL, title: String, origin: EditOrigin) {
        logChange(.export, origin: origin, label: "Exported \(title) for YouTube")
        noteExport(json, origin: origin)
        writeVideoNotes()
    }

    /// The Project Notes sheet's text, as one undo step.
    func setProjectNotes(_ text: String) {
        guard (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text) != projectNotes else { return }
        if case .failure(let error) = perform([.setNotes(text)]) { statusMessage = error.message }
    }
}
