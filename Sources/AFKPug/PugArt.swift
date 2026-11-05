import SwiftUI
import AppKit

enum Palette {
    static let fawn = Color(red: 0.91, green: 0.76, blue: 0.58)
    static let fawnLight = Color(red: 0.97, green: 0.87, blue: 0.72)
    static let mask = Color(red: 0.22, green: 0.17, blue: 0.15)
    static let apricot = Color(red: 0.96, green: 0.56, blue: 0.27)
    static let apricotDeep = Color(red: 0.88, green: 0.40, blue: 0.20)
    static let awake = Color(red: 0.29, green: 0.74, blue: 0.47)
    static let night = Color(red: 0.42, green: 0.45, blue: 0.80)
    static let warn = Color(red: 0.93, green: 0.36, blue: 0.33)
    static let tongue = Color(red: 0.95, green: 0.48, blue: 0.55)
}

/// The pug, drawn with shapes so it scales from menu to app icon.
/// Deliberately static: no blink/breathe loops, so nothing animates while the
/// popover is open (or keeps a task alive while it is closed). Mood changes
/// crossfade via the caller's `.animation(_, value: mood)`.
struct PugFace: View {
    var mood: PugMood
    var size: CGFloat = 72
    /// Shows the "zzz" mark when sleeping. Off for the app icon.
    var animated = true

    var body: some View {
        let s = size
        ZStack {
            // Ears
            Ear().fill(Palette.mask)
                .frame(width: s * 0.30, height: s * 0.34)
                .rotationEffect(.degrees(18))
                .offset(x: -s * 0.40, y: -s * 0.24)
            Ear().fill(Palette.mask)
                .frame(width: s * 0.30, height: s * 0.34)
                .scaleEffect(x: -1)
                .rotationEffect(.degrees(-18))
                .offset(x: s * 0.40, y: -s * 0.24)

            // Head
            RoundedRectangle(cornerRadius: s * 0.40, style: .continuous)
                .fill(LinearGradient(colors: [Palette.fawnLight, Palette.fawn], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.94, height: s * 0.84)
                .shadow(color: .black.opacity(0.12), radius: s * 0.04, y: s * 0.02)

            // Forehead wrinkles
            VStack(spacing: s * 0.035) {
                Wrinkle().stroke(Palette.mask.opacity(0.28), style: StrokeStyle(lineWidth: s * 0.022, lineCap: .round))
                    .frame(width: s * 0.22, height: s * 0.05)
                Wrinkle().stroke(Palette.mask.opacity(0.20), style: StrokeStyle(lineWidth: s * 0.02, lineCap: .round))
                    .frame(width: s * 0.14, height: s * 0.04)
            }
            .offset(y: -s * 0.27)

            // Muzzle mask
            Ellipse()
                .fill(Palette.mask)
                .frame(width: s * 0.56, height: s * 0.40)
                .offset(y: s * 0.17)

            // Tongue when awake
            if mood == .awake {
                Capsule()
                    .fill(Palette.tongue)
                    .frame(width: s * 0.11, height: s * 0.13)
                    .offset(y: s * 0.30)
            }

            // Nose
            Capsule()
                .fill(Color.black.opacity(0.9))
                .frame(width: s * 0.17, height: s * 0.085)
                .offset(y: s * 0.06)

            // Mouth
            Mouth().stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: s * 0.022, lineCap: .round))
                .frame(width: s * 0.20, height: s * 0.08)
                .offset(y: s * 0.17)

            // Eyes
            HStack(spacing: s * 0.24) {
                eye(left: true)
                eye(left: false)
            }
            .offset(y: -s * 0.08)
        }
        .frame(width: s * 1.2, height: s)
        .overlay(alignment: .topTrailing) {
            if mood == .sleeping, animated {
                Zzz(size: s).offset(x: s * 0.12, y: -s * 0.12).transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func eye(left: Bool) -> some View {
        let s = size
        switch mood {
        case .sleeping:
            ClosedEye()
                .stroke(Palette.mask, style: StrokeStyle(lineWidth: s * 0.035, lineCap: .round))
                .frame(width: s * 0.17, height: s * 0.07)
        case .awake, .worried:
            ZStack {
                Circle().fill(Palette.mask).frame(width: s * 0.19, height: s * 0.19)
                Circle().fill(.white).frame(width: s * 0.06, height: s * 0.06)
                    .offset(x: s * 0.03, y: -s * 0.035)
                if mood == .worried {
                    Capsule().fill(Palette.mask)
                        .frame(width: s * 0.16, height: s * 0.03)
                        .rotationEffect(.degrees(left ? -20 : 20))
                        .offset(y: -s * 0.14)
                }
            }
        }
    }
}

private struct Ear: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.15))
        p.addCurve(to: CGPoint(x: r.minX + r.width * 0.25, y: r.maxY),
                   control1: CGPoint(x: r.minX + r.width * 0.2, y: r.minY - r.height * 0.1),
                   control2: CGPoint(x: r.minX - r.width * 0.15, y: r.maxY * 0.8))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.75),
                       control: CGPoint(x: r.midX + r.width * 0.2, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Wrinkle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
        return p
    }
}

