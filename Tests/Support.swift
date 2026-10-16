// Shared helpers for the checks.
import AppKit
import AVFoundation
import Foundation

func pixel(_ url: URL, x: Int, y: Int, at time: Double = 1.0) async throws -> (Int, Int, Int) {
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error",
        "-ss", String(format: "%.3f", time), "-i", url.path,
        "-frames:v", "1", "-vf", "crop=2:2:\(x):\(y)",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ])
    let bytes = [UInt8](result.stdout)
    guard bytes.count >= 3 else { throw FFmpegError(message: "no pixel data at \(x),\(y)") }
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
}

func regionDetail(_ url: URL, _ rect: CGRect, at time: Double = 1.0) async throws -> Double {
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error",
        "-ss", String(format: "%.3f", time), "-i", url.path, "-frames:v", "1",
        "-vf", "crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))",
        "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ])
    let bytes = [UInt8](result.stdout)
    let w = Int(rect.width), h = Int(rect.height)
    guard bytes.count >= w * h, w > 1 else {
        throw FFmpegError(message: "short frame data for \(rect)")
    }
    var total = 0.0
    var count = 0
    for row in 0..<h {
        let base = row * w
        for i in 1..<w {
            total += abs(Double(bytes[base + i]) - Double(bytes[base + i - 1]))
            count += 1
        }
    }
    return total / Double(max(count, 1))
}

func markerBox(_ url: URL, at time: Double, size: CGSize) async throws -> CGRect? {
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error",
        "-ss", String(format: "%.3f", time), "-i", url.path, "-frames:v", "1",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ])
    let bytes = [UInt8](result.stdout)
    let w = Int(size.width), h = Int(size.height)
    guard bytes.count >= w * h * 3 else { return nil }
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in stride(from: 0, to: h, by: 2) {
        for x in stride(from: 0, to: w, by: 2) {
            let i = (y * w + x) * 3
            if bytes[i] > 150, bytes[i + 1] < 90, bytes[i + 2] < 90 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

func frameCount(_ url: URL) async throws -> Int {
    guard let ffprobe = FFmpeg.ffprobePath else { return 0 }
    let result = try await Shell.run(ffprobe, [
        "-v", "error", "-select_streams", "v:0", "-count_packets",
        "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", url.path,
    ])
    return Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

func fileSize(_ url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
}

func integratedLoudness(_ url: URL) async throws -> Double? {
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-nostdin", "-i", url.path,
        "-af", "loudnorm=\(Loudness.filterTargets):print_format=json",
        "-vn", "-f", "null", "-",
    ])
    guard let measured = FFmpeg.parseLoudness(result.stderrText) else { return nil }
    return Double(measured.inputI)
}

func refusal(_ result: Result<EditReceipt, EditError>) -> EditError.Code? {
    if case .failure(let error) = result { return error.code }
    return nil
}

func receipt(_ result: Result<EditReceipt, EditError>) -> EditReceipt? {
    if case .success(let value) = result { return value }
    return nil
}

func reducerRefusal(_ commands: [EditCommand], _ project: VideoProject = roundTripProject) -> EditError.Code? {
    do { _ = try ProjectReducer.apply(commands, to: project); return nil }
    catch let error as EditError { return error.code }
    catch { return .invalidCommand }
}

@MainActor func freshEditor() -> AppModel {
    let model = AppModel(recoveryURL: nil)
    model.restore(roundTripProject)
    return model
}

@MainActor func agentCall(_ model: AppModel, _ request: [String: Any]) async -> [String: Any] {
    var body = request
    body["protocolVersion"] = AgentProtocol.version
    let data = try! JSONSerialization.data(withJSONObject: body)
    let reply = await model.handleAgentRequest(data, instanceID: bridgeInstance)
    return (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
}

func agentError(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }

func agentResult(_ response: [String: Any]) -> [String: Any] { response["result"] as? [String: Any] ?? [:] }

@MainActor func address(_ model: AppModel) -> [String: Any] {
    ["sessionID": model.editSession.sessionID.uuidString, "projectID": model.projectID.uuidString,
     "expectedRevision": model.revision]
}

@MainActor func waitForJob(_ model: AppModel, _ id: String) async throws -> [String: Any] {
    for _ in 0..<600 {
        let job = agentResult(await agentCall(model, ["method": "job", "job": id]))
        if job["status"] as? String != "running" { return job }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return [:]
}

func ctlJSON(_ result: ShellResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]) ?? [:]
}

func toneFrequency(_ url: URL, at time: Double) async throws -> Double {
    let data = try await Shell.run(ffmpeg, ["-v", "error", "-ss", String(time), "-i", url.path,
        "-t", "0.3", "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"])
    let bytes = [UInt8](data.stdout)
    let samples = stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
    return Double(crossings) * 8000 / Double(max(1, samples.count))
}

func nativePixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
    return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
}

