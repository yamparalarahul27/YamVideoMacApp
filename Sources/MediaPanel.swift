import AppKit
import SwiftUI

/// The left panel, as Filmora's media panel: tabs for the recordings, graphics, logos and
/// effects. **+** adds an item at the playhead; drag one onto the timeline to add it where
/// you let go.
struct MediaPanel: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("mediaPanelTab") private var tab: Tab = .media

    enum Tab: String, CaseIterable, Identifiable {
        case media, graphics, logos, effects
        var id: String { rawValue }
        var label: String {
            switch self {
            case .media: return "Media"
            case .graphics: return "Graphics"
            case .logos: return "Logos"
            case .effects: return "Effects"
            }
        }
        var symbol: String {
            switch self {
            case .media: return "photo.on.rectangle"
            case .graphics: return "textformat"
            case .logos: return "seal"
            case .effects: return "sparkles"
            }
        }
    }

    /// One thing to add: what it is, and a line that says what it does.
    struct Entry: Identifiable {
        let asset: MediaAsset
        let title: String
        let detail: String
        let symbol: String
        var id: String { asset.id }
    }

    private var canAdd: Bool { model.selectedItem?.info != nil && !model.isMovieMode && !model.isConverting }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            switch tab {
            case .media: media
            case .graphics: graphics
            case .logos: LogosTab(canAdd: canAdd)
            case .effects: effects
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 14)).frame(height: 18)
                        Text(item.label).font(.system(size: 10.5, weight: tab == item ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8).padding(.bottom, 6)
                    .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(tab == item ? Color.accentColor : Color.clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
    }

    // MARK: Media

    private var media: some View {
        VStack(spacing: 0) {
            QueueSidebar()
            if let item = model.selectedItem, item.info != nil, !model.isMovieMode {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "macwindow").foregroundStyle(.secondary)
                    if let screen = item.screen {
                        Text(screen.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                            .help("The screen recording shown with this recording. Change it in the Video tab's Screen section.")
                    } else {
                        Button("Add Screen Recording…") { model.chooseScreenRecording() }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Show a screen recording with this recording: the speaker in a bubble on the screen, or beside it")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
        }
    }

    // MARK: Graphics and effects

    private var graphics: some View { GraphicsGalleryTab(canAdd: canAdd) }

    private var effects: some View {
        var list = [
            Entry(asset: .blurArea, title: "Blur area", detail: "Hide part of the picture for the whole video", symbol: "eye.slash"),
            Entry(asset: .fullFrameBlur, title: "Full-frame blur", detail: "Blur everything for a moment, with fades", symbol: "camera.filters"),
            Entry(asset: .zoom, title: "Zoom", detail: "An eased push-in at the playhead", symbol: "plus.magnifyingglass"),
        ]
        if model.selectedItem?.screen != nil {
            list.append(Entry(asset: .screenZoom, title: "Screen zoom", detail: "A push-in on the screen recording", symbol: "macwindow"))
        }
        list.append(Entry(asset: .marker, title: "Marker", detail: "A named flag on the ruler (M)", symbol: "flag"))
        return entries(list, footer: nil)
    }

    private func entries(_ list: [Entry], footer: AnyView?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list) { entry in row(entry) }
                if let footer { footer.padding(.top, 4) }
                Text(canAdd ? "Click + to add at the playhead, or drag onto the timeline."
                     : "Select a recording to add these.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(8)
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.callout.weight(.medium))
                Text(entry.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button { model.add(entry.asset) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                .buttonStyle(.borderless)
                .disabled(!canAdd)
                .help("Add \(entry.title.lowercased()) at the playhead")
                .accessibilityLabel("Add \(entry.title.lowercased()) at the playhead")
        }
        .padding(7)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .draggable(entry.asset.dragText) {
            Label(entry.title, systemImage: entry.symbol)
                .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityElement(children: .contain)
    }
}

/// The logo library, the same one Find Brands fills: each logo adds a badge next to the
/// speaker.
private struct LogosTab: View {
    @EnvironmentObject var model: AppModel
    let canAdd: Bool
    @State private var library = LogoLibrary.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if library.isEmpty {
                    Text("No logos yet. Find Brands, in the Video tab's Graphics section, adds a logo for each brand you name.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(library, id: \.name) { logo in tile(logo) }
                    }
                }
                HStack {
                    Button("Show Logo Folder") { NSWorkspace.shared.open(LogoLibrary.folder) }
                    Spacer()
                    Button { library = LogoLibrary.load() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Read the logo folder again")
                }
                .buttonStyle(.borderless).font(.caption)
                Text(canAdd ? "Click a logo to add its badge at the playhead, or drag it onto the timeline."
                     : "Select a recording to add these.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(8)
        }
        .onAppear { library = LogoLibrary.load() }
    }

    private func tile(_ logo: LogoLibrary.Logo) -> some View {
        Button { model.add(.logo(logo.name)) } label: {
            VStack(spacing: 5) {
                Group {
                    if let image = NSImage(contentsOfFile: LogoLibrary.path(of: logo)) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(6)
                    } else {
                        Text(String(logo.name.prefix(1))).font(.title2.weight(.bold)).foregroundStyle(.black)
                    }
                }
                .frame(width: 44, height: 44)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                Text(logo.name).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .help("Add a \(logo.name) badge at the playhead")
        .draggable(MediaAsset.logo(logo.name).dragText) {
            Text(logo.name).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Over the Preview while the gallery shows a draft: what it is, and Add or Done.
struct GalleryDraftBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let sample = model.galleryDraftSample {
            HStack(spacing: 10) {
                Text("\(sample.title) · \(model.galleryLook.label)").font(.caption.weight(.semibold))
                Text("A look, not in the project").font(.caption2).foregroundStyle(.secondary)
                Button("Add") { model.addFromGallery(sample) }
                    .controlSize(.small).keyboardShortcut(.defaultAction)
                    .help("Add it at the playhead")
                Button("Done") { model.galleryDraft = nil }
                    .controlSize(.small).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
        }
    }
}

/// The graphics gallery (docs/plans/graphics-gallery.md): each kind as a picture in the
/// recording's style. A click shows it on the Preview at the playhead without a change to
/// the project; **+** adds it there.
private struct GraphicsGalleryTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var pictures = GalleryPictures.shared
    let canAdd: Bool

    var body: some View {
        let style = model.galleryStyle
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("Look", selection: $model.galleryLook) {
                        ForEach(GalleryLook.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("How the pictures draw. Ink writes the panel kinds by hand; cards stay glass.")
                    Spacer(minLength: 0)
                    Circle().fill(Color(nsColor: NSColor(hex: style.accent) ?? .systemPink)).frame(width: 14, height: 14)
                        .help("The accent of this recording's graphics: \(style.accent)")
                }
                ForEach(GallerySample.Group.allCases) { group in
                    let samples = GallerySample.all.filter { $0.group == group }
                    if !samples.isEmpty {
                        Text(group.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(samples) { sample in tile(sample, style: style) }
                        }
                    }
                }
                Button { model.chooseGraphicsFile() } label: { Label("Import Graphics File…", systemImage: "square.and.arrow.down") }
                    .controlSize(.small)
                    .disabled(!canAdd)
                    .help("A graphics.json from an agent or another project")
                    .padding(.top, 4)
                Text(canAdd ? "Click a picture to see it on the Preview. + adds it at the playhead, or drag it onto the timeline."
                     : "Select a recording to add these.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
        .onAppear { model.openGallery() }
        .onDisappear { model.galleryDraft = nil }
    }

    private func tile(_ sample: GallerySample, style: GraphicsStyle) -> some View {
        let shown = model.galleryDraft?.sample == sample.id
        let look = model.galleryLook
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = pictures.picture(sample, style: style, look: look) {
                        Image(nsImage: image).resizable()
                    } else {
                        Rectangle().fill(Color.black.opacity(0.35)).overlay(ProgressView().controlSize(.small))
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                Button { model.addFromGallery(sample) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain).padding(5)
                .disabled(!canAdd)
                .help("Add \(sample.title.lowercased()) at the playhead")
                .accessibilityLabel("Add \(sample.title.lowercased()) at the playhead")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(sample.title).font(.caption.weight(.semibold))
                Text(sample.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(shown ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: shown ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if canAdd { model.toggleGalleryDraft(sample) } }
        .help(sample.help)
        .draggable(sample.asset.dragText) {
            Label(sample.title, systemImage: "rectangle.on.rectangle")
                .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .task(id: sample.pictureKey(style: style, look: look)) { pictures.request(sample, style: style, look: look) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sample.title)
    }
}
