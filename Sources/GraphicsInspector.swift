import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The selected graphic: where it sits in time, its look, and every text, time and image
/// in its template data. The fields come from the data, so a new template field shows up
/// here without new code.
struct GraphicInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let graphic: Graphic

    var body: some View {
        InspectorSection("\(graphic.kind.label) at \(timelineTime(graphic.start))") {
            if graphic.kind.hasInk {
                Picker("Look", selection: Binding(get: { graphic.look }, set: { model.setGraphicLook(graphic.id, $0) })) {
                    Text("Style (\(item.graphics?.look(of: Graphic(kind: graphic.kind, start: 0, end: 1)).label ?? "Glass cards"))")
                        .tag(GraphicsLook?.none)
                    Text("Glass").tag(GraphicsLook?.some(.glass))
                    Text("Ink").tag(GraphicsLook?.some(.ink))
                }
                .accessibilityLabel("Look of this graphic")
            }
            HStack(spacing: 12) {
                TimelineTimeField(label: "From", value: graphic.start) {
                    model.setGraphicEdge(graphic.id, start: $0)
                    return model.selectedGraphic?.start ?? graphic.start
                }
                if graphic.kind == .endScreen {
                    Text(String(format: "to the end (%.1f s)", graphic.length)).foregroundStyle(.secondary)
                } else {
                    TimelineTimeField(label: "to", value: graphic.end) {
                        model.setGraphicEdge(graphic.id, end: $0)
                        return model.selectedGraphic?.end ?? graphic.end
                    }
                }
            }
            .font(.caption)
            HStack {
                Button("Move to Playhead") { model.moveSelectedGraphicToPlayhead() }
                Button("Show It") { model.showGraphic(graphic) }
                Spacer()
                Button(role: .destructive) { model.removeSelectedGraphic() } label: { Label("Delete", systemImage: "trash") }
            }
            .controlSize(.small)
            if graphic.kind == .endScreen {
                endScreen
            } else {
                placement
                Text("Times inside the graphic are seconds after it starts.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            GraphicPropsEditor(graphicID: graphic.id, value: .object(graphic.props), path: [], depth: 0,
                               hidden: graphic.kind == .endScreen ? ["videos", "side", "guides"] : [])
        }
    }
}

