// End-to-end checks for the pieces the app relies on. Run with ./test.sh, or
// ./test.sh FEATURE ... to run only those features (./test.sh --list names them).
// Keep each feature's checks in its own function (Tests/Checks<Feature>.swift): as one
// long block of top-level code, the checks took 11 minutes to compile instead of one.
import AppKit
import AVFoundation
import Foundation

setbuf(stdout, nil)

/// Every feature's checks, in the order a full run takes them.
let features: [(name: String, run: @MainActor () async throws -> Void)] = [
    ("core", coreTests), ("editing", editingTests), ("tracks", tracksTests), ("player", playerTests), ("changes", changesTests), ("media", mediaTests), ("agents", agentsTests), ("playback", playbackTests),
    ("colour", colourTests), ("effects", effectsTests), ("graphics", graphicsTests), ("publish", publishTests),
    ("thumbnail", thumbnailTests), ("endscreen", endscreenTests), ("autoedit", autoeditTests), ("shorts", shortsTests),
    ("screen", screenTests), ("logos", logosTests), ("covers", coversTests), ("callouts", calloutsTests), ("music", musicTests), ("library", libraryTests), ("calendar", calendarTests), ("pastvideos", pastVideosTests), ("style", styleTests), ("macs", macsTests), ("blur", blurTests), ("gaps", gapsTests),
]
/// Features that start from what another feature makes: its checks run first.
let prerequisites: [String: [String]] = ["blur": ["editing"], "agents": ["editing"], "tracks": ["editing"], "player": ["editing"], "changes": ["editing"], "playback": ["editing"], "style": ["editing"]]
let asked = Array(CommandLine.arguments.dropFirst())
if asked.contains("--list") { print(features.map(\.name).joined(separator: "\n")); exit(0) }
if let unknown = asked.first(where: { name in !features.contains { $0.name == name } }) {
    print("No feature \"\(unknown)\". Features: \(features.map(\.name).joined(separator: ", "))")
    exit(2)
}
guard FFmpeg.ffmpegPath != nil, FFmpeg.ffprobePath != nil else {
    print("ffmpeg/ffprobe not found — cannot run tests")
    exit(2)
}
print("using \(ffmpeg)\n")
try? FileManager.default.removeItem(at: scratch)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
try await makeFixtures()
let chosen = Set(asked + asked.flatMap { prerequisites[$0] ?? [] })
for feature in features where asked.isEmpty || chosen.contains(feature.name) {
    print("\n=== \(feature.name)")
    try await feature.run()
}
print("\n\(checks - failures)/\(checks) checks passed")
try? FileManager.default.removeItem(at: scratch)
exit(failures == 0 ? 0 : 1)
