import Foundation

// The Library for local agents: the `library` state, `libraryApply` with typed commands
// against the Library's own revision, and `libraryUndo` / `libraryRedo` by transaction.
// Every change goes through `performLibrary`, the same path as the owner's own.

/// One Library command as an agent sends it. `type` picks the command; each reads only
/// its own fields and names any that are missing.
struct LibraryWireCommand: Codable, Equatable {
    var type: String
    var ideaID: UUID?
    var title: String?
    var notes: String?
    /// updateIdea: an empty string clears it.
    var topic: String?
    var links: [String]?
    /// Local image files to copy into the Library.
    var paths: [String]?
    /// removeIdeaImage: the image's name from the Library's state.
    var image: String?
    /// linkProject: a .yamvideo file; left out, the project open in Studio.
    var path: String?

    static let types = ["addIdea", "updateIdea", "removeIdea", "addIdeaImages", "removeIdeaImage", "linkProject", "unlinkProject"]
}

/// The parts of a request only Library methods read, decoded from the same line.
private struct LibraryRequestBody: Decodable {
    var commands: [LibraryWireCommand]?
}

/// What `library` returns.
struct AgentLibrary: Encodable {
    struct Image: Encodable { var name: String; var path: String }
    struct Project: Encodable {
        var projectID: UUID
        var path: String
        var name: String
        var exists: Bool
        /// Whether it is the project open in Studio now.
        var open: Bool
    }
    struct Idea: Encodable {
        var id: UUID
        var title: String
        var notes: String
        var topic: String?
        var links: [String]
        var images: [Image]
        /// idea or inProduction (later phases add more).
        var stage: String
        var created: Date
        var updated: Date
        var project: Project?
    }
    struct OpenProject: Encodable {
        var projectID: UUID
        var path: String?
        /// Nil when no idea is linked to it.
        var idea: UUID?
    }
    struct Step: Encodable { var transactionID: UUID; var label: String; var by: String }
    struct History: Encodable { var undo: Step?; var redo: Step? }

    var revision: Int
    var folder: String?
    var stages: [String]
    var topics: [String]
    /// The idea the owner has selected on the Ideas page, and the module showing.
    var selectedIdea: UUID?
    var module: String
    var openProject: OpenProject
    var history: History
    var ideas: [Idea]
}

struct AgentLibraryReceipt: Encodable {
    var revision: Int
    var transactionID: UUID?
    var changed: Bool
    var dryRun: Bool
    var createdIDs: [UUID]
    var changedIDs: [UUID]
}

@MainActor
extension AppModel {
    func agentLibrary() -> AgentLibrary {
        func step(_ entry: LibraryHistory?) -> AgentLibrary.Step? {
            entry.map { .init(transactionID: $0.transactionID, label: $0.name, by: $0.origin.label) }
        }
        let ideas = library.items.map { item in
            AgentLibrary.Idea(
                id: item.id, title: item.title, notes: item.notes, topic: item.topic, links: item.links,
                images: item.images.map { .init(name: $0, path: libraryImageURL($0)?.path ?? $0) },
                stage: item.stage.rawValue, created: item.created, updated: item.updated,
                project: item.project.map { .init(projectID: $0.projectID, path: $0.path, name: $0.name, exists: $0.exists,
                                                  open: $0.projectID == projectID) })
        }
        return AgentLibrary(revision: library.revision, folder: libraryFolderURL?.path,
                            stages: ContentStage.allCases.map(\.rawValue), topics: library.topics,
                            selectedIdea: selectedIdeaID, module: module.rawValue,
                            openProject: .init(projectID: projectID, path: projectURL?.path, idea: openProjectIdea?.id),
                            history: .init(undo: step(libraryUndoEntries.last), redo: step(libraryRedoEntries.last)),
                            ideas: ideas)
    }