func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 0.000001) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.z - b.z) <= tolerance
}

func cubeRefusal(_ text: String) -> String? {
    do { _ = try ColorCube.parse(Data(text.utf8)); return nil } catch { return error.localizedDescription }
}

extension Result { var isFailure: Bool { if case .failure = self { return true } else { return false } } }

extension Result { var isSuccess: Bool { !isFailure } }

func gfx(_ kind: GraphicKind, _ start: Double, _ end: Double, _ props: [String: JSONValue] = [:], look: GraphicsLook? = nil) -> Graphic {
    Graphic(kind: kind, start: start, end: end, props: props, look: look)
}

func unitKeys(_ track: GraphicsTrack, width: Double = 1920) -> [String: String] {
    Dictionary(uniqueKeysWithValues: GraphicsRender.jobs(for: track, fps: "30", outputWidth: width).map { ($0.unit.id, $0.key) })
}

struct Picture { let width: Int, height: Int; let values: [Double]
    func at(_ x: Int, _ y: Int, _ channel: Int) -> Double { values[(y * width + x) * 3 + channel] }
}

func nativePicture(_ item: VideoItem, frame: Int, short: Short? = nil) async throws -> Picture {
    let player = try await PlaybackController.makeItem(item, settings: ExportSettings(), short: short)
    let generator = AVAssetImageGenerator(asset: player.asset)
    generator.videoComposition = player.videoComposition
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let image = try await generator.image(at: CMTime(value: CMTimeValue(frame), timescale: 30)).image
    var words = [UInt16](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &words, width: image.width, height: image.height, bitsPerComponent: 16,
                            bytesPerRow: image.width * 8, space: ColorPipeline.videoSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var values: [Double] = []; values.reserveCapacity(image.width * image.height * 3)
    for pixel in stride(from: 0, to: words.count, by: 4) {
        values += [Double(words[pixel]), Double(words[pixel + 1]), Double(words[pixel + 2])].map { $0 / 257 }
    }
    return Picture(width: image.width, height: image.height, values: values)
}

func ffmpegPicture(_ input: URL, graph: String?, frame: Int, width: Int, height: Int) async throws -> Picture {
    let read = "select='eq(n,\(frame))',scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb48le"
    var args = ["-hide_banner", "-loglevel", "error", "-i", input.path]
    if let graph { args += ["-filter_complex", graph + ";[mvout]" + read + "[read]", "-map", "[read]"] } else { args += ["-vf", read] }
    let result = try await Shell.run(ffmpeg, args + ["-frames:v", "1", "-f", "rawvideo", "-"])
    let words = result.stdout.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    guard words.count == width * height * 3 else { throw FFmpegError(message: "no frame \(frame): \(result.stderrText)") }
    return Picture(width: width, height: height, values: words.map { Double(UInt16(littleEndian: $0)) / 257 })
}

func alignment(_ a: Picture, _ b: Picture, xs: Range<Int>) -> (offset: Int, mean: Double) {
    var best = (offset: 0, mean: Double.infinity)
    for offset in -4...4 {
        var total = 0.0, count = 0
        for y in stride(from: 20, to: a.height - 20, by: 4) { for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 2) {
            for channel in 0..<3 { total += abs(a.at(x, y, channel) - b.at(x + offset, y, channel)) }
            count += 3
        } }
        if total / Double(count) < best.mean { best = (offset, total / Double(count)) }
    }
    return best
}

func meanDifference(_ a: Picture, _ b: Picture, xs: Range<Int>) -> Double {
    var total = 0.0, count = 0
    for y in stride(from: 10, to: a.height - 10, by: 3) { for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 2) {
        for channel in 0..<3 { total += abs(a.at(x, y, channel) - b.at(x, y, channel)) }
        count += 3
    } }
    return total / Double(max(1, count))
}

final class DrawCount: @unchecked Sendable { private let lock = NSLock(); private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value } }

func isMagenta(_ p: (Int, Int, Int)) -> Bool { p.0 > 200 && p.1 < 60 && p.2 > 200 }

func unchanged(_ a: URL, _ b: URL, x: Int, y: Int, at time: Double) async throws -> Bool {
    let p = try await pixel(a, x: x, y: y, at: time), q = try await pixel(b, x: x, y: y, at: time)
    return abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2) < 24
}

