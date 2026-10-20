import Foundation

/// The list of the video folders on one of the owner's Macs (docs/footage-layout.md, "More
/// than one Mac"). Each Mac writes its own list into the YamVideo repo as
/// `docs/channel/macs/<Mac>.json`; Git takes it to the other Macs, and the Library says
/// where each video is. The list names files and sizes only, never the footage.
struct MacInventory: Codable, Equatable {
    struct Video: Codable, Equatable {
        /// The video folder's name, like "2026-10-17 AgentUX System Design Part 1".
        var folder: String
        /// The projectID of each project at the top of the folder.
        var projects: [UUID]
        /// The file names in Recorded/ and the folders inside it.
        var recordings: [String]
        /// The video files in Edited/ and Edited/Shorts/.
        var exports: Int
        var bytes: Int64

        /// The folder's name without its "YYYY-MM-DD " date.
        var title: String {
            let parts = folder.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isNumber || $0 == "-" }) else { return folder }
            return String(parts[1])
        }
    }

    var mac: String
    /// The footage folder on that Mac, with ~ for the home folder.
    var footage: String
    var updated: Date
    var videos: [Video]

    /// Top-level folders of the footage folder that are not videos.
    static let notVideos: Set<String> = ["Inbox", "Shared Assets", "Other"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "gif"]

    // MARK: Where things are

    /// This Mac's short name in the lists, like "Equicom". Set it in the Library's Macs menu.
    static var thisMac: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "macName")?.trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? (Host.current().localizedName ?? "This Mac") : stored
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "macName") }
    }

    /// The footage folder: ~/Desktop/Yamparala Media unless `footageFolder` is set.
    static var footageFolder: URL {
        if let path = UserDefaults.standard.string(forKey: "footageFolder"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Yamparala Media", isDirectory: true)
    }

    /// docs/channel/macs in the YamVideo source folder this app was built in
    /// (build/YamVideo.app), or YAMVIDEO_MACS_PATH. Nil for the checks and the tools, so
    /// they never write a list, and for an app that is not in a source folder.
    static var listsFolder: URL? {
        if let path = ProcessInfo.processInfo.environment["YAMVIDEO_MACS_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return nil }
        let channel = app.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/channel", isDirectory: true)
        return FileManager.default.fileExists(atPath: channel.path) ? channel.appendingPathComponent("macs", isDirectory: true) : nil
    }

    /// The list's file name for `mac`: its name with no path characters.
    static func fileName(for mac: String) -> String {
        let safe = mac.map { "/:\\".contains($0) ? "-" : $0 }
        return String(safe).trimmingCharacters(in: .whitespaces) + ".json"
    }

    // MARK: Making and reading lists

    /// The video folders in `footage` now.
    static func scan(_ footage: URL, mac: String, now: Date = Date()) -> MacInventory {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: footage, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
        var videos: [Video] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !notVideos.contains(folder.lastPathComponent) else { continue }
            let top = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let projects = top.filter { $0.pathExtension.lowercased() == "yamvideo" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { ProjectSummary.read($0)?.projectID }
            var recordings: [String] = [], exports = 0, bytes: Int64 = 0
            let recorded = folder.appendingPathComponent(FootageLayout.recorded).standardizedFileURL.path
            let edited = folder.appendingPathComponent(FootageLayout.edited).standardizedFileURL.path
            let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = walker?.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
                bytes += Int64(values.fileSize ?? 0)
                let path = file.standardizedFileURL.path
                if path.hasPrefix(recorded + "/") { recordings.append(String(path.dropFirst(recorded.count + 1))) }
                if path.hasPrefix(edited + "/"), videoExtensions.contains(file.pathExtension.lowercased()) { exports += 1 }
            }
            videos.append(Video(folder: folder.lastPathComponent, projects: projects, recordings: recordings.sorted(),
                                exports: exports, bytes: bytes))
        }
        let home = manager.homeDirectoryForCurrentUser.path
        let shown = footage.path.hasPrefix(home + "/") ? "~" + footage.path.dropFirst(home.count) : footage.path
        return MacInventory(mac: mac, footage: shown, updated: now, videos: videos)
    }

    /// Writes `list` into `folder` when it differs from the file there, apart from the
    /// date; an unchanged Mac leaves Git with nothing to commit. True when it wrote.
    @discardableResult
    static func write(_ list: MacInventory, to folder: URL) throws -> Bool {
        let file = folder.appendingPathComponent(fileName(for: list.mac))
        if let data = try? Data(contentsOf: file), var stored = try? decoder.decode(MacInventory.self, from: data) {
            stored.updated = list.updated
            if stored == list { return false }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(list).write(to: file, options: .atomic)
        return true
    }

    /// Every list in `folder` but the one for `mac`.
    static func others(in folder: URL, except mac: String) -> [MacInventory] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != fileName(for: mac) }
            .compactMap { try? decoder.decode(MacInventory.self, from: Data(contentsOf: $0)) }
            .filter { $0.mac != mac }
            .sorted { $0.mac < $1.mac }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Comparing Macs

    /// Whether `video` is in this list: the same folder name, or a project with the same id.
    func holds(_ video: Video) -> Bool {
        videos.contains { $0.folder == video.folder || !Set($0.projects).isDisjoint(with: video.projects) }
    }

    /// The other Macs that hold a project with `projectID`.
    static func macs(holding projectID: UUID, in others: [MacInventory]) -> [String] {
        others.filter { $0.videos.contains { $0.projects.contains(projectID) } }.map(\.mac)
    }

    /// The videos that other Macs hold and `here` does not, each once, with every Mac that
    /// holds it.
    static func elsewhere(_ others: [MacInventory], here: MacInventory) -> [(video: Video, macs: [String])] {
        var result: [(video: Video, macs: [String])] = []
        for list in others {
            for video in list.videos where !here.holds(video) {
                if let index = result.firstIndex(where: { MacInventory(mac: "", footage: "", updated: .distantPast, videos: [$0.video]).holds(video) }) {
                    result[index].macs.append(list.mac)
                } else {
                    result.append((video, [list.mac]))
                }
            }
        }
        return result.sorted { $0.video.folder > $1.video.folder }
    }
}

