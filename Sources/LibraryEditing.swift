import AppKit
import Foundation
import UniformTypeIdentifiers

// The Library in the running app: loading and saving it, its own undo history and
// revision, the owner's actions on the Library page, and the links between an idea and the
// project made from it. See Library.swift for the data and its rules.

/// The parts of the window, in the sidebar. The Library holds ideas, projects and
/// published videos; the Calendar shows when each goes out, and where; Studio is the
/// editor. Later phases add Results and Platforms.
enum AppModule: String, CaseIterable, Identifiable {
    case library, calendar, studio

    var id: String { rawValue }
    var label: String {
        switch self {
        case .library: return "Library"
        case .calendar: return "Calendar"
        case .studio: return "Studio"
        }
    }
    var systemImage: String {
        switch self {
        case .library: return "books.vertical"
        case .calendar: return "calendar"
        case .studio: return "film"
        }
    }
    /// The Library and the Calendar edit the Library, with its own undo.
    var editsLibrary: Bool { self != .studio }
}

/// One Library undo step: the ideas as they were before it, and who made it.
struct LibraryHistory {
    let name: String
    let transactionID: UUID
    let origin: EditOrigin
    let items: [ContentItem]
    var style = ""
    var rhythm: ReleaseRhythm?
    /// Typing in one field of one idea is one step while it goes on: the field's key,
    /// and when it last changed.
    var coalesce: String?
    var date = Date()
}

/// The result of a Library transaction, or of a dry run of one.
struct LibraryReceipt: Equatable {
    var revision: Int
    var transactionID: UUID?
    var changed: Bool
    var createdIDs: [UUID]
    var changedIDs: [UUID]
}

/// What an agent just changed in the Library, shown on its ideas for a moment.
struct LibraryHighlight: Equatable {
    let id = UUID()
    var origin: String
    var label: String
    var items: Set<UUID>
}

@MainActor
extension AppModel {
    nonisolated static var libraryFolder: URL {
        // A separate instance (a test, an acceptance run) keeps its own Library.
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_LIBRARY_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo", isDirectory: true).appendingPathComponent("Library", isDirectory: true)
    }

    var libraryFile: URL? { libraryFolderURL?.appendingPathComponent("Library.json") }
    var styleFile: URL? { libraryFolderURL?.appendingPathComponent("Style.md") }
    var libraryImagesFolder: URL? { libraryFolderURL?.appendingPathComponent("Images", isDirectory: true) }

    func libraryImageURL(_ name: String) -> URL? { libraryImagesFolder?.appendingPathComponent(name) }

    // MARK: Loading and saving

    /// Reads the Library from `folder`, or starts an empty one there. A file that cannot be
    /// read is moved aside, never written over. Images no idea uses any more are removed:
    /// undo history does not outlive the app, so nothing can bring them back.
    func loadLibrary(from folder: URL = AppModel.libraryFolder) {
        libraryFolderURL = folder
        libraryUndoEntries = []; libraryRedoEntries = []
        let file = folder.appendingPathComponent("Library.json")
        if let data = try? Data(contentsOf: file) {
            do { library = try Library.decode(data) } catch let error as EditError where error.code == .unsupportedCapability {
                // A newer YamVideo's Library: leave it untouched, and write nothing over it.
                library = Library()
                libraryFolderURL = nil
                statusMessage = error.message
                return
            } catch {
                let aside = folder.appendingPathComponent("Library (unreadable \(Int(Date().timeIntervalSince1970))).json")
                try? FileManager.default.moveItem(at: file, to: aside)
                library = Library()
                statusMessage = "The Library could not be read (\(AppModel.describe(error))). It was kept as \(aside.lastPathComponent) and a new one started."
            }
        } else {
            library = Library()
        }
        if let images = libraryImagesFolder,
           let names = try? FileManager.default.contentsOfDirectory(atPath: images.path) {
            let used = Set(library.items.flatMap(\.images))
            for name in names where !used.contains(name) && !name.hasPrefix(".") {
                try? FileManager.default.removeItem(at: images.appendingPathComponent(name))
            }
        }
        // Style.md: read it, or start one with the headings.
        styleOnDisk = nil; styleFileDate = nil
        if let style = styleFile, let text = try? String(contentsOf: style, encoding: .utf8) {
            library.style = text
            styleOnDisk = text
            styleFileDate = fileDate(style)
        } else {
            library.style = StyleDoc.starter
            writeStyle()
        }
        if selectedIdeaID == nil || library.item(selectedIdeaID) == nil { selectedIdeaID = library.items.first?.id }
        noteProjectLocation()
    }

