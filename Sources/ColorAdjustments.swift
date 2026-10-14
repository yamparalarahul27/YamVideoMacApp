import Foundation

/// How a recording's colours were recorded, which decides how they are brought to
/// standard Rec.709 before anything else touches them.
enum ColorInputProfile: String, Codable, CaseIterable, Identifiable {
    /// Decide from trusted metadata; when the file cannot say, ask rather than guess.
    case auto
    /// Already standard colour: nothing to convert.
    case standard
    /// DJI Osmo Pocket 3 D-Log M, converted by DJI's own technical table.
    case pocket3DLogM
    case hlg, pq

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .standard: return "Standard / already corrected"
        case .pocket3DLogM: return "DJI Pocket 3 D-Log M"
        case .hlg: return "HDR (HLG)"
        case .pq: return "HDR (PQ)"
        }
    }

    var isHDR: Bool { self == .hlg || self == .pq }
}

/// A technical conversion table the project uses, identified by its content.
///
/// The table itself lives in the app's table store and, once the project is saved, in a
/// `YamVideo Assets` folder beside the project, both named by hash. A same-named file
/// with different contents is a different table.
struct LUTAssetRef: Codable, Equatable, Hashable {
    enum Role: String, Codable { case pocket3DLogMToRec709 }

    /// SHA-256 of the `.cube` file, lowercase hex.
    var sha256: String
    /// What the file was called when imported, for display only.
    var originalName: String
    var role: Role
}

/// The four beginner controls. Values are absolute; neutral leaves the picture alone.
struct ColorAdjustments: Codable, Equatable {
    var exposureEV = 0.0
    var warmth = 0.0
    var contrast = 1.0
    var saturation = 1.0

    static let neutral = ColorAdjustments()
    static let exposureRange = -2.0...2.0
    static let warmthRange = -1.0...1.0
    static let contrastRange = 0.5...1.5
    static let saturationRange = 0.0...2.0

    var isNeutral: Bool { self == .neutral }

    /// The BT.1886 reference EOTF with black at 0 and white at 1: a pure 2.4 power. Its
    /// exact inverse re-encodes, so neutral settings round-trip and the 0.18 contrast
    /// pivot sits near mid-grey. Signs are kept so nothing clamps before delivery.
    static let gamma = 2.4
    static func decode(_ value: Double) -> Double { value < 0 ? -pow(-value, gamma) : pow(value, gamma) }
    static func encode(_ value: Double) -> Double { value < 0 ? -pow(-value, 1 / gamma) : pow(value, 1 / gamma) }

    /// Rec.709 luminance weights.
    static let luma = SIMD3(0.2126, 0.7152, 0.0722)

    /// Encoded Rec.709 RGB in, encoded Rec.709 RGB out, through linear light in the
    /// table's order: exposure, warmth, contrast about 0.18, saturation. Algorithm 1.
    func apply(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
        var linear = SIMD3(Self.decode(encoded.x), Self.decode(encoded.y), Self.decode(encoded.z))
        linear *= pow(2, exposureEV)
        // Warm or cool without moving neutral grey's luminance.
        let gains = SIMD3(pow(2, 0.2 * warmth), 1, pow(2, -0.2 * warmth))
        linear *= gains / (gains * Self.luma).sum()
        linear = 0.18 + contrast * (linear - 0.18)
        let y = (linear * Self.luma).sum()
        linear = y + saturation * (linear - y)
        return SIMD3(Self.encode(linear.x), Self.encode(linear.y), Self.encode(linear.z))
    }
}

/// One recording's colour settings, stored with the project.
struct ClipColorSettings: Codable, Equatable {
    /// The adjustment maths in effect. A change to it gets a new number, so an older
    /// project never silently changes appearance.
    static let currentAlgorithm = 1

    var inputProfile: ColorInputProfile = .auto
    var technicalLUT: LUTAssetRef?
    /// Natural colour: whether the technical conversion is applied. Turning it off is
    /// explicit; resetting the adjustments leaves it alone.
    var correctionEnabled = false
    var exposureEV = 0.0
    var warmth = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var algorithmVersion = ClipColorSettings.currentAlgorithm