extension AppModel {
    /// Writes this Mac's list into the repo when it changed, and reads the other Macs'
    /// lists. A Mac without the footage folder writes nothing: an empty list would say its
    /// videos are gone.
    func refreshMacs() {
        guard let folder = MacInventory.listsFolder else { return }
        let footage = MacInventory.footageFolder, mac = MacInventory.thisMac
        Task { [weak self] in
            let (list, others) = await Task.detached(priority: .utility) { () -> (MacInventory?, [MacInventory]) in
                let present = FileManager.default.fileExists(atPath: footage.path)
                let list = present ? MacInventory.scan(footage, mac: mac) : nil
                if let list { try? MacInventory.write(list, to: folder) }
                return (list, MacInventory.others(in: folder, except: mac))
            }.value
            self?.thisMacList = list
            self?.otherMacs = others
        }
    }

    /// Gives this Mac a new name in the lists, and renames its list file to match.
    func renameThisMac(to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        let old = MacInventory.thisMac
        guard !name.isEmpty, name != old else { return }
        if let folder = MacInventory.listsFolder {
            let from = folder.appendingPathComponent(MacInventory.fileName(for: old))
            let to = folder.appendingPathComponent(MacInventory.fileName(for: name))
            if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
                try? FileManager.default.moveItem(at: from, to: to)
            }
        }
        MacInventory.thisMac = name
        refreshMacs()
    }

    /// The other Macs that hold the project with `projectID`.
    func macsHolding(_ projectID: UUID) -> [String] { MacInventory.macs(holding: projectID, in: otherMacs) }

    /// Videos that only other Macs hold and that no Library item links.
    var videosElsewhere: [(video: MacInventory.Video, macs: [String])] {
        let here = thisMacList ?? MacInventory(mac: "", footage: "", updated: .distantPast, videos: [])
        let linked = Set(library.items.compactMap { $0.project?.projectID })
        return MacInventory.elsewhere(otherMacs, here: here).filter { linked.isDisjoint(with: $0.video.projects) }
    }
}
