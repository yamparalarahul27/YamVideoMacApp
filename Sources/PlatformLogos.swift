import SwiftUI

/// Each platform's own logo, drawn from its official shape, at any size: YouTube's red
/// play button, Instagram's camera on its gradient, X's mark in black and white, and
/// LinkedIn's "in" on blue. Nothing is downloaded or bundled. The Calendar shows it in
/// colour once a video is posted there and in grey while it is still to come.
struct PlatformLogo: View {
    let platform: Platform
    var size: CGFloat = 16
    /// The same shape in grey, for a platform it is not posted on yet.
    var gray = false

    /// The logo's ground and its mark, in brand colours or in grey.
    private var ground: Color { Color(white: 0.5) }
    private var mark: Color { gray ? Color(white: 0.9) : .white }

    var body: some View {
        switch platform {
        case .youtube: youtube
        case .instagram: instagram
        case .x: x
        case .linkedin: linkedin
        }
    }

    private var youtube: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(gray ? ground : Color(red: 1, green: 0, blue: 0))
                .frame(width: size * 1.42, height: size)
            PlayTriangle().fill(mark).frame(width: size * 0.36, height: size * 0.42).offset(x: size * 0.04)
        }
        .frame(width: size * 1.42, height: size)
    }

    /// Instagram's gradient, from its yellow corner at the bottom left to purple and blue.
    private static let instagramColors = [
        Color(red: 1, green: 0.86, blue: 0.5), Color(red: 0.99, green: 0.69, blue: 0.27), Color(red: 0.97, green: 0.47, blue: 0.22),
        Color(red: 0.88, green: 0.19, blue: 0.42), Color(red: 0.76, green: 0.21, blue: 0.52), Color(red: 0.51, green: 0.23, blue: 0.71),
        Color(red: 0.35, green: 0.32, blue: 0.86),
    ]

    private var instagram: some View {
        let line = max(1, size * 0.085)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(RadialGradient(colors: gray ? [ground, ground] : Self.instagramColors, center: UnitPoint(x: 0.3, y: 1.07),
                                     startRadius: 0, endRadius: size * 1.35))
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .strokeBorder(mark, lineWidth: line)
                .frame(width: size * 0.66, height: size * 0.66)
            Circle().strokeBorder(mark, lineWidth: line).frame(width: size * 0.32, height: size * 0.32)
            Circle().fill(mark).frame(width: size * 0.09, height: size * 0.09)
                .offset(x: size * 0.17, y: -size * 0.17)
        }
        .frame(width: size, height: size)
    }

    private var x: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(gray ? ground : .black)
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Color.white.opacity(gray ? 0 : 0.35), lineWidth: 0.6)
            XMark().fill(mark, style: FillStyle(eoFill: true)).frame(width: size * 0.58, height: size * 0.59)
        }
        .frame(width: size, height: size)
    }

    private var linkedin: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous).fill(gray ? ground : Color(red: 0.04, green: 0.4, blue: 0.76))
            LinkedInMark().fill(mark).frame(width: size * 0.62, height: size * 0.6).offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

/// YouTube's play triangle, pointing right.
private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// X's mark: the official logo's outline (a 1200 × 1227 drawing), all straight lines,
/// filled even-odd so its inner stroke is open.
private struct XMark: Shape {
    private static let outer: [(CGFloat, CGFloat)] = [
        (714.163, 519.284), (1160.89, 0), (1055.03, 0), (667.137, 450.887), (357.328, 0), (0, 0), (468.492, 681.821),
        (0, 1226.37), (105.866, 1226.37), (515.491, 750.218), (842.672, 1226.37), (1200, 1226.37), (714.137, 519.284),
    ]
    private static let inner: [(CGFloat, CGFloat)] = [
        (569.165, 687.828), (521.697, 619.934), (144.011, 79.6944), (306.615, 79.6944), (611.412, 515.685),
        (658.88, 583.579), (1055.08, 1150.3), (892.476, 1150.3), (569.165, 687.854),
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for points in [Self.outer, Self.inner] {
            path.addLines(points.map { CGPoint(x: rect.minX + $0.0 / 1200 * rect.width, y: rect.minY + $0.1 / 1226.37 * rect.height) })
            path.closeSubpath()
        }
        return path
    }
}

/// LinkedIn's "in": the dot and stem of the i, and the n's stem and arch.
private struct LinkedInMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.addEllipse(in: CGRect(origin: point(0, 0), size: CGSize(width: 0.26 * rect.width, height: 0.26 * rect.height)))
        path.addRect(CGRect(origin: point(0.015, 0.34), size: CGSize(width: 0.23 * rect.width, height: 0.66 * rect.height)))
        // The n: its stem, then the arch down to the right stem's foot and back.
        path.move(to: point(0.36, 1))
        path.addLine(to: point(0.36, 0.34))
        path.addLine(to: point(0.58, 0.34))
        path.addLine(to: point(0.58, 0.43))
        path.addCurve(to: point(0.8, 0.31), control1: point(0.62, 0.36), control2: point(0.7, 0.31))
        path.addCurve(to: point(1, 0.58), control1: point(0.95, 0.31), control2: point(1, 0.4))
        path.addLine(to: point(1, 1))
        path.addLine(to: point(0.78, 1))
        path.addLine(to: point(0.78, 0.63))
        path.addCurve(to: point(0.69, 0.5), control1: point(0.78, 0.55), control2: point(0.75, 0.5))
        path.addCurve(to: point(0.58, 0.64), control1: point(0.62, 0.5), control2: point(0.58, 0.55))
        path.addLine(to: point(0.58, 1))
        path.closeSubpath()
        return path
    }
}

/// A platform's logo as the Calendar shows its state there: in colour once posted, in
/// grey while it is to come, and grey in a red ring once its day has passed without it.
struct PlatformStatusLogo: View {
    let platform: Platform
    let posted: Bool
    let missed: Bool
    var size: CGFloat = 14

    var body: some View {
        PlatformLogo(platform: platform, size: size, gray: !posted)
            .opacity(posted || missed ? 1 : 0.55)
            .padding(missed ? 1.5 : 0)
            .overlay {
                if missed {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Color.red, lineWidth: max(1.2, size * 0.1))
                }
            }
            .padding(missed ? 0 : 1.5)
            .help(platform.label + (posted ? ": posted" : missed ? ": not posted, and its day has passed" : ": planned"))
            .accessibilityLabel(platform.label + (posted ? ", posted" : missed ? ", not posted" : ", planned"))
    }
}