func colourShift(_ a: Picture, _ b: Picture) -> Double {
    var totals = [0.0, 0.0, 0.0], count = 0.0
    for y in stride(from: 10, to: a.height - 10, by: 3) { for x in stride(from: 0, to: a.width, by: 2) {
        for channel in 0..<3 { totals[channel] += a.at(x, y, channel) - b.at(x, y, channel) }; count += 1
    } }
    return totals.map { abs($0 / count) }.max() ?? 0
}

extension CGImage {
    static func blank(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

func brightShare(_ image: CGImage, xs: Range<Int>) -> Double {
    var bright = 0, total = 0
    for y in stride(from: 60, to: 660, by: 12) { for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 12) {
        let p = rgb(image, x, y); total += 1
        if p.0 > 225 && p.1 > 225 && p.2 > 225 { bright += 1 }
    } }
    return Double(bright) / Double(max(1, total))
}

func redShare(_ image: CGImage, xs: Range<Int>) -> Double {
    var red = 0, total = 0
    for y in stride(from: 40, to: 700, by: 10) { for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 10) {
        let p = rgb(image, x, y); total += 1
        if p.0 > 180 && p.1 < 110 && p.2 < 110 { red += 1 }
    } }
    return Double(red) / Double(max(1, total))
}

func rowOverlaps(_ image: CGImage) -> (rows: Int, red: Int, text: Int) {
    var overlaps = 0, red = 0, text = 0
    for y in stride(from: 20, to: 710, by: 6) {
        var textRight = -1, redLeft = Int.max
        for x in stride(from: 0, to: 1280, by: 4) {
            let p = rgb(image, x, y)
            if (p.0 > 225 && p.1 > 225 && p.2 > 225) || (p.0 > 220 && p.1 > 170 && p.1 < 215 && p.2 < 90) { textRight = max(textRight, x) }
            if p.0 > 180 && p.1 < 110 && p.2 < 110 { redLeft = min(redLeft, x) }
        }
        if textRight >= 0 { text += 1 }
        if redLeft < Int.max { red += 1 }
        if textRight >= 0 && redLeft < Int.max && redLeft <= textRight + 20 { overlaps += 1 }
    }
    return (overlaps, red, text)
}

func whiteNear(_ image: CGImage) -> Int {
    var count = 0
    for y in stride(from: 20, to: 710, by: 3) { for x in stride(from: 100, to: 700, by: 3) {
        let p = rgb(image, x, y); if p.0 > 235 && p.1 > 235 && p.2 > 235 { count += 1 }
    } }
    return count
}

func titleColours(_ image: CGImage) -> (dark: Int, accent: Int) {
    var dark = 0, accent = 0
    for y in stride(from: 60, to: 660, by: 6) { for x in stride(from: 40, to: 640, by: 4) {
        let p = rgb(image, x, y)
        if p.0 < 60 && p.1 < 60 && p.2 < 60 { dark += 1 }
        if p.0 > 220 && p.1 > 170 && p.1 < 215 && p.2 < 90 { accent += 1 }
    } }
    return (dark, accent)
}

func face(_ lips: [CGPoint], eyeHeight: Double = 0.05, nose: Double = 0.45) -> FaceLook? {
    func eye(_ x: Double) -> [CGPoint] { [CGPoint(x: x - 0.075, y: 0.62), CGPoint(x: x, y: 0.62 + eyeHeight / 2), CGPoint(x: x + 0.075, y: 0.62), CGPoint(x: x, y: 0.62 - eyeHeight / 2)] }
    return FaceLook.measure(lips: lips, leftEye: eye(0.25), rightEye: eye(0.65), nose: [CGPoint(x: nose, y: 0.45), CGPoint(x: nose, y: 0.40)],
                            quality: 0.6, face: CGRect(x: 0, y: 0, width: 100, height: 100))
}

func spokenWords(_ list: [(String, Double)], end: Double) -> [TranscriptWord] {
    list.enumerated().map { index, word in TranscriptWord(text: word.0, start: word.1, end: index + 1 < list.count ? list[index + 1].1 : end) }
}

func syntheticLevels(_ loud: [(Double, Double)], until: Double) -> AudioOverview {
    var levels: [AudioLevel] = []
    var tick = 0
    while Double(tick) * AudioOverview.interval < until - 0.0001 {
        let time = Double(tick) * AudioOverview.interval
        levels.append(AudioLevel(time: time, decibels: loud.contains { time >= $0.0 - 0.0001 && time < $0.1 - 0.0001 } ? -12 : -70))
        tick += 1
    }
    return AudioOverview(levels: levels)
}

func spans(_ cuts: [SilenceCut]) -> [[Double]] { cuts.map { [($0.start * 1000).rounded() / 1000, ($0.end * 1000).rounded() / 1000] } }
