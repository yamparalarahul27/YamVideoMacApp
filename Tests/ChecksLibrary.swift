import AppKit
import Foundation

// The Library and the Library page (docs/plans/distribution.md, phase 1): ideas, their rules
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
    let newerFolder = scratch.appendingPathComponent("library-newer", isDirectory: true)
    try FileManager.default.createDirectory(at: newerFolder, withIntermediateDirectories: true)
    let newerData = try newer.encoded()
    try newerData.write(to: newerFolder.appendingPathComponent("Library.json"))
    let older = AppModel(recoveryURL: nil)
    older.loadLibrary(from: newerFolder)
    older.performLibrary([.addIdea(ContentItem(title: "Not saved"))])
    check((try? Data(contentsOf: newerFolder.appendingPathComponent("Library.json"))) == newerData && older.libraryFolderURL == nil,
          "an older YamVideo leaves a newer Library untouched and saves nothing over it")

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
    model.module = .library
    equal(model.menuUndoTitle, model.libraryUndoTitle, "on the Library page, the Edit menu undoes the Library")
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
    check(model.module == .library && model.selectedIdeaID == second.id && revealed["idea"] as? String == second.id.uuidString,
          "reveal shows an idea on the Library page")
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

/// Writes `object` as a `.youtube.json` and returns its URL.
func exportFile(_ folder: URL, _ name: String, _ object: [String: Any]) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name + ".youtube.json")
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    return url
}

