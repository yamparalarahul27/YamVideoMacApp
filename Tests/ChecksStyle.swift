import AppKit
import Foundation

// Style.md, project notes, the history of changes and Video.md (docs/plans/distribution.md,
// section 13).

@MainActor func styleTests() async throws {
    print("Style.md: rules by section")
    let starter = StyleDoc.sections(StyleDoc.starter)
    check(starter.map(\.name) == ["Every video", "Talking head", "Screen walkthrough", "Graphics", "Shorts", "Thumbnails"]
              && starter.allSatisfy(\.rules.isEmpty), "a new Style.md has the headings and no rules")
    var text = try StyleDoc.adding("One point per Short.", to: "shorts", source: "AppStore, 15 Oct", in: StyleDoc.starter)
    text = try StyleDoc.adding("Captions never over the face.", to: "Shorts", source: nil, in: text)
    let shorts = StyleDoc.sections(text).first { $0.name == "Shorts" }
    check(shorts?.rules == ["One point per Short. *(AppStore, 15 Oct)*", "Captions never over the face."],
          "a rule goes last under its heading, whatever its case, with its source", "\(shorts?.rules ?? [])")
    check(text.contains("Captions never over the face.\n\n## Thumbnails"), "and the next heading keeps a blank line before it")
    text = try StyleDoc.adding("Plain English.", to: "Voice", source: nil, in: text)
    check(StyleDoc.sections(text).last?.name == "Voice" && StyleDoc.sections(text).last?.rules == ["Plain English."],
          "a heading that is not there yet is added at the end")
    check((try? StyleDoc.adding("One point per Short.", to: "Shorts", source: "again", in: text)) == nil, "the same rule twice is refused")
    check((try? StyleDoc.adding("Two\nlines", to: "Shorts", source: nil, in: text)) == nil, "a rule is one line")
    text = try StyleDoc.removing("One point per Short.", in: text)
    check(StyleDoc.sections(text).first { $0.name == "Shorts" }?.rules == ["Captions never over the face."],
          "a rule is removed by its words, without its source")

    let folder = scratch.appendingPathComponent("style-library", isDirectory: true)
    let model = AppModel(recoveryURL: nil)
    model.loadLibrary(from: folder)
    let file = folder.appendingPathComponent("Style.md")
    check((try? String(contentsOf: file, encoding: .utf8)) == StyleDoc.starter && model.library.style == StyleDoc.starter,
          "a Library starts its Style.md with the headings")
    model.performLibrary([.addStyleRule(section: "Shorts", rule: "Zoom out to 3:4.", source: "feedback, 15 Oct")])
    check((try? String(contentsOf: file, encoding: .utf8))?.contains("- Zoom out to 3:4. *(feedback, 15 Oct)*") == true,
          "a rule added in the app is written to Style.md")
    model.libraryUndo()
    check(model.library.style == StyleDoc.starter && (try? String(contentsOf: file, encoding: .utf8)) == StyleDoc.starter,
          "and Undo takes it out of the file again")
    model.libraryRedo()
    // The owner edits Style.md in another app.
    try await Task.sleep(nanoseconds: 1_100_000_000)
    let edited = StyleDoc.starter + "\n## Mine\n- Written in TextEdit.\n"
    try Data(edited.utf8).write(to: file)
    model.refreshStyleFromDisk()
    check(model.library.style == edited, "an edit made in another app is taken in")
    model.libraryUndo()
    check(model.library.style == edited, "and no Undo can bring back what it replaced")
    let reloaded = AppModel(recoveryURL: nil)
    reloaded.loadLibrary(from: folder)
    check(reloaded.library.style == edited, "Style.md reads back when the app opens")

    print("\nStyle.md for agents")
    let style = agentResult(await agentCall(model, ["method": "style"]))
    check(style["path"] as? String == file.path && (style["sections"] as? [[String: Any]])?.contains { $0["name"] as? String == "Mine" } == true,
          "an agent reads Style.md whole and by section")
    let added = agentResult(await agentCall(model, ["method": "libraryApply", "client": "Claude", "requestID": UUID().uuidString,
                                                    "expectedRevision": model.library.revision,
                                                    "commands": [["type": "addStyleRule", "section": "Thumbnails", "rule": "White background, the key word highlighted.",
                                                                  "source": "feedback on AppStore, 17 Oct"]]]))
    check(added["changed"] as? Bool == true && model.library.style.contains("- White background, the key word highlighted. *(feedback on AppStore, 17 Oct)*")
              && model.libraryUndoTitle.contains("Claude"),
          "an agent adds a rule with its source, credited in the Undo menu")
    let removed = agentResult(await agentCall(model, ["method": "libraryApply", "client": "Claude", "requestID": UUID().uuidString,
                                                      "expectedRevision": model.library.revision,
                                                      "commands": [["type": "removeStyleRule", "rule": "White background, the key word highlighted."]]]))
    check(removed["changed"] as? Bool == true && !model.library.style.contains("White background"), "and takes one out")

    print("\nProject notes and the history of changes")
    let editor = freshEditor()
    editor.changeLog = []
    let clip = editor.items[0].id
    editor.setPreviewFraction(0.4)
    editor.splitAtPlayhead()
    check(editor.changeLog.last?.label == "Split Section" && editor.changeLog.last?.by == "You", "every step goes into the project's history")
    let steps = editor.changeLog.count
    editor.undoEdit()
    check(editor.changeLog.count == steps + 1 && editor.changeLog.last?.label == "Undid Split Section",
          "undoing a step adds to the history instead of forgetting it")
    let noted = agentResult(await agentCall(editor, ["method": "apply", "client": "Claude", "requestID": UUID().uuidString,
                                                     "commands": [["type": "addProjectNote", "note": "Kept the story whole: it is why the app exists."]]]
                                                    .merging(address(editor)) { $1 }))
    check(noted["changed"] as? Bool == true && editor.projectNotes?.hasPrefix("- Kept the story whole: it is why the app exists. *(Claude, ") == true,
          "an agent adds a note signed with its name and the date", editor.projectNotes ?? "nil")
    _ = await agentCall(editor, ["method": "apply", "client": "Claude", "requestID": UUID().uuidString,
                                 "commands": [["type": "addProjectNote", "note": "Zoomed out to 3:4."], ["type": "addProjectNote", "note": "Captions step up."]]]
                                .merging(address(editor)) { $1 })
    check(editor.projectNotes?.components(separatedBy: "\n").count == 3, "notes added together all stay")
    let state = agentResult(await agentCall(editor, ["method": "state"]))
    let notes = state["notes"] as? [String: Any]
    check((notes?["why"] as? String)?.contains("Captions step up.") == true && (notes?["changes"] as? Int ?? 0) >= 4,
          "project state has the Why notes and the size of the history")
    let projectFile = scratch.appendingPathComponent("style-project/Talk.yamvideo")
    editor.save(to: projectFile, asCopy: false)
    let saved = try VideoProject.decodeMigrating(from: Data(contentsOf: projectFile))
    check(saved.version == VideoProject.currentVersion && saved.notes == editor.projectNotes && saved.log?.count == editor.changeLog.count,
          "a saved project keeps its notes and history (version 15)")
    var older = saved; older.version = 14
    check((try? older.validate()) == nil, "a version 14 file with notes is refused")
    editor.setPreviewFraction(0.8)
    editor.splitAtPlayhead()
    check(editor.hasUnsavedChanges, "an edit makes the project unsaved")
    editor.undoEdit()
    check(!editor.hasUnsavedChanges, "undoing back to the saved project is saved again, though the history grew")
    let history = editor.changeLog
    editor.newProject()
    check(editor.changeLog.isEmpty, "a new project starts its own history")
    editor.undoEdit()
    check(editor.changeLog.count >= history.count && editor.items.first?.id == clip, "and undoing it brings the old project's history back")
    for _ in 0..<3 { editor.logChange(.edit, origin: .human, label: "Publish Details") }
    check(editor.changeLog.filter { $0.label == "Publish Details" }.count == 1, "the same step repeated at once is one line")

    print("\nVideo.md")
    let notesFile = VideoNotes.file(forProject: projectFile)
    editor.save(to: projectFile, asCopy: false)
    let video = (try? String(contentsOf: notesFile, encoding: .utf8)) ?? ""
    check(notesFile.lastPathComponent == "Talk Video.md" && video.hasPrefix("# Talk — Video notes") && video.contains("## Why")
              && video.contains("Kept the story whole") && video.contains("## Changes, in order") && video.contains("· You · Undid Split Section"),
          "saving writes Video.md beside the project, with the Why notes and the history", String(video.prefix(300)))
    let json = scratch.appendingPathComponent("style-project/Talk.youtube.json")
    try JSONSerialization.data(withJSONObject: ["title": "Talk", "projectID": editor.projectID.uuidString]).write(to: json)
    editor.finishedExport(json, title: "Talk", origin: .agent("Claude"))
    check(editor.changeLog.last?.kind == .export && editor.changeLog.last?.by == "Claude"
              && ((try? String(contentsOf: notesFile, encoding: .utf8)) ?? "").contains("Claude · Exported Talk for YouTube"),
          "an export goes into the history and Video.md")
    let empty = VideoNotes.markdown(VideoProject(projectID: UUID(), clips: [], settings: ExportSettings(), selection: nil, movieSettings: nil),
                                    file: URL(fileURLWithPath: "/tmp/New.yamvideo"), item: nil, styleChanged: nil)
    check(empty.contains("not linked to an idea") && empty.contains("Nothing written yet") && empty.contains("No changes recorded yet"),
          "Video.md says plainly what is not there yet")
}