    private func fileDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Writes Style.md when its text is not what the file already holds.
    private func writeStyle() {
        guard let file = styleFile, library.style != styleOnDisk else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(library.style.utf8).write(to: file, options: .atomic)
            styleOnDisk = library.style
            styleFileDate = fileDate(file)
        } catch {
            statusMessage = "Could not save Style.md: \(error.localizedDescription)"
        }
    }

    /// Takes in Style.md as the owner left it in another app. Their text wins: the undo
    /// history keeps it too, so no Undo can bring back what they replaced.
    func refreshStyleFromDisk() {
        guard let file = styleFile, let date = fileDate(file), date != styleFileDate,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        styleFileDate = date
        styleOnDisk = text
        guard text != library.style else { return }
        library.style = text
        func keep(_ entries: inout [LibraryHistory]) {
            entries = entries.map { entry in
                LibraryHistory(name: entry.name, transactionID: entry.transactionID, origin: entry.origin,
                               items: entry.items, style: text, rhythm: entry.rhythm, coalesce: entry.coalesce, date: entry.date)
            }
        }
        keep(&libraryUndoEntries); keep(&libraryRedoEntries)
        library.revision += 1
        writeLibrary()
        appendEvent(.library, origin: .human, label: "Style.md changed in another app", revision: library.revision)
    }

    /// Writes the whole Library atomically. Nothing is written before it was loaded.
    private func writeLibrary() {
        guard let file = libraryFile else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try library.encoded().write(to: file, options: .atomic)
        } catch {
            statusMessage = "Could not save the Library: \(error.localizedDescription)"
        }
        writeStyle()
    }

    // MARK: Transactions

    /// Applies `commands` to the Library as one undo step, or none of them. Agents pass
    /// `expectedRevision`; a stale one is refused. `coalesce` names a field being typed
    /// in: changes to the same one within a few seconds join the step on top.
    @discardableResult
    func performLibrary(_ commands: [LibraryCommand], label: String? = nil, origin: EditOrigin = .human,
                        expectedRevision: Int? = nil, dryRun: Bool = false, coalesce: String? = nil) -> Result<LibraryReceipt, EditError> {
        let label = label ?? commands.first?.defaultLabel ?? "Edit Ideas"
        // An edit made in another app comes first, and moves the revision on.
        if commands.contains(where: { if case .setStyle = $0 { return false }; return true }) || origin.isHuman == false { refreshStyleFromDisk() }
        if let refusal = admitLibrary(origin, expectedRevision: expectedRevision) { return .failure(refusal) }
        let outcome: LibraryOutcome
        do { outcome = try LibraryReducer.apply(commands, to: library) }
        catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid(error.localizedDescription)) }
        var receipt = LibraryReceipt(revision: library.revision, transactionID: nil,
                                     changed: outcome.library.items != library.items || outcome.library.style != library.style
                                        || outcome.library.rhythm != library.rhythm,
                                     createdIDs: outcome.createdIDs, changedIDs: outcome.changedIDs)
        guard !dryRun, receipt.changed else { return .success(receipt) }

        let transaction: UUID
        if let coalesce, origin.isHuman, libraryRedoEntries.isEmpty, let top = libraryUndoEntries.last,
           top.coalesce == coalesce, top.origin.isHuman, Date().timeIntervalSince(top.date) < 4 {
            transaction = top.transactionID
            libraryUndoEntries[libraryUndoEntries.count - 1].date = Date()
        } else {
            transaction = UUID()
            libraryUndoEntries.append(LibraryHistory(name: label, transactionID: transaction, origin: origin,
                                                     items: library.items, style: library.style, rhythm: library.rhythm, coalesce: coalesce))
            if libraryUndoEntries.count > 100 { libraryUndoEntries.removeFirst() }
            libraryRedoEntries.removeAll()
        }
        let before = library.items
        library.items = outcome.library.items
        library.style = outcome.library.style
        library.rhythm = outcome.library.rhythm
        receipt.transactionID = transaction
        receipt.revision = commitLibrary(origin: origin, label: label, transaction: transaction, before: before)
        return .success(receipt)
    }

    /// Whether `origin` may change the Library now.
    private func admitLibrary(_ origin: EditOrigin, expectedRevision: Int?) -> EditError? {
        guard !origin.isHuman else { return nil }
        if agentsPaused {
            return EditError(code: .agentsPaused, message: "Agent edits are paused in YamVideo. Ask the owner to resume them.")
        }
        if let expectedRevision, expectedRevision != library.revision {
            return EditError(code: .revisionConflict,
                             message: "The Library is at revision \(library.revision), not \(expectedRevision). Read the Library and plan again.")
        }
        return nil
    }

    /// Bookkeeping shared by every committed Library change. Returns the new revision.
    private func commitLibrary(origin: EditOrigin, label: String, transaction: UUID?, before: [ContentItem]) -> Int {
        library.revision += 1
        writeLibrary()
        if library.item(selectedIdeaID) == nil { selectedIdeaID = library.items.first?.id }
        appendEvent(.library, origin: origin, label: label, transaction: transaction, revision: library.revision)
        if !origin.isHuman {
            let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            let changed = Set(library.items.filter { old[$0.id] != $0 }.map(\.id))
            let highlight = LibraryHighlight(origin: origin.label, label: label, items: changed)
            libraryHighlight = highlight
            statusMessage = "\(origin.label): \(label)"
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if self?.libraryHighlight?.id == highlight.id { self?.libraryHighlight = nil }
            }
        }
        return library.revision
    }

    // MARK: Undo and redo

    /// The Library's own history, apart from the project's. An agent names the step it
    /// means; if anyone has changed the Library since, it is refused.
    @discardableResult
    func libraryUndo(origin: EditOrigin = .human, expectedTransaction: UUID? = nil,
                     expectedRevision: Int? = nil) -> Result<LibraryReceipt, EditError> {
        stepLibraryHistory(redo: false, origin: origin, expectedTransaction: expectedTransaction, expectedRevision: expectedRevision)
    }

    @discardableResult
    func libraryRedo(origin: EditOrigin = .human, expectedTransaction: UUID? = nil,
                     expectedRevision: Int? = nil) -> Result<LibraryReceipt, EditError> {
        stepLibraryHistory(redo: true, origin: origin, expectedTransaction: expectedTransaction, expectedRevision: expectedRevision)
    }

    private func stepLibraryHistory(redo: Bool, origin: EditOrigin, expectedTransaction: UUID?,
                                    expectedRevision: Int?) -> Result<LibraryReceipt, EditError> {
        if let refusal = admitLibrary(origin, expectedRevision: expectedRevision) { return .failure(refusal) }
        guard let entry = redo ? libraryRedoEntries.last : libraryUndoEntries.last else {
            return .failure(EditError(code: .nothingToUndo, message: redo ? "There is nothing to redo in the Library." : "There is nothing to undo in the Library."))
        }
        if !origin.isHuman, entry.transactionID != expectedTransaction {
            return .failure(EditError(code: .historyConflict,
                message: "The most recent Library step is now \"\(entry.name)\" by \(entry.origin.label). Read the Library and decide again."))
        }
        let opposite = LibraryHistory(name: entry.name, transactionID: entry.transactionID, origin: entry.origin, items: library.items,
                                      style: library.style, rhythm: library.rhythm)
        if redo { libraryRedoEntries.removeLast(); libraryUndoEntries.append(opposite) }
        else { libraryUndoEntries.removeLast(); libraryRedoEntries.append(opposite) }
        let before = library.items
        library.items = entry.items
        library.style = entry.style
        library.rhythm = entry.rhythm
        let changed = Set(entry.items.map(\.id)).symmetricDifference(before.map(\.id))
            .union(entry.items.filter { item in before.first { $0.id == item.id } != item }.map(\.id))
        if origin.isHuman, let first = changed.first(where: { library.item($0) != nil }) { selectedIdeaID = first }
        let revision = commitLibrary(origin: origin, label: "\(redo ? "Redid" : "Undid") \(entry.name)",
                                     transaction: entry.transactionID, before: before)
        return .success(LibraryReceipt(revision: revision, transactionID: entry.transactionID, changed: true,
                                       createdIDs: [], changedIDs: Array(changed)))
    }

    var libraryUndoTitle: String { libraryHistoryTitle("Undo", libraryUndoEntries.last) }
    var libraryRedoTitle: String { libraryHistoryTitle("Redo", libraryRedoEntries.last) }

    private func libraryHistoryTitle(_ verb: String, _ entry: LibraryHistory?) -> String {
        guard let entry else { return verb }
        return entry.origin.isHuman ? "\(verb) \(entry.name)" : "\(verb) \(entry.name) (\(entry.origin.label))"
    }

    // MARK: The Edit menu, whichever module is showing

    var menuUndoTitle: String { module.editsLibrary ? libraryUndoTitle : undoTitle }
    var menuRedoTitle: String { module.editsLibrary ? libraryRedoTitle : redoTitle }
    var canUndoInModule: Bool { module.editsLibrary ? !libraryUndoEntries.isEmpty : !undoEntries.isEmpty && !isConverting }
    var canRedoInModule: Bool { module.editsLibrary ? !libraryRedoEntries.isEmpty : !redoEntries.isEmpty && !isConverting }

    // MARK: The owner's actions

    /// The idea the open project was made from, if it is linked to one.
    var openProjectIdea: ContentItem? { library.item(forProject: projectID) }

    /// The module the window showed when the app last quit.
    func restoreModule() {
        if let saved = UserDefaults.standard.string(forKey: Self.moduleKey).flatMap(AppModule.init(rawValue:)) { module = saved }
    }

    func showModule(_ module: AppModule) {
        guard self.module != module else { return }
        if module != .studio { playback.pause() }
        self.module = module
    }

    /// Goes to an idea on the Library page.
    func showIdea(_ id: UUID) {
        guard library.item(id) != nil else { return }
        selectedIdeaID = id
        showModule(.library)
    }

    func newIdea() {
        let item = ContentItem(title: "New idea", topic: library.item(selectedIdeaID)?.topic)
        if case .success = performLibrary([.addIdea(item)]) {
            selectedIdeaID = item.id
            showModule(.library)
            focusIdeaTitle = true
        }
    }

    func deleteIdea(_ id: UUID) {
        guard let item = library.item(id) else { return }
        let index = library.items.firstIndex { $0.id == id } ?? 0
        if case .success = performLibrary([.removeIdea(id: id)]) {
            let rest = library.items
            selectedIdeaID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
            statusMessage = "Deleted \"\(item.title)\". Undo brings it back."
        }
    }

    /// Field edits from the idea editor. A refusal (an empty title) is said in the status
    /// bar and the idea keeps what it had.
    func editIdea(_ id: UUID, title: String? = nil, notes: String? = nil, topic: String?? = nil, links: [String]? = nil) {
        // An editor closing on an idea that was just deleted has nothing to save.
        guard library.item(id) != nil else { return }
        let key = title != nil ? "title" : notes != nil ? "notes" : topic != nil ? "topic" : "links"
        if case .failure(let error) = performLibrary([.updateIdea(id: id, title: title, notes: notes, topic: topic, links: links)],
                                                     coalesce: key == "links" ? nil : "\(key)-\(id)") {
            statusMessage = error.message
        }
    }

    func addIdeaLink(_ id: UUID, _ text: String) -> Bool {
        guard let item = library.item(id) else { return false }
        let link = ContentItem.normalisedLink(text)
        guard !link.isEmpty else { return false }
        if let problem = ContentItem.linkProblem(link) { statusMessage = problem; return false }
        guard !item.links.contains(link) else { statusMessage = "The idea already has that link."; return false }
        editIdea(id, links: item.links + [link])
        return true
    }

    func removeIdeaLink(_ id: UUID, _ link: String) {
        guard let item = library.item(id) else { return }
        editIdea(id, links: item.links.filter { $0 != link })
    }

    /// Copies images into the Library and adds them to an idea, as one undo step.
    @discardableResult
    func addIdeaImages(_ urls: [URL], to id: UUID, origin: EditOrigin = .human, expectedRevision: Int? = nil,
                       dryRun: Bool = false) -> Result<LibraryReceipt, EditError> {
        guard let folder = libraryImagesFolder else { return .failure(.invalid("The Library is not loaded.")) }
        guard library.item(id) != nil else { return .failure(.notFound("No idea \(id). Read the Library again.")) }
        if let problem = urls.lazy.compactMap(LibraryImages.problem).first { return .failure(.invalid(problem)) }
        if dryRun || urls.isEmpty { return performLibrary([.addImages(id: id, names: [])], origin: origin, expectedRevision: expectedRevision, dryRun: true) }
        if let refusal = admitLibrary(origin, expectedRevision: expectedRevision) { return .failure(refusal) }
        let names: [String]
        do { names = try LibraryImages.copy(urls, into: folder) }
        catch { return .failure(error as? EditError ?? .invalid(error.localizedDescription)) }
        let result = performLibrary([.addImages(id: id, names: names)], origin: origin, expectedRevision: expectedRevision)
        if case .failure = result { for name in names { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) } }
        return result
    }

    func promptForIdeaImages(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose images for this idea. They are copied into the Library."
        guard panel.runModal() == .OK else { return }
        if case .failure(let error) = addIdeaImages(panel.urls, to: id) { statusMessage = error.message }
    }

    /// An image on the pasteboard (a screenshot copied with ⌃⇧⌘4, or an image file), added
    /// to the idea.
    func pasteIdeaImage(_ id: UUID) {
        let board = NSPasteboard.general
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            if case .failure(let error) = addIdeaImages(files, to: id) { statusMessage = error.message }
            return
        }
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            statusMessage = "There is no image to paste. Copy a screenshot or an image file first."
            return
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted \(UUID().uuidString).png")
        do {
            try png.write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if case .failure(let error) = addIdeaImages([temporary], to: id) { statusMessage = error.message }
        } catch { statusMessage = "Could not paste the image: \(error.localizedDescription)" }
    }

    /// Files dropped on the window. On the Library page images go to the selected idea,
    /// and projects, exports and folders are scanned as past videos; recordings always go
    /// to Studio.
    func receiveDropped(_ urls: [URL]) {
        var rest = urls
        if module == .library {
            let images = urls.filter { LibraryImages.extensions.contains($0.pathExtension.lowercased()) }
            if !images.isEmpty, let id = selectedIdeaID {
                if case .failure(let error) = addIdeaImages(images, to: id) { statusMessage = error.message }
            }
            let past = urls.filter { url in
                url.pathExtension.lowercased() == "yamvideo" || url.lastPathComponent.hasSuffix(".youtube.json") || url.hasDirectoryPath
                    || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            if !past.isEmpty { scanPastVideos(past) }
            rest = urls.filter { !images.contains($0) && !past.contains($0) }
        }
        guard !rest.isEmpty else { return }
        showModule(.studio)
        addDropped(rest)
    }

    func removeIdeaImage(_ id: UUID, _ name: String) {
        if case .failure(let error) = performLibrary([.removeImage(id: id, name: name)]) { statusMessage = error.message }
    }

    // MARK: Ideas and projects

    /// Makes a new project for an idea: asks where to save it (named after the idea), then
    /// starts it, saves it there and links it, and opens Studio to add recordings. The
    /// project that was open stays available with Undo in Studio.
    func startProject(from id: UUID) {
        guard let item = library.item(id), item.project == nil else { return }
        guard !isConverting else { statusMessage = "Finish or stop the export before starting a project."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.yamVideoProject]
        panel.nameFieldStringValue = PublishInfo.fileStem(item.title, fallback: "Untitled") + ".yamvideo"
        panel.title = "Start a Project from This Idea"
        panel.message = "Choose where to save the new project. You add its recordings next, in Studio."
        if let folder = UserDefaults.standard.string(forKey: Self.projectFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        } else if let projectURL {
            panel.directoryURL = projectURL.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startProject(from: id, at: url)
    }

    static let projectFolderKey = "ideasProjectFolder"

    /// The work of Start a Project from This Idea, once the place is chosen.
    @discardableResult
    func startProject(from id: UUID, at url: URL) -> Bool {
        guard library.item(id) != nil else { return false }
        newProject()
        save(to: url, asCopy: false)
        guard projectURL?.standardizedFileURL == url.standardizedFileURL else { return false }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.projectFolderKey)
        guard case .success = performLibrary([.linkProject(id: id, link: ProjectLink(projectID: projectID, path: url.path))],
                                             label: "Start Project") else { return false }
        showModule(.studio)
        statusMessage = "Started \(url.lastPathComponent) for this idea. Add its recordings with Add Videos."
        return true
    }

    /// Links the project open in Studio to an idea. An unsaved project is saved first.
    func linkOpenProject(to id: UUID) {
        if projectURL == nil { saveProject() }
        guard let url = projectURL else { return }
        if hasUnsavedChanges { saveProject() }
        if case .failure(let error) = performLibrary([.linkProject(id: id, link: ProjectLink(projectID: projectID, path: url.path))]) {
            statusMessage = error.message
        }
    }

    func unlinkProject(_ id: UUID) {
        performLibrary([.linkProject(id: id, link: nil)])
    }

    /// Opens an idea's project in Studio, unless it is open already.
    func openLinkedProject(_ id: UUID) {
        guard let link = library.item(id)?.project else { return }
        if link.projectID == projectID { showModule(.studio); return }
        guard link.exists else { statusMessage = "\(link.name).yamvideo is no longer at \(link.path). Use Locate to find it."; return }
        openProject(at: link.url)
        if projectID == link.projectID { showModule(.studio) }
    }

    /// Finds a moved project by asking for it; it must be the same project, not a copy.
    func locateLinkedProject(_ id: UUID) {
        guard let link = library.item(id)?.project else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yamVideoProject]
        panel.message = "Find \(link.name).yamvideo."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let found = try? VideoProject.decodeMigrating(from: data) else {
            statusMessage = "\(url.lastPathComponent) is not a YamVideo project this version can read."; return
        }
        guard found.projectID == link.projectID else {
            statusMessage = "\(url.lastPathComponent) is a different project. Unlink this one, then link the project you want."; return
        }
        movedProject(link.projectID, to: url.path)
    }

    /// Called when a project is opened or saved: an idea linked to it follows the file to
    /// where it is now, if the file moved. A fact about the file, not an edit, so there is
    /// no undo step. While the linked file is still at its old place, the open file is a
    /// copy (an agent's review copy in a temporary folder, a backup), and the link stays:
    /// on 20 Oct 2026 two review copies took the link from the real project. Locate… is
    /// the owner's own choice and always moves the link.
    func noteProjectLocation() {
        guard let path = projectURL?.path,
              let link = library.items.first(where: { $0.project?.projectID == projectID })?.project,
              link.path != path, !link.exists else { return }
        movedProject(projectID, to: path)
    }

    private func movedProject(_ projectID: UUID, to path: String) {
        guard let index = library.items.firstIndex(where: { $0.project?.projectID == projectID }),
              library.items[index].project?.path != path else { return }
        library.items[index].project?.path = path
        func follow(_ entries: inout [LibraryHistory]) {
            entries = entries.map { entry in
                let items = entry.items.map { item -> ContentItem in
                    var item = item
                    if item.project?.projectID == projectID { item.project?.path = path }
                    return item
                }
                return LibraryHistory(name: entry.name, transactionID: entry.transactionID, origin: entry.origin,
                                      items: items, style: entry.style, rhythm: entry.rhythm, coalesce: entry.coalesce, date: entry.date)
            }
        }
        follow(&libraryUndoEntries); follow(&libraryRedoEntries)
        library.revision += 1
        writeLibrary()
        appendEvent(.library, origin: .human, label: "Project moved", revision: library.revision)
    }
}
