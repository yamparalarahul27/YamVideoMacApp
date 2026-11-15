import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}
@MainActor func waitFor(_ message: String, until condition: () -> Bool) async {
    for _ in 0..<900 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    print("FAIL: timed out: \(message)"); exit(1)
}

let odd = "https://example.com/watch?v=a&name=$(touch%20bad);x"
require((try? DownloadEngine.validatedURL(odd)) != nil, "URL is data, not shell syntax")
for input in ["", "file:///etc/passwd", "javascript:alert(1)", "https://user:password@example.com/x", "https://"] {
    require((try? DownloadEngine.validatedURL(input)) == nil, "Reject non-web or credential URL: \(input)")
}
let url = try DownloadEngine.validatedURL(" https://example.com/video?x=1&y=2 ")
let args = DownloadEngine.arguments(url: url, folder: URL(fileURLWithPath: "/tmp/a folder"), kind: .video, quality: .fullHD, browser: .none, inspect: false)
require(Array(args.suffix(2)) == ["--", url.absoluteString], "URL kept as a single final argument")
require(args.contains("bv*[height<=?1080]+ba/b[height<=?1080]"), "Quality caps both adaptive and combined formats")
require(!args.contains("--cookies-from-browser"), "No browser session read by default")
let audio = DownloadEngine.arguments(url: url, folder: nil, kind: .audio, quality: .best, browser: .firefox, inspect: false)
require(audio.contains("-x") && audio.contains("m4a") && audio.contains("firefox"), "Explicit audio/login settings")
let p = DownloadEngine.progress("yv-progress:{\"downloaded_bytes\":500,\"total_bytes\":1000,\"speed\":2000}")
require(p?.0 == 0.5, "Structured progress uses bytes")
require(DownloadEngine.progress("WARNING: changed console output") == nil, "Ignore ordinary logs")
let metadata = try DownloadInspection.parse(Data(#"{"title":"A post","entries":[{"title":"Clip","duration":12.5,"uploader":"Creator"}]}"#.utf8))
require(metadata.title == "A post" && metadata.duration == 12.5, "Multi-video metadata inspected")

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("yamvideo-download-smoke-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
try Data([1]).write(to: temp.appendingPathComponent("clip.mp4"))
require(DownloadStore.availableDestination(for: "clip.mp4", in: temp).lastPathComponent == "clip (2).mp4", "Never overwrite existing files")
if let endpoint = ProcessInfo.processInfo.environment["YAMVIDEO_TEST_DOWNLOAD_URL"] {
    let store = DownloadStore(dataDirectory: temp.appendingPathComponent("history"), outputDirectory: temp.appendingPathComponent("out"))
    store.inspect(endpoint, browser: .none)
    await waitFor("inspection") { !store.isInspecting }
    require(store.inspection != nil, "Real yt-dlp inspection: \(store.message ?? "")")
    store.enqueue(endpoint, kind: .video, quality: .fullHD, browser: .none)
    let first = store.entries[0].id
    store.enqueue(endpoint, kind: .video, quality: .best, browser: .none)
    let second = store.entries[0].id
    store.cancel(second)
    require(store.entries.first { $0.id == second }?.phase == .cancelled, "Cancel a queued item")
    await waitFor("first download") { store.entries.first { $0.id == first }?.phase == .completed || store.entries.first { $0.id == first }?.phase == .failed }
    let finished = store.entries.first { $0.id == first }!
    require(finished.phase == .completed && !finished.files.isEmpty, "Real download: \(finished.error ?? "")")
    require(finished.files.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "Completed files exist")
    store.retry(second)
    await waitFor("active download") { store.entries.first { $0.id == second }?.phase.isActive == true }
    store.cancel(second)
    await waitFor("cancel reaches worker") { !FileManager.default.fileExists(atPath: store.destination.appendingPathComponent(".partial-\(second.uuidString)").path) }
    require(store.entries.first { $0.id == second }?.phase == .cancelled, "Active cancellation retained")
    store.retry(second)
    await waitFor("retry") { store.entries.first { $0.id == second }?.phase == .completed || store.entries.first { $0.id == second }?.phase == .failed }
    let retried = store.entries.first { $0.id == second }!
    require(retried.phase == .completed, "Retry completes: \(retried.error ?? "")")
    require(retried.files != finished.files, "Duplicate title gets a new filename")
    store.enqueue(endpoint, kind: .audio, quality: .best, browser: .none)
    let audioID = store.entries[0].id
    await waitFor("audio extraction") { store.entries.first { $0.id == audioID }?.phase == .completed || store.entries.first { $0.id == audioID }?.phase == .failed }
    let extracted = store.entries.first { $0.id == audioID }!
    require(extracted.phase == .completed && extracted.files.first?.hasSuffix(".m4a") == true, "Audio output is M4A: \(extracted.error ?? "")")
    let reopened = DownloadStore(dataDirectory: temp.appendingPathComponent("history"), outputDirectory: temp.appendingPathComponent("out"))
    require(reopened.entries.filter { $0.phase == .completed }.count == 3, "History survives reopening")
    print("Real local HTTP media: inspection, queue, cancellation, retry, filename isolation, audio extraction and history passed.")
}
print("Download engine checks passed.")
