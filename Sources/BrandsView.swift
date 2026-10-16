import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Find Brands, in the Graphics section: the brand and company names said in the
/// recording, the owner's logo for each (or a button to choose one), and the logo badges
/// they make, added as one undo step.
struct BrandFinderView: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    @State private var shown = false
    /// Changes when a logo is chosen, so the library is read again.
    @State private var library = LogoLibrary.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(shown ? "Hide Brands" : "Find Brands") {
                    library = LogoLibrary.load()
                    shown.toggle()
                }
                .disabled(item.transcript == nil)
                .help(item.transcript == nil
                      ? "Transcribe the recording first: the app finds brands in what is said."
                      : "Find the brand and company names said in the recording, and show their logos next to you")
                Spacer()
            }
            if shown, let found = item.brandPlan(library: library) {
                list(found.mentions, plan: found.plan)
            }
        }
        .controlSize(.small)
    }

    private struct Row: Identifiable {
        var name: String
        var source: BrandMention.Source
        var logo: String?
        var times: [Double]
        var id: String { name }
    }

    private func rows(_ mentions: [BrandMention]) -> [Row] {
        var rows: [Row] = []
        for mention in mentions {
            guard let time = mention.time else { continue }
            if let index = rows.firstIndex(where: { $0.name == mention.name }) { rows[index].times.append(time) }
            else { rows.append(Row(name: mention.name, source: mention.source, logo: mention.logo, times: [time])) }
        }
        return rows
    }

    @ViewBuilder
    private func list(_ mentions: [BrandMention], plan: BrandFinder.Plan) -> some View {
        let rows = rows(mentions)
        if rows.isEmpty {
            Text("No brand or company names found in what is said.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        logoPicture(row.logo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.source == .guess ? "\(row.name)?" : row.name).font(.caption.weight(.semibold))
                            Text(row.times.prefix(4).map(timelineTime).joined(separator: " · ") + (row.times.count > 4 ? " …" : ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button(row.logo == nil ? "Choose Logo…" : "Change…") { chooseLogo(for: row.name) }
                            .help(row.source == .guess ? "This word looks like a name. Choose a logo only if it is a brand." : "Choose the logo for \(row.name): a transparent PNG or an SVG")
                    }
                }
            }
            Text(plan.badges.isEmpty
                 ? "No badges to add. Choose logos for the names you want, or remove the badges there are to place them again."
                 : "\(plan.badges.count) logo badge\(plan.badges.count == 1 ? "" : "s"): each shows next to you for about 2 s from the name. A name said again within a minute gets no new badge.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add \(plan.badges.count) Logo Badge\(plan.badges.count == 1 ? "" : "s")") {
                model.perform(plan.badges.map { .addGraphic(clip: item.id, graphic: $0) }, label: "Logo Badges")
            }
            .disabled(plan.badges.isEmpty)
        }
    }

    @ViewBuilder
    private func logoPicture(_ path: String?) -> some View {
        if let path, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
        } else {
            Image(systemName: "questionmark.square.dashed").frame(width: 22, height: 22).foregroundStyle(.secondary)
        }
    }

    /// Keeps a copy of the chosen file in the logo library, for this and later projects.
    private func chooseLogo(for name: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .svg, .jpeg, .webP, .heic]
        panel.message = "Choose the logo for \(name). A transparent PNG or an SVG looks best."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let old = library.first { $0.name.lowercased() == name.lowercased() }
            try LogoLibrary.set(name: name, image: url, words: old?.words)
            library = LogoLibrary.load()
            model.statusMessage = "Kept the \(name) logo for this and later projects."
        } catch {
            model.statusMessage = (error as? EditError)?.message ?? error.localizedDescription
        }
    }
}
