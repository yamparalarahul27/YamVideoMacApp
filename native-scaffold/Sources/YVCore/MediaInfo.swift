import AVFoundation

/// What we know about a media file after probing it. Everything the Export
/// tab shows and everything the pipeline branches on.
public struct MediaInfo: Sendable {
    public let url: URL
    public let fileSizeBytes: Int64
    public let duration: Double
    public let width: Int
    public let height: Int
    public let fps: Double
    /// Human-readable ("H.264", "HEVC", "ProRes 422"), nil when there is no video track.
    public let videoCodec: String?
    public let videoCodecFourCC: String?
    public let audioCodec: String?
    public let hasAudio: Bool

    public var sizeText: String {
        Self.formatBytes(fileSizeBytes)
    }

    public var durationText: String {
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    // MARK: - Probing

    public static func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let (duration, tracks) = try await asset.load(.duration, .tracks)

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        var width = 0, height = 0
        var fps = 0.0
        var videoCodec: String?
        var videoFourCC: String?
        var audioCodec: String?
        var hasAudio = false

        if let video = tracks.first(where: { $0.mediaType == .video }) {
            let (descs, frameRate, naturalSize) = try await video.load(
                .formatDescriptions, .nominalFrameRate, .naturalSize)
            width = Int(abs(naturalSize.width).rounded())
            height = Int(abs(naturalSize.height).rounded())
            fps = Double(frameRate)
            if let desc = descs.first {
                let fourCC = desc.mediaSubType.rawValue.fourCCString
                videoFourCC = fourCC
                videoCodec = Self.videoCodecName(fourCC)
            }
        }

        if let audio = tracks.first(where: { $0.mediaType == .audio }) {
            hasAudio = true
            let descs = try await audio.load(.formatDescriptions)
            if let desc = descs.first {
                audioCodec = Self.audioCodecName(desc.mediaSubType.rawValue.fourCCString)
            }
        }

        return MediaInfo(url: url, fileSizeBytes: fileSize,
                         duration: duration.seconds,
                         width: width, height: height, fps: fps,
                         videoCodec: videoCodec, videoCodecFourCC: videoFourCC,
                         audioCodec: audioCodec, hasAudio: hasAudio)
    }

    static func videoCodecName(_ fourCC: String) -> String {
        switch fourCC {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "ap4h": return "ProRes 4444"
        case "apch": return "ProRes 422 HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422 LT"
        case "apco": return "ProRes 422 Proxy"
        case "jpeg": return "MJPEG"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        default: return fourCC
        }
    }

    static func audioCodecName(_ fourCC: String) -> String {
        switch fourCC {
        case "aac ", "mp4a": return "AAC"
        case "lpcm", "sowt", "twos": return "PCM"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case ".mp3": return "MP3"
        default: return fourCC.trimmingCharacters(in: .whitespaces)
        }
    }
}

extension FourCharCode {
    var fourCCString: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(self)
    }
}
