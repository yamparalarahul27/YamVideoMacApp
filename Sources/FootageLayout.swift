import Foundation

/// The footage folder layout (docs/footage-layout.md): one folder for each video, with
/// the camera and screen recordings in Recorded/, the exports in Edited/ (Shorts in
/// Edited/Shorts/) and the made files, like thumbnails and graphics images, in Files/.
/// A recording outside this layout keeps the old default: its files go beside it.
enum FootageLayout {
    static let recorded = "Recorded"
    static let edited = "Edited"
    static let files = "Files"
    static let shorts = "Shorts"

    /// The video folder that holds `recording` in its Recorded/ folder, or one folder
    /// deeper (like Recorded/Joined/). Nil when the recording is not in the layout.
    static func videoFolder(of recording: URL) -> URL? {
        var folder = recording.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<2 {
            if folder.lastPathComponent.caseInsensitiveCompare(recorded) == .orderedSame {
                return folder.deletingLastPathComponent()
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// Where the exports of `recording` go when no output folder is set.
    static func editedFolder(for recording: URL) -> URL { folder([edited], for: recording) }

    /// Where the Shorts of `recording` go when no output folder is set.
    static func shortsFolder(for recording: URL) -> URL { folder([edited, shorts], for: recording) }

    /// Where the images made from `recording` (thumbnails, saved frames) go.
    static func filesFolder(for recording: URL) -> URL { folder([files], for: recording) }

    /// The named folder inside the video folder, made when it is not there yet; else the
    /// recording's own folder.
    private static func folder(_ names: [String], for recording: URL) -> URL {
        guard let video = videoFolder(of: recording) else { return recording.deletingLastPathComponent() }
        let target = names.reduce(video) { $0.appendingPathComponent($1, isDirectory: true) }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        } catch { return recording.deletingLastPathComponent() }
    }
}
