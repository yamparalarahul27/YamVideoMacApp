import CryptoKit
import Foundation

/// A 3D colour table, as a `.cube` file holds one.
///
/// Both renderers apply tables the same way — trilinear, inputs clamped to the domain —
/// so `sample` here is the reference the parity checks hold them to.
struct ColorCube: Equatable {
    /// Larger files are refused before they are read: a 65³ table is about 9 MB of text.
    static let maximumBytes = 16 * 1024 * 1024
    static let sizes = 2...65

    let size: Int
    /// RGB triples with red changing fastest, then green, then blue: the `.cube` order.
    let values: [Float]
    let domainMin: [Double]
    let domainMax: [Double]

    init(size: Int, values: [Float], domainMin: [Double] = [0, 0, 0], domainMax: [Double] = [1, 1, 1]) {
        precondition(values.count == size * size * size * 3, "a \(size)³ table holds \(size * size * size) RGB rows")
        self.size = size; self.values = values; self.domainMin = domainMin; self.domainMax = domainMax
    }

    static func identity(size: Int) -> ColorCube {
        build(size: size) { $0 }
    }

    /// A table over the unit domain whose entry at each grid point is `transform` of
    /// that point's coordinates.
    static func build(size: Int, _ transform: (SIMD3<Double>) -> SIMD3<Double>) -> ColorCube {
        let step = 1 / Double(size - 1)
        var values = [Float](); values.reserveCapacity(size * size * size * 3)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let out = transform(SIMD3(Double(r) * step, Double(g) * step, Double(b) * step))
            values += [Float(out.x), Float(out.y), Float(out.z)]
        } } }
        return ColorCube(size: size, values: values)
    }

    var isUnitDomain: Bool { domainMin == [0, 0, 0] && domainMax == [1, 1, 1] }

    /// The same table with every entry clipped to 0–1. Unchanged when it already is.
    func clampedToUnit() -> ColorCube {
        values.allSatisfy({ (0...1).contains($0) }) ? self
            : ColorCube(size: size, values: values.map { min(1, max(0, $0)) }, domainMin: domainMin, domainMax: domainMax)
    }

    /// Trilinear interpolation. Inputs outside the domain are clamped to its edge, as
    /// both ffmpeg's `lut3d` and Core Image's colour cube do.
    func sample(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let last = Double(size - 1)
        func axis(_ value: Double, _ channel: Int) -> (Int, Double) {
            let span = domainMax[channel] - domainMin[channel]
            let clamped = min(max(value.isFinite ? value : 0, domainMin[channel]), domainMax[channel])
            let t = (clamped - domainMin[channel]) / span * last
            let index = min(Int(t), size - 2)
            return (index, t - Double(index))
        }
        let (r, fr) = axis(rgb.x, 0), (g, fg) = axis(rgb.y, 1), (b, fb) = axis(rgb.z, 2)
        func entry(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
            let i = ((b * size + g) * size + r) * 3
            return SIMD3(Double(values[i]), Double(values[i + 1]), Double(values[i + 2]))
        }
        func lerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
        let c00 = lerp(entry(r, g, b), entry(r + 1, g, b), fr)
        let c10 = lerp(entry(r, g + 1, b), entry(r + 1, g + 1, b), fr)
        let c01 = lerp(entry(r, g, b + 1), entry(r + 1, g, b + 1), fr)
        let c11 = lerp(entry(r, g + 1, b + 1), entry(r + 1, g + 1, b + 1), fr)
        return lerp(lerp(c00, c10, fg), lerp(c01, c11, fg), fb)
    }

    /// The same table over the unit domain, which is all Core Image's colour cube
    /// understands. A unit-domain table comes back unchanged.
    func unitDomain() -> ColorCube {
        isUnitDomain ? self : ColorCube.build(size: size) { point in
            let mapped = SIMD3((0..<3).map { domainMin[$0] + point[$0] * (domainMax[$0] - domainMin[$0]) })
            return sample(mapped)
        }
    }

    /// `.cube` text for ffmpeg's `lut3d`. Nine significant digits keep a Float exactly.
    func cubeText(title: String) -> String {
        var text = "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"\nLUT_3D_SIZE \(size)\n"
        if !isUnitDomain {
            text += "DOMAIN_MIN \(domainMin.map { String($0) }.joined(separator: " "))\n"
            text += "DOMAIN_MAX \(domainMax.map { String($0) }.joined(separator: " "))\n"
        }
        text.reserveCapacity(text.count + values.count * 12)
        for row in stride(from: 0, to: values.count, by: 3) {
            text += "\(String(format: "%.9g", values[row])) \(String(format: "%.9g", values[row + 1])) \(String(format: "%.9g", values[row + 2]))\n"
        }
        return text
    }

    /// RGBA float32 rows in `.cube` order, which is also what Core Image's colour cube
    /// takes. Only meaningful for a unit-domain table.
    var coreImageData: Data {
        var rgba = [Float](); rgba.reserveCapacity(values.count / 3 * 4)
        for row in stride(from: 0, to: values.count, by: 3) {
            rgba += [values[row], values[row + 1], values[row + 2], 1]
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

struct ColorCubeError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension ColorCube {
    /// Reads the subset of `.cube` the colour workflow relies on: one 3D table with
    /// `LUT_3D_SIZE` from 2 to 65, optional `TITLE`, `DOMAIN_MIN`/`DOMAIN_MAX` (or
    /// Resolve's `LUT_3D_INPUT_RANGE`), `#` comments, and any line endings. 1D tables and
    /// shapers are refused rather than half-applied. Nothing in the file is executed.
    static func parse(_ data: Data) throws -> ColorCube {
        func fail(_ message: String) -> ColorCubeError { ColorCubeError(message: message) }
        guard data.count <= maximumBytes else { throw fail("The file is larger than 16 MB, too large for a colour table.") }
        guard var text = String(data: data, encoding: .utf8) else { throw fail("The file is not text, so it is not a .cube table.") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        var size: Int?
        var domainMin = [0.0, 0.0, 0.0], domainMax = [1.0, 1.0, 1.0]
        var values: [Float] = []
        var number = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            number += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = fields.first else { continue }
            if keyword.first?.isLetter == true {
                guard values.isEmpty else { throw fail("Line \(number): \(keyword) appears after the table has started.") }
                func triple() throws -> [Double] {
                    let numbers = fields.dropFirst().compactMap(Double.init)
                    guard fields.count == 4, numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
                        throw fail("Line \(number): \(keyword) needs three numbers.")
                    }
                    return numbers
                }
                switch keyword {
                case "TITLE": continue
                case "LUT_3D_SIZE":
                    guard fields.count == 2, let value = Int(fields[1]), sizes.contains(value) else {
                        throw fail("Line \(number): LUT_3D_SIZE must be a whole number from 2 to 65.")
                    }
                    guard size == nil else { throw fail("Line \(number): LUT_3D_SIZE is given twice.") }
                    size = value
                case "DOMAIN_MIN": domainMin = try triple()
                case "DOMAIN_MAX": domainMax = try triple()
                case "LUT_3D_INPUT_RANGE":
                    let numbers = fields.dropFirst().compactMap(Double.init)
                    guard fields.count == 3, numbers.count == 2, numbers.allSatisfy(\.isFinite) else {
                        throw fail("Line \(number): LUT_3D_INPUT_RANGE needs two numbers.")
                    }
                    domainMin = Array(repeating: numbers[0], count: 3); domainMax = Array(repeating: numbers[1], count: 3)
                case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                    throw fail("This file has a 1D table or shaper. Only a single 3D table is supported.")
                default:
                    throw fail("Line \(number): \(keyword) is not something a .cube colour table may contain.")
                }
                continue
            }
            guard let size else { throw fail("Line \(number): the table starts before LUT_3D_SIZE says how big it is.") }
            let numbers = fields.compactMap(Float.init)
            guard fields.count == 3, numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
                throw fail("Line \(number): each row of the table needs three finite numbers.")
            }
            guard values.count < size * size * size * 3 else {
                throw fail("The table has more than the \(size * size * size) rows a \(size)³ table holds.")
            }
            values += numbers
        }
        guard let size else { throw fail("There is no LUT_3D_SIZE line, so this is not a 3D .cube table.") }
        let expected = size * size * size
        guard values.count == expected * 3 else {
            throw fail("The table has \(values.count / 3) rows; a \(size)³ table needs \(expected).")
        }
        guard (0..<3).allSatisfy({ domainMin[$0] < domainMax[$0] }) else {
            throw fail("DOMAIN_MIN must be below DOMAIN_MAX for every channel.")
        }
        return ColorCube(size: size, values: values, domainMin: domainMin, domainMax: domainMax)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