@MainActor func pastVideosTests() async throws {
    print("Past videos: finding projects and their exports")
    let root = scratch.appendingPathComponent("past", isDirectory: true)
    let shorts = root.appendingPathComponent("Shorts", isDirectory: true)
    try FileManager.default.createDirectory(at: shorts, withIntermediateDirectories: true)
    // A saved project: one recording with a YouTube title and two Shorts.
    let projectID = UUID(), shortOne = UUID(), shortTwo = UUID()
    var recording = VideoItem(url: landscape)
    recording.info = info; recording.crop = info.fullFrame
    var long = PublishInfo(); long.title = "Five App Store tips"
    recording.publish = long
    var first = Short(id: shortOne, start: 0.2, end: 1.5); first.title = "Tip one"
    var second = Short(id: shortTwo, start: 1.6, end: 2.9); second.title = "Tip two"
    recording.shorts = [first, second]
    let projectFile = root.appendingPathComponent("AppStore.yamvideo")
    let project = VideoProject(projectID: projectID, clips: [ProjectClip(recording)], settings: ExportSettings(), selection: nil,
                               movieSettings: nil, autoEdit: nil)
    try JSONEncoder().encode(project).write(to: projectFile)
    // A Short exported before exports said their project (as on 15 Oct): matched by the Short.
    try Data().write(to: shorts.appendingPathComponent("Tip one.mp4"))
    _ = try ideaImage("past/Shorts/Tip one cover.jpg")
    let oldShort = try exportFile(shorts, "Tip one", ["short": true, "shortID": shortOne.uuidString, "title": "Tip one",
                                                      "description": "The first tip.", "tags": ["App Store", "iOS app"], "length": 1.3,
                                                      "files": ["video": "Tip one.mp4", "cover": "Tip one cover.jpg", "text": "Tip one YouTube.txt"]])
    // The long video exported now: it names its project and recording.
    let longFiles = YouTubeExport.files(in: root, publish: long, fallback: "AppStore", captions: false, unique: false)
    try YouTubeExport.json(long, files: longFiles, project: projectID, recording: recording.id).write(to: longFiles.json)
    // An export whose project is somewhere else, and a project in a hidden folder.
    let stray = try exportFile(root.appendingPathComponent("Older", isDirectory: true), "Old intro", ["title": "Old intro", "short": false])
    let hidden = root.appendingPathComponent(".cache", isDirectory: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try JSONEncoder().encode(project).write(to: hidden.appendingPathComponent("Copy.yamvideo"))

    let (projects, exports) = LibraryScan.files(in: [root])
    check(projects.map(\.lastPathComponent) == ["AppStore.yamvideo"] && exports.count == 3,
          "a scan finds the projects and exports in a folder, and skips hidden folders",
          "\(projects.map(\.lastPathComponent)) \(exports.map(\.lastPathComponent))")
    let longJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: longFiles.json)) as? [String: Any]
    check(longJSON?["projectID"] as? String == projectID.uuidString && longJSON?["recordingID"] as? String == recording.id.uuidString,
          "Export for YouTube now writes the project and recording it was made from")
    let shortJSON = try JSONSerialization.jsonObject(with: ShortExport.json(second, publish: second.publishInfo(recording: long), recording: recording,
                                                                             files: longFiles, coverWritten: false, project: projectID)) as? [String: Any]
    check(shortJSON?["projectID"] as? String == projectID.uuidString && shortJSON?["shortID"] as? String == shortTwo.uuidString,
          "and so does Export Short for YouTube")

    let model = AppModel(recoveryURL: nil)
    model.loadLibrary(from: scratch.appendingPathComponent("past-library", isDirectory: true))
    let found = LibraryScan.candidates(roots: [root], library: model.library)
    let projectCandidate = found.first { $0.project != nil }
    check(found.count == 2 && projectCandidate?.exports.count == 2 && projectCandidate?.title == "Five App Store tips"
              && found.contains { $0.project == nil && $0.path == stray.path },
          "an export is matched to its project by the Short it is of, or by the project it names; one without its project stands alone")

    model.scanPastVideos([root])
    for _ in 0..<100 where model.libraryScan?.scanning != false { try await Task.sleep(nanoseconds: 50_000_000) }
    check(model.libraryScan?.chosen.count == 2 && model.module == .library, "Scan a Folder ticks everything new and shows the Library")
    model.addChosenPastVideos()
    guard let item = model.library.item(forProject: projectID) else { check(false, "the project becomes an item"); return }
    check(model.libraryScan == nil && item.stage == .ready && item.project?.path == projectFile.path && item.videos.count == 2
              && Set(item.videos.map(\.id)) == [shortOne, recording.id] && model.library.items.count == 2,
          "the project becomes a Ready item with its exported long video and Short; nothing is copied")
    equal(model.libraryUndoTitle, "Undo Add Past Videos", "adding them is one undo step")
    let rows = model.videoRows(item)
    check(rows.map(\.id) == [recording.id, shortOne, shortTwo] && rows[0].title == "Five App Store tips" && rows[2].stored == nil,
          "the item shows every video of its project, long ones first, exported or not")
    check(rows[1].export?.video?.hasSuffix("Tip one.mp4") == true && rows[1].export?.cover?.hasSuffix("Tip one cover.jpg") == true
              && rows[1].export?.everything.contains("App Store, iOS app") == true,
          "a video's export gives its files and the title, description and tags to copy")
    check(LibraryScan.candidates(roots: [root], library: model.library).allSatisfy(\.alreadyAdded),
          "scanning again finds nothing new")

    print("\nNew exports and posts")
    func row(_ id: UUID) -> VideoRow { model.videoRows(model.library.item(item.id)!).first { $0.id == id }! }
    let laterFiles = YouTubeExport.files(in: shorts, publish: second.publishInfo(recording: long), fallback: "Tip two", captions: false, unique: false)
    try ShortExport.json(second, publish: second.publishInfo(recording: long), recording: recording, files: laterFiles, coverWritten: false,
                         project: projectID).write(to: laterFiles.json)
    model.noteExport(laterFiles.json, origin: .human)
    check(model.library.item(item.id)?.video(shortTwo)?.exports.count == 1 && model.libraryUndoTitle == "Undo Exported Tip two",
          "an export from a linked project lands in the Library without a scan")
    let again = try exportFile(shorts, "Tip one again", ["short": true, "shortID": shortOne.uuidString, "title": "Tip one"])
    let refound = LibraryScan.candidates(roots: [root], library: model.library).first { $0.project != nil }
    check(refound?.alreadyAdded == false && refound?.newExports == 1, "a scan offers only the exports the Library does not have")
    model.scanPastVideos([root])
    for _ in 0..<100 where model.libraryScan?.scanning != false { try await Task.sleep(nanoseconds: 50_000_000) }
    model.addChosenPastVideos()
    check(Set(model.library.item(item.id)?.video(shortOne)?.exports.map(\.json) ?? []) == [oldShort.path, again.path],
          "and adds them to the video they are of")
    check(row(shortOne).export?.video?.hasSuffix("Tip one.mp4") == true, "the row plays the latest export that still has its video")

    if case .failure(let error) = model.addPost(item.id, row(shortOne), link: "youtube.com/shorts/abc123") { check(false, "a post link is kept", error.message) }
    check(row(shortOne).posts.first?.link == "https://youtube.com/shorts/abc123" && row(shortOne).posts.first?.platform == .youtube
              && model.library.item(item.id)?.stage == .posted,
          "a pasted post link is kept, its platform read from the address, and the item is Posted")
    check(model.addPost(item.id, row(shortOne), link: "https://youtube.com/shorts/abc123").isFailureCase
              && model.addPost(item.id, row(shortOne), link: "not a link").isFailureCase,
          "the same link twice, or something that is not a link, is refused")
    model.addPost(item.id, row(shortTwo), link: nil)
    check(row(shortTwo).posts.count == 1 && row(shortTwo).posts[0].link == nil, "a video can be marked posted without a link")
    model.addPost(item.id, row(shortTwo), link: "https://www.instagram.com/reel/xyz/")
    check(row(shortTwo).posts.map(\.platform) == [.instagram], "and a link given later takes the place of the plain mark")
    check(Platform.of("https://x.com/me/status/1") == .x && Platform.of("https://www.linkedin.com/posts/me") == .linkedin
              && Platform.of("https://youtu.be/abc") == .youtube && Platform.of("https://example.com") == nil,
          "the four platforms are recognised from their addresses")
    model.removePost(item.id, row(shortTwo), link: nil)
    check(row(shortTwo).posts.isEmpty, "posts come off again")

    model.openVideoInStudio(item.id, row(shortOne))
    check(model.module == .studio && model.projectID == projectID && model.selection == recording.id && model.selectedShortID == shortOne,
          "Open in Studio opens the project with the recording and the Short selected")

    print("\nOlder Libraries and agents")
    var older = model.library
    older.version = 1
    for index in older.items.indices { older.items[index].videos = [] }
    let reread = try Library.decode(older.encoded())
    check(reread.version == Library.currentVersion && reread.items.count == older.items.count, "a version 1 Library reads as version 2")

    let agentModel = AppModel(recoveryURL: nil)
    agentModel.loadLibrary(from: scratch.appendingPathComponent("past-agent-library", isDirectory: true))
    let scanned = agentResult(await agentCall(agentModel, ["method": "scanFolder", "path": root.path]))
    let candidates = scanned["candidates"] as? [[String: Any]] ?? []
    check(candidates.count == 2 && candidates.contains { $0["projectID"] as? String == projectID.uuidString && ($0["exports"] as? [Any])?.count == 4 },
          "an agent sees what a scan would add, and nothing changes", "\(candidates.map { $0["title"] ?? "" })")
    check(agentModel.library.items.isEmpty, "scanFolder adds nothing")
    let imported = agentResult(await agentCall(agentModel, ["method": "libraryApply", "client": "Claude", "requestID": UUID().uuidString,
                                                            "expectedRevision": agentModel.library.revision,
                                                            "commands": [["type": "importVideos", "paths": [root.path]]]]))
    check((imported["createdIDs"] as? [Any])?.count == 2 && agentModel.library.item(forProject: projectID)?.stage == .ready,
          "importVideos adds the project and the stray export")
    let agentItem = agentModel.library.item(forProject: projectID)!
    let posted = agentResult(await agentCall(agentModel, ["method": "libraryApply", "client": "Claude", "requestID": UUID().uuidString,
                                                          "expectedRevision": agentModel.library.revision,
                                                          "commands": [["type": "addPost", "ideaID": agentItem.id.uuidString,
                                                                        "videoID": shortTwo.uuidString, "link": "https://youtube.com/shorts/two"]]]))
    check(posted["changed"] as? Bool == true && agentModel.library.item(agentItem.id)?.video(shortTwo)?.posts.first?.platform == .youtube,
          "addPost records a post on a Short that was in the project but not yet in the Library")
    let state = agentResult(await agentCall(agentModel, ["method": "library"]))
    let ideas = state["ideas"] as? [[String: Any]] ?? []
    let videos = ideas.first { $0["id"] as? String == agentItem.id.uuidString }?["videos"] as? [[String: Any]] ?? []
    check(videos.count == 3 && videos.contains { ($0["posts"] as? [[String: Any]])?.first?["platform"] as? String == "youtube" }
              && videos.contains { ($0["exports"] as? [Any])?.count == 2 && ($0["video"] as? String)?.hasSuffix(".mp4") == true },
          "the Library's state lists each video with its exports, posts and files")
    let missingVideo = await agentCall(agentModel, ["method": "libraryApply", "client": "Claude", "requestID": UUID().uuidString,
                                                    "expectedRevision": agentModel.library.revision,
                                                    "commands": [["type": "addPost", "ideaID": agentItem.id.uuidString, "videoID": UUID().uuidString]]])
    equal(agentError(missingVideo), "not_found", "addPost names a video the idea has")
}

extension Result {
    var isFailureCase: Bool { if case .failure = self { return true }; return false }
}
