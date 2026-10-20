import AppKit
import SwiftUI

/// Publish: what YouTube gets for the selected recording, checked against YouTube's rules,
/// with the video shown as YouTube shows it, and Export for YouTube.
struct PublishSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 0 shows the watch page first, 1 the search result.
    var initialPreview = 0

    var body: some View {
        Group {
            if let item = model.selectedItem, item.info != nil {
                PublishContent(item: item, publish: item.publish ?? PublishInfo(), initialPreview: initialPreview,
                               target: model.showsShort || model.inspectorFocus == .short ? model.selectedShortID : nil, close: { dismiss() })
            } else {
                VStack(spacing: 12) {
                    Text("Select a recording to publish.").foregroundStyle(.secondary)
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .frame(width: 420, height: 160)
            }
        }
    }
}

private struct PublishContent: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let publish: PublishInfo
    let initialPreview: Int
    /// The Short being published, or nil for the video itself.
    @State var target: UUID?
    let close: () -> Void

    private var short: Short? { item.short(target) }
    private var issues: [PublishInfo.Issue] {
        short.map { item.shortIssues($0) } ?? publish.issues(duration: item.editedDuration, graphics: item.graphics, music: item.effective.music)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Publish").font(.title2.weight(.semibold))
                Text(item.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !item.shorts.isEmpty {
                    Picker("What", selection: $target) {
                        Text("The video").tag(UUID?.none)
                        ForEach(Array(item.shorts.enumerated()), id: \.element.id) { index, short in
                            Text(short.name(index: index)).tag(UUID?.some(short.id))
                        }
                    }
                    .frame(width: 260)
                    .help("The video itself, or one of its Shorts: each has its own title, description and tags")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                if let short {
                    ScrollView { ShortPublishForm(item: item, short: short).padding(18) }
                        .frame(width: 430)
                    Divider()
                    ScrollView { ShortsPlayerPreview(item: item, short: short).padding(18) }
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView { PublishForm(item: item, publish: publish).padding(18) }
                        .frame(width: 430)
                    Divider()
                    ScrollView { YouTubePreview(item: item, publish: publish, page: initialPreview).padding(18) }
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack(spacing: 10) {
                summary
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                if let short {
                    Button("Export Short for YouTube…") {
                        close()
                        DispatchQueue.main.async { model.promptForShortExport(short.id) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isConverting || !model.toolsAvailable || issues.contains { $0.severity == .blocking })
                    .help("Writes the 1080×1920 MP4, its captions, a cover and the upload text into a folder")
                } else {
                    Button("Export for YouTube…") {
                        close()
                        DispatchQueue.main.async { model.promptForYouTubeExport() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isConverting || !model.toolsAvailable || issues.contains { $0.severity == .blocking })
                    .help("Writes the MP4, the captions on the edited timeline, the thumbnail and the upload text into a folder")
                }
            }
            .padding(14)
        }
        .frame(width: 1080, height: 760)
    }

    @ViewBuilder private var summary: some View {
        let blocking = issues.filter { $0.severity == .blocking }.count
        // A Short always carries the related-video note; it is a step, not a problem.
        let warnings = issues.filter { $0.field != "relatedVideo" }.count - blocking
        if blocking == 0, warnings == 0 {
            Label("Ready for YouTube", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        } else {
            Label(blocking > 0 ? "\(blocking) to fix before exporting" + (warnings > 0 ? ", \(warnings) to check" : "")
                               : "\(warnings) to check", systemImage: blocking > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(blocking > 0 ? .red : .orange).font(.caption)
        }
    }
}

// MARK: - The form

private struct PublishForm: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let publish: PublishInfo
    @State private var makingThumbnail = false

    private func issues(_ field: String) -> [PublishInfo.Issue] {
        publish.issues(duration: item.editedDuration, graphics: item.graphics, music: item.effective.music).filter { $0.field == field }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorSection("Title") {
                PublishTextField(placeholder: "What the video is called", value: publish.title, axis: .horizontal) { text in
                    model.setPublish(label: "Video Title") { $0.title = text }
                }
                counter(publish.title.count, of: PublishInfo.titleLimit)
                issueLines("title")
            }
            InspectorSection("Description") {
                PublishTextField(placeholder: "What viewers read under the video", value: publish.description, axis: .vertical) { text in
                    model.setPublish(label: "Video Description") { $0.description = text }
                }
                counter(publish.crediting(item.effective.music).fullDescription.count, of: PublishInfo.descriptionLimit,
                        note: item.effective.music?.creditLines.isEmpty == false ? "with the chapters and music credits" : "with the chapters")
                issueLines("description")
            }
            InspectorSection("Tags") {
                PublishTextField(placeholder: "Comma-separated, like video editing, macOS", value: publish.tags.joined(separator: ", "),
                                 axis: .horizontal) { text in
                    let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.setPublish(label: "Video Tags") { $0.tags = tags }
                }
                counter(publish.tagCharacters, of: PublishInfo.tagsLimit, note: "as YouTube counts them")
                issueLines("tags")
            }
            InspectorSection("Category") {
                Picker("Category", selection: Binding(get: { publish.category },
                                                      set: { value in model.setPublish(label: "Video Category") { $0.category = value } })) {
                    ForEach(YouTubeCategory.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            chapters
            thumbnail
            PublishEndScreenSection(item: item, publish: publish)
            captions
            InspectorSection("Channel") {
                PublishTextField(placeholder: "Your channel's name, for the preview", value: publish.channel, axis: .horizontal) { text in
                    model.setPublish(label: "Channel Name") { $0.channel = text }
                }
            }
        }
    }

    private var chapters: some View {
        InspectorSection("Chapters") {
            ForEach(publish.chapters.sorted { $0.time < $1.time }) { chapter in
                HStack(spacing: 6) {
                    PublishTextField(placeholder: "0:00", value: PublishInfo.timestamp(chapter.time), axis: .horizontal) { text in
                        guard let seconds = PublishInfo.seconds(fromTimestamp: text) else {
                            model.statusMessage = "Write a chapter time like 1:05 or 1:02:03."; return
                        }
                        model.setPublish(label: "Chapter Time") { info in
                            if let index = info.chapters.firstIndex(where: { $0.id == chapter.id }) { info.chapters[index].time = seconds }
                        }
                    }
                    .frame(width: 70)
                    .accessibilityLabel("Chapter time")
                    PublishTextField(placeholder: "Chapter title", value: chapter.title, axis: .horizontal) { text in
                        model.setPublish(label: "Chapter Title") { info in
                            if let index = info.chapters.firstIndex(where: { $0.id == chapter.id }) { info.chapters[index].title = text }
                        }
                    }
                    Button {
                        model.setPublish(label: "Delete Chapter") { $0.chapters.removeAll { $0.id == chapter.id } }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Delete this chapter").accessibilityLabel("Delete chapter \(chapter.title)")
                }
            }
            HStack {
                Button("Add at Playhead") {
                    let time = model.previewTime.rounded(.down)
                    model.setPublish(label: "Add Chapter") { $0.chapters.append(Chapter(time: time, title: "")) }
                }
                Button("Suggest from Markers and Graphics") { model.useSuggestedChapters() }
                    .help("Chapters from named markers and from panel, rule, checklist and title graphics. Replaces the list.")
            }
            .controlSize(.small)
            Text("YouTube shows chapters when the first starts at 0:00, there are at least \(PublishInfo.chapterCount), and each lasts \(Int(PublishInfo.chapterMinimum)) seconds or more. They follow their footage when you cut.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            issueLines("chapters")
        }
    }

    private var thumbnail: some View {
        InspectorSection("Thumbnail") {
            HStack(alignment: .top, spacing: 10) {
                PublishImage(url: publish.thumbnail, fallback: nil)
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 6) {
                    Button("Make Thumbnail…") { makingThumbnail = true }
                        .help("A frame with the speaker cut out, a big title and a tag, made 1280×720")
                    Button("Choose Image…") { model.chooseThumbnail() }
                    Button("Use Frame at Playhead") { model.useFrameAsThumbnail() }
                        .help("Saves the picture at the playhead, graphics included, next to the recording")
                    if publish.thumbnail != nil {
                        Button("Clear") { model.setPublish(label: "Clear Thumbnail") { $0.thumbnail = nil } }
                    }
                }
                .controlSize(.small)
            }
            Text("Exported as a 1280×720 JPEG under 2 MB, the middle of the image at 16:9.")
                .font(.caption2).foregroundStyle(.secondary)
            issueLines("thumbnail")
        }
        .sheet(isPresented: $makingThumbnail) {
            ThumbnailMakerSheet(item: item, playhead: model.previewTime).environmentObject(model)
        }
    }

    private var captions: some View {
        InspectorSection("Captions") {
            let use = model.settings.captionUse(hasFile: item.subtitles != nil)
            if !use.uploads, item.subtitles != nil || item.transcript != nil {
                Text("Captions are off, so none go up with the video. Turn them on under Captions in the inspector or in Auto Edit.")
            } else if let subtitles = item.subtitles {
                if Captions.retimable.contains(subtitles.pathExtension.lowercased()) {
                    Text("\(subtitles.lastPathComponent) goes up as an SRT timed on the edited video, so it stays in step with your cuts.")
                } else {
                    Text("\(subtitles.lastPathComponent) cannot be retimed (only SRT and VTT can), so it is left out of the upload files.")
                        .foregroundStyle(.orange)
                }
            } else if item.captionsSource(model.settings) == "transcript" {
                Text("Captions made from the transcript go up as an SRT on the edited video, without the words you cut.")
            } else {
                Text("No captions yet. Auto Edit makes them from what is said, or choose a file under Captions in the inspector.")
            }
            HStack {
                Text("Language").foregroundStyle(.secondary)
                PublishTextField(placeholder: "en", value: publish.language, axis: .horizontal) { text in
                    model.setPublish(label: "Captions Language") { $0.language = text }
                }
                .frame(width: 80)
            }
        }
        .font(.caption)
    }

    private func counter(_ count: Int, of limit: Int, note: String? = nil) -> some View {
        Text("\(count) / \(limit)" + (note.map { " · \($0)" } ?? ""))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(count > limit ? Color.red : .secondary)
    }

    @ViewBuilder private func issueLines(_ field: String) -> some View {
        ForEach(issues(field), id: \.message) { issue in
            Label(issue.message, systemImage: issue.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Which YouTube element goes in each box of the end screen layout. YouTube's upload cannot
/// place them, so the upload text and JSON say where each goes in Studio.
struct PublishEndScreenSection: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let publish: PublishInfo

    var body: some View {
        let elements = publish.endScreen ?? EndScreenElements()
        func change(_ label: String, _ edit: @escaping (inout EndScreenElements) -> Void) {
            model.setPublish(label: label) { info in
                var value = info.endScreen ?? EndScreenElements()
                edit(&value)
                info.endScreen = value
            }
        }
        return InspectorSection("End Screen") {
            if let screen = item.graphics?.endScreen {
                let layout = EndScreenLayout(props: screen.props)
                Text("From \(PublishInfo.timestamp(screen.start)) to the end (\(String(format: "%.0f", screen.length.rounded())) s). "
                     + "Choose what goes in each box:")
                    .font(.caption)
                Picker("Circle, \(layout.place(of: layout.circle))", selection: Binding(get: { elements.circle },
                                                                                       set: { value in change("End Screen Circle") { $0.circle = value } })) {
                    ForEach(EndScreenElements.Circle.allCases) { Text($0.label).tag($0) }
                }
                if elements.circle == .channel {
                    PublishTextField(placeholder: "The channel's link or @handle", value: elements.channel, axis: .horizontal) { text in
                        change("End Screen Channel") { $0.channel = text }
                    }
                    PublishTextField(placeholder: "Its message, shown with it", value: elements.message, axis: .horizontal) { text in
                        change("End Screen Channel") { $0.message = text }
                    }
                }
                ForEach(Array(layout.cards.enumerated()), id: \.offset) { index, rect in
                    let video = elements.video(index)
                    let name = layout.cards.count == 1 ? "Video" : "Video \(index + 1)"
                    Picker("\(name), \(layout.place(of: rect))", selection: Binding(get: { video.kind }, set: { kind in
                        change("End Screen Video") { value in
                            while value.videos.count <= index { value.videos.append(EndScreenElements.Video()) }
                            value.videos[index].kind = kind
                        }
                    })) {
                        ForEach(EndScreenElements.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    if video.kind.needsLink {
                        HStack(spacing: 6) {
                            PublishTextField(placeholder: video.kind == .video ? "The video's YouTube link" : "The playlist's YouTube link",
                                             value: video.link, axis: .horizontal) { text in
                                change("End Screen Video") { value in
                                    while value.videos.count <= index { value.videos.append(EndScreenElements.Video()) }
                                    value.videos[index].link = text
                                }
                            }
                            PublishTextField(placeholder: "Its title", value: video.title, axis: .horizontal) { text in
                                change("End Screen Video") { value in
                                    while value.videos.count <= index { value.videos.append(EndScreenElements.Video()) }
                                    value.videos[index].title = text
                                }
                            }
                            .frame(width: 140)
                        }
                    }
                }
                Text(EndScreen.apiNote + " The upload text lists each element and its box.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No end screen. Add one to keep the last 5–20 seconds clear for YouTube's Subscribe circle and video cards; "
                     + "the speaker moves into a smaller frame beside them.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Add End Screen") { model.addEndScreen() }
                    .controlSize(.small)
                    .disabled(item.editedDuration < EndScreen.lengths.lowerBound)
            }
            ForEach(publish.issues(duration: item.editedDuration, graphics: item.graphics).filter { $0.field == "endScreen" }, id: \.message) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

/// A field that commits on Return or when it loses focus, so typing is one undo step.
struct PublishTextField: View {
    let placeholder: String
    let value: String
    let axis: Axis
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .lineLimit(axis == .vertical ? 4...12 : 1...1)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .accessibilityLabel(placeholder)
    }

    private func commit() { if text != value { onCommit(text) } }
}

/// An image file, or a stand-in.
struct PublishImage: View {
    let url: URL?
    let fallback: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))
            if let image = url.flatMap({ NSImage(contentsOf: $0) }) ?? fallback {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipped()
    }
}

// MARK: - The preview

/// The video as YouTube shows it: the watch page and a search result, at YouTube's sizes.
private struct YouTubePreview: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let publish: PublishInfo
    @State var page = 0

    private var duration: String { PublishInfo.timestamp(item.editedDuration) }
    private var channel: String { publish.channel.isEmpty ? "Your channel" : publish.channel }
    private var title: String { publish.title.isEmpty ? "Your title" : publish.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Preview", selection: $page) {
                Text("Watch page").tag(0)
                Text("Search result").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            if page == 0 { watchPage } else { searchResult }
            Text("A sketch of YouTube's layout at its real sizes, for checking how the title, thumbnail, description and chapters read. YouTube changes its pages often.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func thumbnail(width: CGFloat) -> some View {
        PublishImage(url: publish.thumbnail, fallback: model.previewImage)
            .frame(width: width, height: width * 9 / 16)
            .overlay(alignment: .bottomTrailing) {
                Text(duration).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var avatar: some View {
        Circle().fill(Color.accentColor.opacity(0.85)).frame(width: 40, height: 40)
            .overlay(Text(String(channel.prefix(1)).uppercased()).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
    }

    private var watchPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnail(width: 560)
            Text(title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                .frame(width: 560, alignment: .leading)
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel).font(.system(size: 16, weight: .semibold))
                    Text("subscribers").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("Subscribe").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.primary, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("0 views  just now").font(.system(size: 14, weight: .semibold))
                let description = publish.crediting(item.effective.music).fullDescription
                Text(description.isEmpty ? "Your description" : description)
                    .font(.system(size: 14)).lineLimit(3)
                Text("...more").font(.system(size: 14, weight: .semibold))
            }
            .padding(12)
            .frame(width: 560, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            if !publish.chapters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chapters").font(.system(size: 16, weight: .bold))
                    if let problem = publish.chapterProblem(duration: item.editedDuration) {
                        Text("Off on YouTube: \(problem)").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(publish.chapters.sorted { $0.time < $1.time }) { chapter in
                        HStack(spacing: 10) {
                            Text(PublishInfo.timestamp(chapter.time)).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(nsColor: .linkColor)).frame(width: 56, alignment: .leading)
                            Text(chapter.title.isEmpty ? "Untitled" : chapter.title).font(.system(size: 14)).lineLimit(1)
                        }
                    }
                }
                .frame(width: 560, alignment: .leading)
            }
        }
    }

    private var searchResult: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnail(width: 360)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 18)).lineLimit(2)
                Text("0 views · just now").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Circle().fill(Color.accentColor.opacity(0.85)).frame(width: 24, height: 24)
                        .overlay(Text(String(channel.prefix(1)).uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                    Text(channel).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Text(publish.description.isEmpty ? "Your description" : publish.description)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                if publish.chapterProblem(duration: item.editedDuration) == nil, publish.chapters.count >= PublishInfo.chapterCount {
                    Text("\(publish.chapters.count) chapters").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 300, alignment: .leading)
        }
    }
}
