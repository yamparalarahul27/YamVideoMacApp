import AppKit
import Foundation

// The Library and the Ideas page (docs/plans/distribution.md, phase 1): ideas, their rules
// and file, undo, images, the link to a project, and the same for agents.

/// A small PNG to add to ideas.
func ideaImage(_ name: String) throws -> URL {
    let url = scratch.appendingPathComponent(name)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

@MainActor func libraryTests() async throws {
    print("The Library: ideas, their rules and their file")
    let folder = scratch.appendingPathComponent("library", isDirectory: true)
    let file = folder.appendingPathComponent("Library.json")
    let model = AppModel(recoveryURL: nil)
    model.loadLibrary(from: folder)
    check(model.library.items.isEmpty && !FileManager.default.fileExists(atPath: file.path),
          "a new Library starts empty and writes nothing until it changes")

    let first = ContentItem(title: "How I edit with Claude", notes: "Hook", topic: "AI workflow", links: ["youtube.com/watch?v=abc"])
    guard case .success(let added) = model.performLibrary([.addIdea(first)]) else { check(false, "an idea can be added"); return }
    check(added.createdIDs == [first.id] && added.revision == 1 && model.library.items.first?.links == ["https://youtube.com/watch?v=abc"],
          "an idea is added, and a bare web address gets https://")
    equal(try Library.decode(Data(contentsOf: file)), model.library, "the Library is written to its file after a change")
    equal(model.library.items.first?.stage, .idea, "an idea without a project is at the Idea stage")

    let second = ContentItem(title: "Pocket 3 colour in five minutes", topic: "ai WORKFLOW")
    model.performLibrary([.addIdea(second)])
    equal(model.library.items.map(\.id), [second.id, first.id], "a new idea goes to the top")
    equal(model.library.item(second.id)?.topic, "AI workflow", "a topic differing only in case takes the existing spelling")
    equal(model.library.topics, ["AI workflow"], "and the topics are listed once each")

    func refused(_ commands: [LibraryCommand]) -> EditError.Code? {
        if case .failure(let error) = model.performLibrary(commands) { return error.code }
        return nil
    }
    equal(refused([.updateIdea(id: first.id, title: "   ", notes: nil, topic: nil, links: nil)]), .invalidCommand, "an idea keeps a title")
    equal(refused([.updateIdea(id: first.id, title: "Two\nlines", notes: nil, topic: nil, links: nil)]), .invalidCommand, "a title is one line")
    equal(refused([.updateIdea(id: first.id, title: nil, notes: nil, topic: nil, links: ["ftp://example.com/x"])]), .invalidCommand,
          "links are web links")
    equal(refused([.addIdea(ContentItem(id: first.id, title: "Again"))]), .invalidCommand, "two ideas cannot share an ID")
    equal(refused([.removeIdea(id: UUID())]), .notFound, "an unknown idea is not found")
    let revision = model.library.revision
    equal(refused([.addIdea(ContentItem(title: "Fine")), .removeIdea(id: UUID())]), .notFound, "a batch is all or nothing")
    check(model.library.revision == revision && model.library.items.count == 2, "so a refused batch changes nothing")
    var newer = model.library; newer.version = Library.currentVersion + 1
    check((try? Library.decode(newer.encoded())) == nil, "a Library from a newer YamVideo is refused, not half read")

    print("\nUndo, typing and topics")
    model.editIdea(first.id, notes: "Hook: one")
    model.editIdea(first.id, notes: "Hook: one recording")
    equal(model.libraryUndoTitle, "Undo Edit Notes", "the Undo menu names the Library step")
    model.libraryUndo()
    equal(model.library.item(first.id)?.notes, "Hook", "typing in the notes is one undo step")
    model.libraryRedo()
    equal(model.library.item(first.id)?.notes, "Hook: one recording", "and redo brings it back")
    model.editIdea(second.id, topic: .some(nil))
    check(model.library.item(second.id)?.topic == nil, "a topic can be cleared")
    model.deleteIdea(second.id)
    check(model.library.item(second.id) == nil && model.selectedIdeaID == first.id, "deleting an idea selects the next one")
    model.libraryUndo()
    check(model.library.item(second.id) != nil, "and undo brings it back")
    model.module = .ideas
    equal(model.menuUndoTitle, model.libraryUndoTitle, "on the Ideas page, the Edit menu undoes the Library")
    model.module = .studio
    equal(model.menuUndoTitle, model.undoTitle, "in Studio, it undoes the project")

    print("\nImages")
    let png = try ideaImage("idea-reference.png")
    if case .failure(let error) = model.addIdeaImages([png], to: first.id) { check(false, "an image can be added", error.message) }
    let name = model.library.item(first.id)?.images.first ?? ""
    check(ContentItem.isImageName(name) && FileManager.default.fileExists(atPath: folder.appendingPathComponent("Images/\(name)").path),
          "an image is copied into the Library under its own name")
    let text = scratch.appendingPathComponent("notes.txt")
    try "not an image".write(to: text, atomically: true, encoding: .utf8)
    if case .failure(let error) = model.addIdeaImages([text], to: first.id) {
        check(error.message.contains("not an image"), "a file that is not an image is refused", error.message)
    } else { check(false, "a file that is not an image is refused") }
    model.removeIdeaImage(first.id, name)
    check(model.library.item(first.id)?.images.isEmpty == true, "an image comes off an idea")
    let reloaded = AppModel(recoveryURL: nil)
    reloaded.loadLibrary(from: folder)
    check(reloaded.library == model.library && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Images/\(name)").path),
          "the Library reads back, and an image no idea uses is removed on load")
    let broken = scratch.appendingPathComponent("library-broken", isDirectory: true)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: broken.appendingPathComponent("Library.json"))
    let fresh = AppModel(recoveryURL: nil)
    fresh.loadLibrary(from: broken)
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: broken.path)) ?? []
    check(fresh.library.items.isEmpty && kept.contains { $0.hasPrefix("Library (unreadable") } && !kept.contains("Library.json"),
          "a Library that cannot be read is kept aside, never written over")

    print("\nIdeas and projects")
    let projects = scratch.appendingPathComponent("idea-projects", isDirectory: true)
    let projectFile = projects.appendingPathComponent("How I edit with Claude.yamvideo")
    check(model.startProject(from: first.id, at: projectFile), "Start a Project from This Idea saves a new project")
    let link = model.library.item(first.id)?.project
    check(link?.projectID == model.projectID && link?.path == projectFile.path && model.module == .studio,
          "and links it to the idea, then opens Studio")
    equal(model.library.item(first.id)?.stage, .inProduction, "an idea with a project is In production")
    equal(model.openProjectIdea?.id, first.id, "Studio knows which idea the open project was made from")
    equal(refused([.linkProject(id: second.id, link: link)]), .invalidCommand, "a project belongs to one idea at most")
    let moved = projects.appendingPathComponent("Moved.yamvideo")
    try FileManager.default.moveItem(at: projectFile, to: moved)
    model.newProject()
    model.openProject(at: moved)
    equal(model.library.item(first.id)?.project?.path, moved.path, "opening a moved project moves the idea's link with it")
    model.libraryUndo()
    model.libraryRedo()
    equal(model.library.item(first.id)?.project?.path, moved.path, "and undo and redo keep its new place")
    model.unlinkProject(first.id)
    check(model.library.item(first.id)?.project == nil && model.openProjectIdea == nil, "unlinking leaves only the idea")

    print("\nThe Library for agents")
    let library = agentResult(await agentCall(model, ["method": "library"]))
    let ideas = library["ideas"] as? [[String: Any]] ?? []
    check(library["revision"] as? Int == model.library.revision && ideas.count == 2 && (library["topics"] as? [String]) == ["AI workflow"]
              && ideas.contains { $0["stage"] as? String == "idea" && $0["title"] as? String == first.title },
          "an agent reads the ideas, topics and the Library's revision")
    let current = model.library.revision
    func libraryApply(_ commands: [[String: Any]], revision: Int?, extra: [String: Any] = [:]) async -> [String: Any] {
        var request: [String: Any] = ["method": "libraryApply", "client": "Claude", "requestID": UUID().uuidString, "commands": commands]
        if let revision { request["expectedRevision"] = revision }
        for (key, value) in extra { request[key] = value }
        return await agentCall(model, request)
    }
    equal(agentError(await libraryApply([["type": "addIdea", "title": "x"]], revision: nil)), "invalid_request",
          "Library edits name the Library revision they read")
    let chosen = UUID()
    let images = try ideaImage("agent-reference.png")
    let imageCount = { (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Images").path).count) ?? 0 }
    let before = imageCount()
    let dry = agentResult(await libraryApply([["type": "addIdea", "ideaID": chosen.uuidString, "title": "Shorts safe area explained",
                                                "topic": "YouTube tips", "paths": [images.path]]], revision: current, extra: ["dryRun": true]))
    check(dry["changed"] as? Bool == true && dry["dryRun"] as? Bool == true && model.library.item(chosen) == nil && imageCount() == before,
          "a dry run checks an idea with its images and copies nothing")
    let applied = agentResult(await libraryApply([["type": "addIdea", "ideaID": chosen.uuidString, "title": "Shorts safe area explained",
                                                    "topic": "YouTube tips", "paths": [images.path]]], revision: current))
    check((applied["createdIDs"] as? [String]) == [chosen.uuidString] && model.library.item(chosen)?.images.count == 1
              && model.libraryHighlight?.items.contains(chosen) == true,
          "an agent adds an idea with the id it chose, and the idea shows who added it")
    check(model.recentActivity.first?.kind == .library && model.recentActivity.first?.origin == .agent("Claude"),
          "the activity list credits the agent")
    equal(agentError(await libraryApply([["type": "removeIdea", "ideaID": chosen.uuidString]], revision: current)), "revision_conflict",
          "an edit against an old Library revision is refused")
    let unknown = await libraryApply([["type": "renameEverything"]], revision: model.library.revision)
    check(agentError(unknown) == "invalid_request" && ((unknown["error"] as? [String: Any])?["message"] as? String ?? "").contains("addIdea"),
          "an unknown command says which commands there are")
    let missingTitle = await libraryApply([["type": "addIdea"]], revision: model.library.revision)
    check(((missingTitle["error"] as? [String: Any])?["message"] as? String ?? "").contains("Command 1 (addIdea)"),
          "a refusal says which command it was")
    let cleared = agentResult(await libraryApply([["type": "updateIdea", "ideaID": chosen.uuidString, "topic": ""]], revision: model.library.revision))
    check(cleared["changed"] as? Bool == true && model.library.item(chosen)?.topic == nil, "an empty topic clears it")
    model.save(to: projects.appendingPathComponent("Open.yamvideo"), asCopy: false)
    let linked = agentResult(await libraryApply([["type": "linkProject", "ideaID": chosen.uuidString]], revision: model.library.revision))
    check(linked["changed"] as? Bool == true && model.library.item(chosen)?.project?.projectID == model.projectID,
          "linkProject without a path links the saved project open in Studio")
    let state = agentResult(await agentCall(model, ["method": "state"]))
    check((state["idea"] as? [String: Any])?["id"] as? String == chosen.uuidString, "project state names the idea it was made from")
    let byPath = agentResult(await libraryApply([["type": "unlinkProject", "ideaID": chosen.uuidString],
                                                 ["type": "linkProject", "ideaID": first.id.uuidString, "path": moved.path]],
                                                revision: model.library.revision))
    check(byPath["changed"] as? Bool == true && model.library.item(first.id)?.project?.path == moved.path,
          "linkProject with a path reads the project's identity from its file")
    let undone = agentResult(await agentCall(model, ["method": "libraryUndo", "client": "Claude", "requestID": UUID().uuidString,
                                                     "transactionID": byPath["transactionID"] as? String ?? "",
                                                     "expectedRevision": model.library.revision]))
    check(undone["changed"] as? Bool == true && model.library.item(chosen)?.project != nil, "an agent undoes its own Library step")
    model.editIdea(first.id, title: "How I edit with Claude, live")
    let conflict = await agentCall(model, ["method": "libraryRedo", "client": "Claude", "requestID": UUID().uuidString,
                                          "transactionID": byPath["transactionID"] as? String ?? "", "expectedRevision": model.library.revision])
    equal(agentError(conflict), "nothing_to_undo", "after the owner's edit there is nothing of the agent's to redo")
    let retryID = UUID().uuidString
    let once = await agentCall(model, ["method": "libraryApply", "client": "Claude", "requestID": retryID, "expectedRevision": model.library.revision,
                                       "commands": [["type": "updateIdea", "ideaID": chosen.uuidString, "notes": "Once"]]])
    let twice = await agentCall(model, ["method": "libraryApply", "client": "Claude", "requestID": retryID, "expectedRevision": model.library.revision - 1,
                                        "commands": [["ideaID": chosen.uuidString, "notes": "Once", "type": "updateIdea"]]])
    check(agentResult(once)["revision"] as? Int == agentResult(twice)["revision"] as? Int && agentResult(once)["revision"] != nil,
          "a retry with the same request ID gets the first answer")
    let reused = await agentCall(model, ["method": "libraryApply", "client": "Claude", "requestID": retryID, "expectedRevision": model.library.revision,
                                         "commands": [["type": "updateIdea", "ideaID": chosen.uuidString, "notes": "Twice"]]])
    equal(agentError(reused), "request_id_reused", "and reusing it for other commands is refused")
    model.agentsPaused = true
    equal(agentError(await libraryApply([["type": "removeIdea", "ideaID": chosen.uuidString]], revision: model.library.revision)), "agents_paused",
          "paused agents cannot change the Library")
    model.agentsPaused = false
    model.module = .studio
    let revealed = agentResult(await agentCall(model, ["method": "reveal", "idea": second.id.uuidString]))
    check(model.module == .ideas && model.selectedIdeaID == second.id && revealed["idea"] as? String == second.id.uuidString,
          "reveal shows an idea on the Ideas page")
    equal(agentError(await agentCall(model, ["method": "reveal", "idea": UUID().uuidString])), "not_found", "and says when there is no such idea")

    let catalog = AgentCatalog.current
    let libraryFields = Set(Mirror(reflecting: LibraryWireCommand(type: "x")).children.compactMap(\.label))
    equal(Set(catalog.libraryCommands.map(\.type)), Set(LibraryWireCommand.types), "the catalog describes exactly the Library commands")
    let strays = catalog.libraryCommands.flatMap { command in command.fields.map(\.name).filter { !libraryFields.contains($0) }.map { "\(command.type).\($0)" } }
    check(strays.isEmpty, "every Library field it names is one libraryApply reads", strays.joined(separator: ", "))
    let badExamples = catalog.libraryCommands.filter { command in
        guard let data = try? JSONEncoder().encode(command.example),
              let wire = try? JSONDecoder().decode(LibraryWireCommand.self, from: data) else { return true }
        return wire.type != command.type
    }.map(\.type)
    check(badExamples.isEmpty, "every Library example is a well-formed command of its own type", badExamples.joined(separator: ", "))
}
