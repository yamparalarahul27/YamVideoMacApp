import Foundation

/// The footage list of each Mac (MacInventory.swift, docs/footage-layout.md).
@MainActor func macsTests() async throws {
    print("\nMac lists")
    let manager = FileManager.default
    let root = scratch.appendingPathComponent("macs", isDirectory: true)
    let footage = root.appendingPathComponent("Yamparala Media", isDirectory: true)
    let lists = root.appendingPathComponent("lists", isDirectory: true)
    let part1 = footage.appendingPathComponent("2026-10-17 AgentUX Part 1", isDirectory: true)
    for path in ["Recorded/Joined", "Edited/Shorts"] {
        try manager.createDirectory(at: part1.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    for path in ["2026-10-18 Sahi/Recorded", "Inbox", "Shared Assets/logos", "Other"] {
        try manager.createDirectory(at: footage.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try Data(count: 1000).write(to: part1.appendingPathComponent("Recorded/take.mp4"))
    try Data(count: 500).write(to: part1.appendingPathComponent("Recorded/Joined/joined.mov"))
    try Data(count: 200).write(to: part1.appendingPathComponent("Edited/Long.mp4"))
    try Data(count: 50).write(to: part1.appendingPathComponent("Edited/Long.en.srt"))
    try Data(count: 100).write(to: part1.appendingPathComponent("Edited/Shorts/One.mp4"))
    let projectID = UUID()
    let project = VideoProject(projectID: projectID, clips: [], settings: ExportSettings(), selection: nil,
                               movieSettings: nil, autoEdit: nil)
    try JSONEncoder().encode(project).write(to: part1.appendingPathComponent("AgentUX.yamvideo"))
    try Data(count: 10).write(to: footage.appendingPathComponent("2026-10-18 Sahi/Recorded/phone.MP4"))
    try Data().write(to: footage.appendingPathComponent("Inbox/new.mov"))

    let here = MacInventory.scan(footage, mac: "Equicom")
    equal(here.videos.map(\.folder), ["2026-10-17 AgentUX Part 1", "2026-10-18 Sahi"],
          "lists the video folders, not Inbox, Shared Assets or Other")
    let first = here.videos.first
    equal(first?.projects ?? [], [projectID], "reads the id of the project in a video folder")
    equal(first?.recordings ?? [], ["Joined/joined.mov", "take.mp4"], "lists the recordings, also in Recorded/Joined")
    equal(first?.exports ?? 0, 2, "counts the video files in Edited and Edited/Shorts, not the captions")
    check((first?.bytes ?? 0) >= 1850, "adds up the sizes", "\(first?.bytes ?? 0)")
    equal(first?.title ?? "", "AgentUX Part 1", "a video's title leaves out the date")

    let wrote = try MacInventory.write(here, to: lists)
    check(wrote && manager.fileExists(atPath: lists.appendingPathComponent("Equicom.json").path),
          "writes the list as <Mac>.json")
    var later = here
    later.updated = here.updated.addingTimeInterval(3600)
    let wroteAgain = try MacInventory.write(later, to: lists)
    check(!wroteAgain, "a list that only has a new date writes nothing, so Git has nothing to commit")

    let sketch = MacInventory.Video(folder: "2026-08-11 iPad Sketch", projects: [], recordings: ["sketch.mp4"], exports: 0, bytes: 1)
    let other = MacInventory(mac: "Yamparala", footage: "~/Desktop/Yamparala Media", updated: Date(), videos: [
        .init(folder: "2026-10-17 Renamed on that Mac", projects: [projectID], recordings: ["take.mp4"], exports: 2, bytes: 1),
        sketch,
    ])
    try MacInventory.write(other, to: lists)
    let others = MacInventory.others(in: lists, except: "Equicom")
    equal(others.map(\.mac), ["Yamparala"], "reads the other Macs' lists, not its own")
    equal(MacInventory.macs(holding: projectID, in: others), ["Yamparala"], "finds the other Macs that hold a project")
    let away = MacInventory.elsewhere(others, here: here)
    equal(away.map(\.video.folder), ["2026-08-11 iPad Sketch"],
          "a video only on the other Mac is listed; one with the same project here is not")
    let studio = MacInventory(mac: "Studio", footage: "~/Desktop/Yamparala Media", updated: Date(), videos: [sketch])
    equal(MacInventory.elsewhere(others + [studio], here: here).first?.macs ?? [], ["Yamparala", "Studio"],
          "a video on two other Macs shows once, with both Macs")
    equal(MacInventory.fileName(for: "Studio/Desk"), "Studio-Desk.json", "a Mac name with a slash gives a safe file name")
    try? manager.removeItem(at: root)
}