extension GraphicInspector {
    /// The end screen's boxes: how many video cards, and which side the speaker takes.
    var endScreen: some View {
        let layout = EndScreenLayout(props: graphic.props)
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Video boxes", selection: Binding(get: { layout.videos }, set: { model.setEndScreenLayout(graphic.id, videos: $0) })) {
                Text("One").tag(1)
                Text("Two").tag(2)
            }
            .pickerStyle(.segmented)
            Picker("Speaker", selection: Binding(get: { layout.side }, set: { model.setEndScreenLayout(graphic.id, side: $0) })) {
                ForEach(EndScreenLayout.Side.allCases) { Text($0 == .left ? "Left" : "Right").tag($0) }
            }
            .pickerStyle(.segmented)
            Text("The speaker moves into the frame and the boxes stay empty where YouTube puts its end screen elements: "
                 + "the Subscribe circle and \(layout.videos == 1 ? "a video card" : "two video cards"). Choose what goes in each "
                 + "box in Publish; YouTube Studio is where they are placed, since YouTube's upload cannot set them.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension GraphicInspector {
    /// Where the graphic sits on the picture: a move from its place in the template, in
    /// design pixels of a 1920-wide frame, and its size.
    var placement: some View {
        let transform = graphic.transform ?? GraphicTransform()
        func place(_ change: (inout GraphicTransform) -> Void) {
            var edited = transform
            change(&edited)
            if let problem = edited.problem { model.statusMessage = problem; return }
            model.placeGraphic(graphic.id, edited)
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                CommitNumberField(label: "Across", value: transform.x) { value in place { $0.x = value.rounded() } }
                CommitNumberField(label: "Down", value: transform.y) { value in place { $0.y = value.rounded() } }
            }
            HStack(spacing: 10) {
                CommitNumberField(label: "Size %", value: (transform.scale * 100).rounded()) { value in place { $0.scale = value / 100 } }
                Spacer()
                Button("Reset Position") { model.resetGraphicPlace(graphic.id) }
                    .controlSize(.small)
                    .disabled(graphic.transform == nil)
            }
            Text("In Preview, drag the graphic to move it or a corner to resize it; ⌥ turns snapping off, and ⌥ arrow keys nudge it. Across and down are pixels of a 1920-wide frame.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The recording's graphics: how many, import, and the shared style.
struct GraphicsSection: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem

    private var style: GraphicsStyle { item.graphics?.style ?? GraphicsStyle() }

    var body: some View {
        InspectorSection("Graphics") {
            let count = item.graphics?.items.count ?? 0
            Text(count == 0
                 ? "None. Import a graphics file to add titles, cards and ink notes over the video."
                 : "\(count) graphic\(count == 1 ? "" : "s"). Select one on the timeline to change it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Import…") { model.chooseGraphicsFile() }
                    .help("Load a graphics file (graphics.json) onto this recording")
                Button("End Screen") { model.addEndScreen() }
                    .disabled(item.graphics?.endScreen != nil || item.editedDuration < EndScreen.lengths.lowerBound)
                    .help("Add YouTube's end screen layout to the last 5–20 seconds: the speaker in a frame, with boxes kept clear for YouTube's elements")
                Spacer()
                Button("Clear All") {
                    model.perform([.replaceGraphics(clip: item.id, graphics: [], style: nil)], label: "Clear Graphics")
                }
                .disabled(count == 0)
            }
            .controlSize(.small)
            BrandFinderView(item: item)
            if count > 0 {
                Picker("Look", selection: styleBinding(\.look)) {
                    ForEach(GraphicsLook.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { style.size ?? 1 }, set: { value in
                        model.setGraphicsStyle { $0.size = abs(value - 1) < 0.0005 ? nil : value }
                    }), in: GraphicsStyle.sizes, step: 0.05)
                        .accessibilityLabel("Size of cards and panels")
                    Text("\(Int(((style.size ?? 1) * 100).rounded()))%").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                .help("Larger cards and panels read better on a phone. Cards grow to the left from the column's right edge; panels grow half as much. Logo badges, the end screen and Shorts keep their sizes.")
                Picker("Panel", selection: styleBinding(\.panel)) {
                    ForEach(PanelStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Move the video aside for panels", isOn: styleBinding(\.moveVideo))
                if style.panel == .shade {
                    HStack {
                        Text("Soft edge").font(.caption).foregroundStyle(.secondary)
                        Slider(value: styleBinding(\.edge), in: 0...400, step: 10)
                            .accessibilityLabel("Soft edge of the shade, in pixels")
                        Text("\(Int(style.edge)) px").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                ColorPicker("Accent", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: style.accent) ?? .systemYellow) },
                    set: { color in model.setGraphicsStyle { $0.accent = NSColor(color).hexString } }),
                    supportsOpacity: false)
                Text("Preview shows the graphics over the video, and exports draw them in.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func styleBinding<Value>(_ path: WritableKeyPath<GraphicsStyle, Value>) -> Binding<Value> {
        Binding(get: { style[keyPath: path] }, set: { value in model.setGraphicsStyle { $0[keyPath: path] = value } })
    }
}

/// Text, numbers, images and lists in a graphic's template data, as fields.
private struct GraphicPropsEditor: View {
    @EnvironmentObject var model: AppModel
    let graphicID: UUID
    let value: JSONValue
    let path: [GraphicPropPath]
    let depth: Int
    /// Top-level keys the inspector shows in its own way.
    var hidden: Set<String> = []

    /// Fields people read first come first; the rest follow alphabetically.
    private static let order = ["kicker", "number", "title", "subtitle", "detail", "from", "to", "url",
                                "question", "text", "button", "toast", "footer", "type", "image"]

    var body: some View {
        switch value {
        case .object(let fields):
            ForEach(Self.sortedKeys(fields).filter { !hidden.contains($0) }, id: \.self) { key in
                field(key: key, value: fields[key]!, path: path + [.key(key)])
            }
        case .array(let elements):
            ForEach(Array(elements.indices), id: \.self) { index in
                element(index: index, value: elements[index])
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func field(key: String, value: JSONValue, path: [GraphicPropPath]) -> some View {
        let label = Self.label(for: key)
        switch value {
        case .string(let text):
            if key == "image" {
                ImageField(label: label, path: text) { model.setGraphicProp(graphicID, at: path, to: .string($0)) }
            } else if key != "type" && key != "tone" && key != "icon" {
                CommitTextField(label: label, value: text) { model.setGraphicProp(graphicID, at: path, to: .string($0)) }
            }
        case .number(let number):
            CommitNumberField(label: Self.isBeat(key) ? "\(label) (s)" : label, value: number) {
                model.setGraphicProp(graphicID, at: path, to: .number($0))
            }
        case .bool(let flag):
            Toggle(label, isOn: Binding(get: { flag }, set: { model.setGraphicProp(graphicID, at: path, to: .bool($0)) }))
                .font(.caption)
        case .object, .array:
            if depth < 4 {
                DisclosureGroup(label) {
                    VStack(alignment: .leading, spacing: 6) {
                        GraphicPropsEditor(graphicID: graphicID, value: value, path: path, depth: depth + 1)
                    }
                    .padding(.leading, 4)
                }
                .font(.caption)
            }
        case .null:
            EmptyView()
        }
    }

    @ViewBuilder
    private func element(index: Int, value: JSONValue) -> some View {
        let elementPath = path + [.index(index)]
        switch value {
        case .object:
            VStack(alignment: .leading, spacing: 4) {
                Text("Item \(index + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                GraphicPropsEditor(graphicID: graphicID, value: value, path: elementPath, depth: depth + 1)
            }
            .padding(6)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .string(let text):
            CommitTextField(label: "Item \(index + 1)", value: text) {
                model.setGraphicProp(graphicID, at: elementPath, to: .string($0))
            }
        default:
            EmptyView()
        }
    }

    private static func sortedKeys(_ fields: [String: JSONValue]) -> [String] {
        fields.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
    }

    private static func isBeat(_ key: String) -> Bool { key == "at" || key.hasSuffix("At") }

    /// "badgesAt" → "Badges at".
    private static func label(for key: String) -> String {
        if key == "at" { return "Appears at" }
        var words = ""
        for character in key {
            if character.isUppercase, !words.isEmpty { words += " " + character.lowercased() } else { words.append(character) }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A text field that commits on Return or when it loses focus, so typing is one undo step.
struct CommitTextField: View {
    let label: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
                .accessibilityLabel(label)
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in if !focused { text = new } }
    }

    private func commit() { if text != value { onCommit(text) } }
}

struct CommitNumberField: View {
    let label: String
    let value: Double
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            TextField(label, text: $text)
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
                .accessibilityLabel(label)
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, new in if !focused { text = Self.format(new) } }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func commit() {
        guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite else {
            text = Self.format(value); return
        }
        if number != value { onCommit(number) }
    }
}

private struct ImageField: View {
    let label: String
    let path: String
    let onChoose: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(FileManager.default.fileExists(atPath: path) ? Color.primary : Color.red)
            Spacer(minLength: 4)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .svg]
                panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
                if panel.runModal() == .OK, let url = panel.url { onChoose(url.path) }
            }
            .controlSize(.small)
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let r = Int((color.redComponent * 255).rounded()), g = Int((color.greenComponent * 255).rounded()),
            b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