    /// `libraryApply`: 1–100 Library commands as one undo step, all or nothing, against
    /// the revision the agent read. Images are copied in only once everything else checks.
    func agentLibraryApply(_ request: AgentRequest, data: Data) -> Result<AgentLibraryReceipt, EditError> {
        guard let expected = request.expectedRevision else {
            return .failure(EditError(code: .invalidRequest, message: "Include expectedRevision: the Library revision you read (method library)."))
        }
        let body: LibraryRequestBody
        do { body = try AgentProtocol.decoder.decode(LibraryRequestBody.self, from: data) }
        catch { return .failure(EditError(code: .invalidRequest, message: "The commands could not be read: \(Self.describe(error))")) }
        guard let wires = body.commands, (1...100).contains(wires.count) else {
            return .failure(EditError(code: .invalidRequest, message: "Send 1 to 100 commands."))
        }
        let origin = agentOrigin(request)
        let label = request.label.map { String($0.prefix(80)) }
        let dryRun = request.dryRun ?? false

        // Resolve every command first, with the images it would copy, so a mistake in the
        // last command leaves nothing behind.
        var planned: [(command: LibraryCommand, images: [URL])] = []
        do {
            for (index, wire) in wires.enumerated() {
                do { planned.append(try resolveLibrary(wire)) }
                catch let error as EditError { throw EditError(code: error.code, message: "Command \(index + 1) (\(wire.type)): \(error.message)") }
            }
        } catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid(error.localizedDescription)) }

        func commands(_ names: [[String]]) -> [LibraryCommand] {
            zip(planned, names).map { plan, names in
                switch plan.command {
                case .addIdea(var item): item.images = names; return .addIdea(item)
                case .addImages(let id, _): return .addImages(id: id, names: names)
                default: return plan.command
                }
            }
        }
        // Stand-in names check the counts and the rest without copying anything.
        let standIns = planned.map { $0.images.map { UUID().uuidString + "." + $0.pathExtension.lowercased() } }
        let preview: LibraryReceipt
        switch performLibrary(commands(standIns), label: label, origin: origin, expectedRevision: expected, dryRun: true) {
        case .success(let receipt): preview = receipt
        case .failure(let error): return .failure(error)
        }
        if dryRun || !preview.changed {
            return .success(.init(revision: preview.revision, transactionID: nil, changed: preview.changed, dryRun: dryRun,
                                  createdIDs: preview.createdIDs, changedIDs: preview.changedIDs))
        }
        let folder = libraryImagesFolder
        if folder == nil, planned.contains(where: { !$0.images.isEmpty }) {
            return .failure(.invalid("The Library is not loaded, so it cannot keep images."))
        }
        var copied: [[String]] = []
        do { for plan in planned { copied.append(plan.images.isEmpty ? [] : try LibraryImages.copy(plan.images, into: folder!)) } }
        catch {
            for name in copied.joined() { if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) } }
            return .failure(error as? EditError ?? .invalid(error.localizedDescription))
        }
        switch performLibrary(commands(copied), label: label, origin: origin, expectedRevision: expected) {
        case .success(let receipt):
            return .success(.init(revision: receipt.revision, transactionID: receipt.transactionID, changed: receipt.changed,
                                  dryRun: false, createdIDs: receipt.createdIDs, changedIDs: receipt.changedIDs))
        case .failure(let error):
            for name in copied.joined() { if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) } }
            return .failure(error)
        }
    }

    /// One wire command as a Library command, with the image files it would add.
    private func resolveLibrary(_ wire: LibraryWireCommand) throws -> (command: LibraryCommand, images: [URL]) {
        func idea() throws -> UUID {
            guard let id = wire.ideaID else { throw EditError(code: .invalidRequest, message: "This command needs ideaID from the Library's ideas[].id.") }
            return id
        }
        func images() throws -> [URL] {
            let urls = (wire.paths ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            if let problem = urls.lazy.compactMap(LibraryImages.problem).first { throw EditError.invalid(problem) }
            return urls
        }
        switch wire.type {
        case "addIdea":
            guard let title = wire.title else { throw EditError(code: .invalidRequest, message: "addIdea needs a title.") }
            let item = ContentItem(id: wire.ideaID ?? UUID(), title: title, notes: wire.notes ?? "", topic: wire.topic,
                                   links: wire.links ?? [])
            return (.addIdea(item), try images())
        case "updateIdea":
            // A topic of "" clears it: .some(nil). Left out, it stays: nil.
            var topic: String?? = nil
            if let text = wire.topic { topic = .some(text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text) }
            guard wire.title != nil || wire.notes != nil || topic != nil || wire.links != nil else {
                throw EditError(code: .invalidRequest, message: "updateIdea needs at least one of title, notes, topic (\"\" clears it) or links.")
            }
            return (.updateIdea(id: try idea(), title: wire.title, notes: wire.notes, topic: topic, links: wire.links), [])
        case "removeIdea":
            return (.removeIdea(id: try idea()), [])
        case "addIdeaImages":
            let id = try idea()
            let urls = try images()
            guard !urls.isEmpty else { throw EditError(code: .invalidRequest, message: "addIdeaImages needs paths: local image files.") }
            return (.addImages(id: id, names: []), urls)
        case "removeIdeaImage":
            guard let image = wire.image else { throw EditError(code: .invalidRequest, message: "removeIdeaImage needs image: a name from the idea's images[].name.") }
            return (.removeImage(id: try idea(), name: image), [])
        case "linkProject":
            let id = try idea()
            if let path = wire.path {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let data = try? Data(contentsOf: url) else { throw EditError.notFound("There is no project file at \(url.path).") }
                guard let found = try? VideoProject.decodeMigrating(from: data), let projectID = found.projectID else {
                    throw EditError.invalid("\(url.lastPathComponent) is not a YamVideo project this version can read.")
                }
                return (.linkProject(id: id, link: ProjectLink(projectID: projectID, path: url.path)), [])
            }
            guard let url = projectURL else {
                throw EditError.invalid("The project open in Studio has not been saved yet. Save it first (method save with a path), or give path.")
            }
            return (.linkProject(id: id, link: ProjectLink(projectID: projectID, path: url.path)), [])
        case "unlinkProject":
            return (.linkProject(id: try idea(), link: nil), [])
        default:
            throw EditError(code: .invalidRequest, message: "Unknown Library command \"\(wire.type)\". Commands: \(LibraryWireCommand.types.joined(separator: ", ")).")
        }
    }

    func agentLibraryHistory(_ request: AgentRequest, redo: Bool) -> Result<AgentLibraryReceipt, EditError> {
        guard let transaction = request.transactionID, let expected = request.expectedRevision else {
            return .failure(EditError(code: .invalidRequest, message: "Include transactionID (from libraryApply or library.history) and expectedRevision."))
        }
        let origin = agentOrigin(request)
        let result = redo ? libraryRedo(origin: origin, expectedTransaction: transaction, expectedRevision: expected)
                          : libraryUndo(origin: origin, expectedTransaction: transaction, expectedRevision: expected)
        return result.map { .init(revision: $0.revision, transactionID: $0.transactionID, changed: $0.changed, dryRun: false,
                                  createdIDs: [], changedIDs: $0.changedIDs) }
    }
}