    var adjustments: ColorAdjustments {
        get { ColorAdjustments(exposureEV: exposureEV, warmth: warmth, contrast: contrast, saturation: saturation) }
        set { exposureEV = newValue.exposureEV; warmth = newValue.warmth; contrast = newValue.contrast; saturation = newValue.saturation }
    }

    /// Nothing chosen and nothing adjusted: what every recording starts as.
    var isDefault: Bool { self == ClipColorSettings() }

    /// Every number in range, a known algorithm, and a conversion only where it belongs.
    func validate() throws {
        func reject(_ message: String) -> FFmpegError { FFmpegError(message: message) }
        guard algorithmVersion == Self.currentAlgorithm else {
            throw reject("Colour algorithm \(algorithmVersion) is not one this build knows; it uses \(Self.currentAlgorithm).")
        }
        let checks: [(String, Double, ClosedRange<Double>)] = [
            ("Brightness", exposureEV, ColorAdjustments.exposureRange), ("Warmth", warmth, ColorAdjustments.warmthRange),
            ("Contrast", contrast, ColorAdjustments.contrastRange), ("Colour strength", saturation, ColorAdjustments.saturationRange),
        ]
        for (name, value, range) in checks where !value.isFinite || !range.contains(value) {
            throw reject("\(name) must be from \(range.lowerBound.formatted()) to \(range.upperBound.formatted()).")
        }
        if let technicalLUT {
            guard inputProfile == .pocket3DLogM, technicalLUT.role == .pocket3DLogMToRec709 else {
                throw reject("A Pocket 3 D-Log M conversion only applies to recordings set to Pocket 3 D-Log M.")
            }
            guard technicalLUT.sha256.count == 64, technicalLUT.sha256.allSatisfy(\.isHexDigit) else {
                throw reject("A conversion table is identified by a 64-character SHA-256.")
            }
        }
        if correctionEnabled, technicalLUT == nil {
            throw reject("Natural colour needs the DJI conversion table first.")
        }
    }

    /// What the file itself rules out: HDR profiles need HDR tags, and D-Log M is never
    /// tagged HDR, so the technical table and tone mapping can never both run.
    func validate(against info: MediaInfo) throws {
        switch inputProfile {
        case .hlg where info.colorTransfer != "arib-std-b67", .pq where info.colorTransfer != "smpte2084":
            throw FFmpegError(message: "This recording is not tagged \(inputProfile == .hlg ? "HLG" : "PQ"), so it cannot be read as that HDR format.")
        case .pocket3DLogM where info.isHDR:
            throw FFmpegError(message: "This recording is tagged \(info.hdrLabel ?? "HDR"); Pocket 3 D-Log M recordings are not.")
        default: break
        }
    }
}

/// How the picture shows the colour stage while it is being judged.
enum ColorComparison: String, CaseIterable, Identifiable {
    case corrected, original, split
    var id: String { rawValue }
    var label: String {
        switch self {
        case .corrected: return "Corrected"
        case .original: return "Original"
        case .split: return "Compare"
        }
    }
}

// MARK: - What Auto means

extension MediaInfo {
    /// The profile Auto settles on for this file, and why. Nil means the file cannot say:
    /// a DJI recording may be Normal or D-Log M, and its tags do not tell them apart, so
    /// the picture stays as recorded until the owner chooses.
    ///
    /// Only HDR transfer tags count as proof. A camera name, a file name, low contrast or
    /// a generic Rec.709 tag are not evidence of D-Log M.
    func inferredColorProfile(fileName: String) -> (profile: ColorInputProfile?, evidence: String) {
        switch colorTransfer {
        case "smpte2084": return (.pq, "The file is tagged HDR10 (PQ).")
        case "arib-std-b67": return (.hlg, "The file is tagged HLG.")
        default:
            let make = (cameraMake ?? "").uppercased()
            if fileName.uppercased().hasPrefix("DJI_") || make.contains("DJI") {
                return (nil, "This looks like a DJI recording, which may be Normal or D-Log M. The file does not say which.")
            }
            return (.standard, "The file has no log or HDR colour tags.")
        }
    }
}