private struct ClosedEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6))
        return p
    }
}

private struct Mouth: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.width * 0.25, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.width * 0.75, y: r.maxY))
        return p
    }
}

private struct Zzz: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Text("z")
                    .font(.system(size: size * (0.14 + CGFloat(i) * 0.05), weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.80, green: 0.82, blue: 1.0).opacity(1 - Double(i) * 0.2))
                    .offset(x: CGFloat(i) * size * 0.1, y: CGFloat(-i) * size * 0.12)
            }
        }
        .accessibilityHidden(true)
    }
}

/// App icon: the pug on a warm rounded square.
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.80, blue: 0.55), Palette.apricotDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 824, height: 824)
                .overlay(
                    Circle().fill(.white.opacity(0.16)).frame(width: 640, height: 640).offset(x: -170, y: -200)
                )
                .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))
            PugFace(mood: .awake, size: 520, animated: false).offset(y: 40)
            Text("AFK")
                .font(.system(size: 110, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 36).padding(.vertical, 6)
                .background(Capsule().fill(Palette.mask))
                .offset(x: 220, y: -270)
                .rotationEffect(.degrees(8))
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Monochrome template icon for the menu bar: an outlined pug face with
/// folded ears, a dark muzzle and a forehead wrinkle.
enum MenuIcon {
    static func make(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            draw(active: active)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(active: Bool) {
        NSColor.black.setFill()
        NSColor.black.setStroke()

        // Wide, soft head
        let head = NSBezierPath(roundedRect: NSRect(x: 3.4, y: 1.8, width: 15.2, height: 12.6), xRadius: 5.6, yRadius: 5.6)
        head.lineWidth = 1.35
        head.stroke()

        // Folded "button" ears: triangles flopping forward over the top corners
        for flip in [false, true] {
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: flip ? 22 - x : x, y: y) }
            let ear = NSBezierPath()
            ear.move(to: pt(2.2, 13.4))
            ear.curve(to: pt(8.6, 15.0), controlPoint1: pt(3.8, 15.6), controlPoint2: pt(6.6, 15.8))
            ear.curve(to: pt(4.4, 9.6), controlPoint1: pt(7.4, 12.6), controlPoint2: pt(5.6, 10.6))
            ear.curve(to: pt(2.2, 13.4), controlPoint1: pt(3.2, 10.6), controlPoint2: pt(2.0, 12.0))
            ear.close()
            ear.fill()
        }

        // Forehead wrinkles
        for (y, half) in [(12.0, 1.8)] as [(CGFloat, CGFloat)] {
            let w = NSBezierPath()
            w.move(to: NSPoint(x: 11 - half, y: y))
            w.curve(to: NSPoint(x: 11 + half, y: y), controlPoint1: NSPoint(x: 11 - half / 2, y: y + 0.8), controlPoint2: NSPoint(x: 11 + half / 2, y: y + 0.8))
            w.lineWidth = 0.9
            w.lineCapStyle = .round
            w.stroke()
        }

        // Big round eyes (open) or sleepy arcs (closed)
        if active {
            NSBezierPath(ovalIn: NSRect(x: 6.2, y: 7.6, width: 3.0, height: 3.0)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.8, y: 7.6, width: 3.0, height: 3.0)).fill()
        } else {
            for x in [6.1, 12.7] as [CGFloat] {
                let eye = NSBezierPath()
                eye.move(to: NSPoint(x: x, y: 9.4))
                eye.curve(to: NSPoint(x: x + 3.2, y: 9.4), controlPoint1: NSPoint(x: x + 0.8, y: 8.2), controlPoint2: NSPoint(x: x + 2.4, y: 8.2))
                eye.lineWidth = 1.2
                eye.lineCapStyle = .round
                eye.stroke()
            }
        }

        // Wide dark muzzle with nose and mouth cut out
        NSBezierPath(ovalIn: NSRect(x: 6.6, y: 2.5, width: 8.8, height: 5.0)).fill()
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 9.5, y: 5.3, width: 3.0, height: 1.5)).fill()
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: 9.4, y: 4.0))
        mouth.curve(to: NSPoint(x: 11, y: 4.3), controlPoint1: NSPoint(x: 9.9, y: 3.5), controlPoint2: NSPoint(x: 10.6, y: 3.6))
        mouth.curve(to: NSPoint(x: 12.6, y: 4.0), controlPoint1: NSPoint(x: 11.4, y: 3.6), controlPoint2: NSPoint(x: 12.1, y: 3.5))
        mouth.lineWidth = 0.7
        mouth.lineCapStyle = .round
        mouth.stroke()
        ctx.compositingOperation = .sourceOver
    }
}
