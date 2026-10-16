import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The Ideas page: ideas listed by stage on the left, the selected idea's editor on the
// right (the owner chose a list over columns, 2026-10-16). See LibraryEditing.swift for
// the actions and Library.swift for the data.

// MARK: - The sidebar

/// The slim column of modules at the left edge of the window.
struct ModuleSidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AppModule.allCases) { module in
                Button { model.showModule(module) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: module.systemImage).font(.system(size: 17))
                        Text(module.label).font(.caption2)
                    }
                    .frame(width: 58, height: 48)
                    .foregroundStyle(model.module == module ? Color.accentColor : Color.secondary)
                    .background(model.module == module ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(module == .ideas ? "Your ideas, and the projects made from them" : "The editor")
                .accessibilityLabel(module.label)
                .accessibilityAddTraits(model.module == module ? [.isSelected, .isButton] : .isButton)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .frame(width: 68)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}

// MARK: - The page

struct IdeasPage: View {
    @EnvironmentObject var model: AppModel
    /// Nil shows every topic.
    @State private var topic: String?

    var body: some View {
        HSplitView {
            IdeasList(topic: $topic)
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 340)
            Group {
                if let item = model.library.item(model.selectedIdeaID) {
                    IdeaEditor(item: item).id(item.id)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        }
        .onChange(of: model.library.topics) { _, topics in
            if let topic, !topics.contains(topic) { self.topic = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "lightbulb").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
            Text(model.library.items.isEmpty ? "Start your first idea" : "Select an idea").font(.headline)
            Text("Write down what the video is about, with links and pictures. When it is time to record, start a project from it.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if model.library.items.isEmpty {
                Button("New Idea") { model.newIdea() }.padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The list

private struct IdeasList: View {
    @EnvironmentObject var model: AppModel
    @Binding var topic: String?

    private var shown: [ContentItem] {
        guard let topic else { return model.library.items }
        return model.library.items.filter { $0.topic == topic }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button("All topics") { topic = nil }
                    if !model.library.topics.isEmpty { Divider() }
                    ForEach(model.library.topics, id: \.self) { name in Button(name) { topic = name } }
                } label: {
                    Label(topic ?? "All topics", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Show the ideas of one topic")
                Spacer()
                Text("\(shown.count) idea\(shown.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            List(selection: $model.selectedIdeaID) {
                ForEach(ContentStage.allCases) { stage in
                    let items = shown.filter { $0.stage == stage }
                    if !items.isEmpty {
                        Section("\(stage.label) · \(items.count)") {
                            ForEach(items) { item in
                                IdeaRow(item: item, agentNote: model.libraryHighlight?.items.contains(item.id) == true
                                        ? model.libraryHighlight?.origin : nil)
                                    .tag(item.id)
                                    .contextMenu {
                                        if item.project != nil { Button("Open in Studio") { model.openLinkedProject(item.id) } }
                                        Button("Delete Idea") { model.deleteIdea(item.id) }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand { if let id = model.selectedIdeaID { model.deleteIdea(id) } }
            Divider()
            HStack(spacing: 6) {
                Button { model.newIdea() } label: { Image(systemName: "plus") }.help("New idea (⌥⌘N)")
                Button { if let id = model.selectedIdeaID { model.deleteIdea(id) } } label: { Image(systemName: "minus") }
                    .disabled(model.selectedIdeaID == nil).help("Delete the selected idea")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }
}

private struct IdeaRow: View {
    let item: ContentItem
    /// Names the agent that just changed this idea, for a moment.
    var agentNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.callout).lineLimit(1)
            HStack(spacing: 6) {
                if let topic = item.topic { TopicChip(topic: topic) }
                if let project = item.project {
                    // The project is usually named after the idea; then "Project" says enough.
                    Label(project.name == item.title ? "Project" : project.name,
                          systemImage: project.exists ? "film" : "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(project.exists ? Color.secondary : Color.orange).lineLimit(1)
                }
            }
            if let agentNote {
                Label("\(agentNote) edited", systemImage: "sparkles").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct TopicChip: View {
    let topic: String

    var body: some View {
        Text(topic)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.purple.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.purple)
    }
}

// MARK: - The editor

private struct IdeaEditor: View {
    @EnvironmentObject var model: AppModel
    let item: ContentItem

    private enum Field: Hashable { case title, topic, notes, link }
    @FocusState private var focus: Field?
    @State private var title = ""
    @State private var topic = ""
    @State private var notes = ""
    @State private var newLink = ""
    @State private var notesCommit: Task<Void, Never>?
    @State private var dropTarget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($focus, equals: .title)
                    .onSubmit(commitTitle)
                    .accessibilityLabel("Idea title")

                InspectorSection("Topic") { topicField }
                InspectorSection("Notes") {
                    TextEditor(text: $notes)
                        .font(.body)
                        .focused($focus, equals: .notes)
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                        .accessibilityLabel("Notes")
                    Text("The hook, the points to make, why it matters.").font(.caption).foregroundStyle(.secondary)
                }
                InspectorSection("Links") { links }
                InspectorSection("Images") { images }
                InspectorSection("Project") { project }

                HStack {
                    Text("Created \(item.created.formatted(date: .abbreviated, time: .shortened)) · Changed \(item.updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete Idea", role: .destructive) { model.deleteIdea(item.id) }.controlSize(.small)
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            title = item.title; topic = item.topic ?? ""; notes = item.notes
            if model.focusIdeaTitle { focusTitle() }
        }
        .onChange(of: model.focusIdeaTitle) { _, ask in if ask { focusTitle() } }
        // Someone else (an agent, Undo) changed the idea: show it unless it is being typed.
        .onChange(of: item.title) { _, value in if focus != .title { title = value } }
        .onChange(of: item.topic) { _, value in if focus != .topic { topic = value ?? "" } }
        .onChange(of: item.notes) { _, value in if focus != .notes { notes = value } }
        .onChange(of: notes) { _, value in
            guard focus == .notes, value != item.notes else { return }
            notesCommit?.cancel()
            notesCommit = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                commitNotes()
            }
        }
        .onChange(of: focus) { old, _ in
            switch old {
            case .title: commitTitle()
            case .topic: commitTopic()
            case .notes: notesCommit?.cancel(); commitNotes()
            default: break
            }
        }
        .onDisappear { commitTitle(); commitTopic(); notesCommit?.cancel(); commitNotes() }
    }

    // MARK: Fields

    /// After New Idea: the cursor in the title with "New idea" selected, to type over.
    private func focusTitle() {
        model.focusIdeaTitle = false
        focus = .title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != item.title else { return }
        guard !trimmed.isEmpty else { title = item.title; model.statusMessage = "An idea needs a title."; return }
        model.editIdea(item.id, title: String(trimmed.prefix(ContentItem.titleLimit)))
    }

    private func commitTopic() {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (item.topic ?? "") else { return }
        model.editIdea(item.id, topic: .some(trimmed.isEmpty ? nil : String(trimmed.prefix(ContentItem.topicLimit))))
        topic = model.library.item(item.id)?.topic ?? ""
    }

    private func commitNotes() {
        guard notes != item.notes, model.library.item(item.id) != nil else { return }
        model.editIdea(item.id, notes: String(notes.prefix(ContentItem.notesLimit)))
    }

    private var topicField: some View {
        HStack(spacing: 6) {
            TextField("What it is about, like AI workflow", text: $topic)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .topic)
                .onSubmit(commitTopic)
                .frame(maxWidth: 300)
                .accessibilityLabel("Topic")
            let others = model.library.topics.filter { $0 != item.topic }
            if !others.isEmpty {
                Menu {
                    ForEach(others, id: \.self) { name in
                        Button(name) { topic = name; commitTopic() }
                    }
                    if item.topic != nil {
                        Divider()
                        Button("No Topic") { topic = ""; commitTopic() }
                    }
                } label: { Text("Topics") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Use a topic another idea has, so they group together")
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.links, id: \.self) { link in
                HStack(spacing: 6) {
                    Button {
                        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(link, systemImage: "link").lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Open in your browser")
                    Spacer(minLength: 4)
                    Button { model.removeIdeaLink(item.id, link) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Remove this link").accessibilityLabel("Remove link")
                }
            }
            HStack(spacing: 6) {
                TextField("Paste a link to a video, an article or a post", text: $newLink)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .link)
                    .onSubmit(addLink)
                    .accessibilityLabel("New link")
                Button("Add", action: addLink).disabled(newLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addLink() {
        if model.addIdeaLink(item.id, newLink) { newLink = "" }
    }

    private var images: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(item.images, id: \.self) { name in
                    if let url = model.libraryImageURL(name) {
                        IdeaThumbnail(url: url)
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Remove from Idea") { model.removeIdeaImage(item.id, name) }
                            }
                            .help("Double-click to open")
                    }
                }
                Button { model.promptForIdeaImages(item.id) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(item.images.isEmpty ? "Add or drop images" : "Add").font(.caption)
                    }
                    .frame(maxWidth: .infinity).frame(height: 84)
                    .foregroundStyle(.secondary)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.tertiary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose images, or drop them here. They are copied into the Library.")
            }
            HStack(spacing: 8) {
                Button("Paste Image") { model.pasteIdeaImage(item.id) }.controlSize(.small)
                    .help("Add the screenshot or image you copied")
                Text("Screenshots, references, thumbnail ideas.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .background(dropTarget ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTarget) { providers in
            receive(providers)
            return true
        }
    }

    /// Dropped files, or image data dragged from a browser.
    private func receive(_ providers: [NSItemProvider]) {
        let id = item.id
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        if case .failure(let error) = model.addIdeaImages([url], to: id) { model.statusMessage = error.message }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let data else { return }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped \(UUID().uuidString).png")
                    guard (try? data.write(to: file)) != nil else { return }
                    Task { @MainActor in
                        if case .failure(let error) = model.addIdeaImages([file], to: id) { model.statusMessage = error.message }
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
        }
    }

    @ViewBuilder private var project: some View {
        if let link = item.project {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: link.exists ? "film" : "exclamationmark.triangle")
                        .foregroundStyle(link.exists ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.name).font(.callout.weight(.medium))
                        Text(link.exists ? link.path : "Not found at \(link.path)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack(spacing: 8) {
                    if link.exists {
                        Button(link.projectID == model.projectID ? "Show in Studio" : "Open in Studio") { model.openLinkedProject(item.id) }
                            .buttonStyle(.borderedProminent)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([link.url]) }
                    } else {
                        Button("Locate…") { model.locateLinkedProject(item.id) }.buttonStyle(.borderedProminent)
                    }
                    Button("Unlink") { model.unlinkProject(item.id) }
                        .help("The idea goes back to being only an idea; the project file is untouched")
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button("Start a Project from This Idea…") { model.startProject(from: item.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isConverting)
                    .help("Saves a new project named after the idea, links it here and opens Studio to add the recordings")
                let open = model.openProjectIdea
                Button("Link the Open Project") { model.linkOpenProject(to: item.id) }
                    .controlSize(.small)
                    .disabled(model.items.isEmpty || open != nil)
                    .help(open.map { "The open project already belongs to \"\($0.title)\"." }
                          ?? (model.items.isEmpty ? "Open a project in Studio first." : "Link \(openProjectName) to this idea"))
                Text("A project made from an idea shows it in Studio, and opens from here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var openProjectName: String {
        model.projectURL?.deletingPathExtension().lastPathComponent ?? "the open project"
    }
}

/// A small copy of an image, read off the main thread.
private struct IdeaThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        // The image fills a fixed box and is cut to it, so it never spills into its neighbour.
        Color(nsColor: .quaternaryLabelColor)
            .frame(maxWidth: .infinity).frame(height: 84)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 400,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
        .accessibilityLabel("Image")
    }
}
