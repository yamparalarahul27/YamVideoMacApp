import AVFoundation
import XCTest
@testable import YVCore

final class ExporterTests: XCTestCase {

    var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yvcore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Fixture

    /// Writes a short H.264 .mov: a moving bar over a solid background, so the
    /// encode isn't degenerate.
    func makeTestMovie(seconds: Double = 2.0, fps: Int32 = 30,
                       width: Int = 640, height: Int = 360) async throws -> URL {
        let url = workDir.appendingPathComponent("fixture-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "startWriting failed: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(seconds * Double(fps))
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                XCTFail("no pixel buffer pool"); break
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { XCTFail("no pixel buffer"); break }

            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1))
            let x = CGFloat(i) / CGFloat(frameCount) * CGFloat(width - 40)
            ctx.fill(CGRect(x: x, y: 40, width: 40, height: CGFloat(height - 80)))
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let pts = CMTime(value: CMTimeValue(i), timescale: fps)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: pts))
        }

        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed,
                       "writer failed: \(String(describing: writer.error))")
        return url
    }

    // MARK: - Tests

    func testProbe() async throws {
        let movie = try await makeTestMovie()
        let info = try await MediaInfo.probe(movie)

        XCTAssertEqual(info.videoCodec, "H.264")
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertEqual(info.duration, 2.0, accuracy: 0.2)
        XCTAssertFalse(info.hasAudio)
        XCTAssertGreaterThan(info.fileSizeBytes, 0)
    }

    func testCanRemuxH264Mov() async throws {
        let movie = try await makeTestMovie()
        let canRemux = await Exporter.canRemuxToMP4(movie)
        XCTAssertTrue(canRemux, "H.264 in .mov should be MP4-remuxable")
    }

    func testRemuxToMP4() async throws {
        let movie = try await makeTestMovie()
        let out = workDir.appendingPathComponent("out.mp4")

        var lastProgress = 0.0
        let progressBox = ProgressBox()
        let result = try await Exporter.convertToMP4(
            movie, outputURL: out, preset: .webSafeH264,
            progress: { progressBox.set($0) })
        lastProgress = progressBox.get()

        XCTAssertTrue(result.wasRemux)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(lastProgress, 1.0)

        let info = try await MediaInfo.probe(out)
        XCTAssertEqual(info.videoCodec, "H.264")
        XCTAssertEqual(info.duration, 2.0, accuracy: 0.2)
    }

    func testForcedTranscode() async throws {
        let movie = try await makeTestMovie()
        let out = workDir.appendingPathComponent("transcoded.mp4")

        let result = try await Exporter.transcodeToMP4(
            movie, outputURL: out, preset: .webSafeH264)

        XCTAssertFalse(result.wasRemux)
        let info = try await MediaInfo.probe(out)
        XCTAssertEqual(info.videoCodec, "H.264")
        XCTAssertEqual(info.duration, 2.0, accuracy: 0.2)
    }

    func testDefaultOutputURLAvoidsCollision() throws {
        let input = workDir.appendingPathComponent("clip.mov")
        FileManager.default.createFile(atPath: input.path, contents: Data())

        let first = Exporter.defaultOutputURL(for: input)
        XCTAssertEqual(first.lastPathComponent, "clip.mp4")

        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = Exporter.defaultOutputURL(for: input)
        XCTAssertEqual(second.lastPathComponent, "clip 2.mp4")
    }

    func testGifArgs() {
        let args = FFmpeg.gifArgs(
            input: URL(fileURLWithPath: "/tmp/in.mp4"),
            output: URL(fileURLWithPath: "/tmp/out.gif"),
            startSeconds: 5, endSeconds: 15,
            settings: GifSettings())
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("-ss 5.000"))
        XCTAssertTrue(joined.contains("-to 15.000"))
        XCTAssertTrue(joined.contains("palettegen=stats_mode=diff"))
        XCTAssertTrue(joined.contains("paletteuse=dither=bayer"))
        XCTAssertTrue(joined.contains("fps=15,scale=800"))
        XCTAssertTrue(joined.contains("-loop 0"))
    }

    func testEditDocRoundTrip() throws {
        var doc = EditDoc()
        doc.timeline = [Segment(sourceId: "screen", inMs: 3500, outMs: 80000)]
        doc.sources = [Source(id: "screen", path: "/tmp/a.mov", role: .screen)]
        doc.blurs = [BlurRegion(sourceId: "screen",
                                rect: NormalizedRect(x: 0.6, y: 0.1, w: 0.3, h: 0.05))]

        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(EditDoc.self, from: data)
        XCTAssertEqual(decoded, doc)
    }
}

/// Progress lands from a @Sendable closure; a tiny lock keeps XCTest happy.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func set(_ v: Double) { lock.withLock { value = v } }
    func get() -> Double { lock.withLock { value } }
}
