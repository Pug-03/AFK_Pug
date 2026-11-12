import SwiftUI
import AppKit

/// The app's glyph, drawn in a 32 × 32 box: an open "A" at rest, with a crossbar while active.
enum AppGlyph {
    static func path(active: Bool) -> Path {
        var lines = Path()
        lines.move(to: CGPoint(x: 6, y: 26.5))
        lines.addLine(to: CGPoint(x: 16, y: 5.5))
        lines.addLine(to: CGPoint(x: 26, y: 26.5))
        if active {
            lines.move(to: CGPoint(x: 9.5, y: 20.5))
            lines.addLine(to: CGPoint(x: 22.5, y: 20.5))
        }
        return lines.strokedPath(StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round))
    }

    fileprivate static func scaled(_ size: CGFloat, active: Bool) -> Path {
        path(active: active).applying(CGAffineTransform(scaleX: size / 32, y: size / 32))
    }

    /// Template image for the menu bar, so macOS tints it for light and dark bars.
    static func menuImage(active: Bool) -> NSImage {
        menuImage(crossbar: active ? 1 : 0)
    }

    /// One frame of the menu bar icon. `crossbar` is the bar's opacity (it breathes while
    /// agents work). `ring` is the share of the countdown left: the glyph shrinks into a
    /// ring that empties clockwise. `tint` draws a colored (non-template) frame.
    static func menuImage(crossbar: CGFloat, ring: Double? = nil, tint: NSColor? = nil) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let color = (tint ?? .black).cgColor
            var glyph: CGFloat = size, offset: CGFloat = 0
            if let ring {
                glyph = 10; offset = (size - glyph) / 2
                let center = CGPoint(x: size / 2, y: size / 2), radius = size / 2 - 1
                context.setLineWidth(1.6)
                context.setLineCap(.round)
                context.setStrokeColor(color.copy(alpha: 0.3) ?? color)
                context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.strokePath()
                let left = max(0, min(1, ring))
                if left > 0 {
                    // Flipped context: clockwise on screen from 12 o'clock.
                    context.setStrokeColor(color)
                    context.addArc(center: center, radius: radius, startAngle: -.pi / 2,
                                   endAngle: -.pi / 2 + 2 * .pi * left, clockwise: false)
                    context.strokePath()
                }
            }
            let move = CGAffineTransform(translationX: offset, y: offset)
            context.addPath(scaled(glyph, active: false).applying(move).cgPath)
            context.setFillColor(color)
            context.fillPath()
            if crossbar > 0 {
                context.addPath(crossbarPath(glyph).applying(move).cgPath)
                context.setFillColor(color.copy(alpha: crossbar) ?? color)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = tint == nil
        return image
    }

    /// Bright red behind the waiting badge. White text on it measures 4.7:1.
    static let waitingRed = NSColor(srgbRed: 0xE5 / 255.0, green: 0x14 / 255.0, blue: 0x1F / 255.0, alpha: 1)

    /// The menu bar while an agent waits for you: a bright red badge with a white A and
    /// `text`, so it reads from across the room. `dim` is the blink's off beat.
    static func waitingBadge(text: String, dim: Bool = false) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let glyph: CGFloat = 12, pad: CGFloat = 6, gap: CGFloat = 4, height: CGFloat = 18
        let width = ceil(pad + glyph + gap + label.size().width + pad)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setAlpha(dim ? 0.55 : 1)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.setFillColor(waitingRed.cgColor)
            context.fillPath()
            let move = CGAffineTransform(translationX: pad, y: (height - glyph) / 2)
            context.addPath(scaled(glyph, active: true).applying(move).cgPath)
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
            label.draw(at: NSPoint(x: pad + glyph + gap, y: (height - label.size().height) / 2))
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = text
        return image
    }

    private static func crossbarPath(_ size: CGFloat) -> Path {
        var bar = Path()
        bar.move(to: CGPoint(x: 9.5, y: 20.5))
        bar.addLine(to: CGPoint(x: 22.5, y: 20.5))
        return bar.strokedPath(StrokeStyle(lineWidth: 4.6, lineCap: .round))
            .applying(CGAffineTransform(scaleX: size / 32, y: size / 32))
    }
}

enum MenuMotion: Equatable {
    case still, working, waiting
    case countdown(until: Date, length: TimeInterval)
}

struct GlyphView: View {
    var active = false
    var size: CGFloat
    var color: Color

    var body: some View {
        AppGlyph.scaled(size, active: active)
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The glyph on a quiet rounded tile, for the popover and onboarding.
struct AppMark: View {
    @ObservedObject var themeStore = ThemeStore.shared
    var size: CGFloat = 34

    var body: some View {
        GlyphView(size: size * 0.6, color: Theme.accent)
            .frame(width: size, height: size)
            .cardBackground(radius: size * 0.28)
    }
}

/// App icon: the white glyph on a black rounded square, with a hairline so it holds its
/// shape on a dark Dock.
struct AppIconView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(Color.black)
            .overlay {
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 5)
            }
            .frame(width: 824, height: 824)
            .overlay { GlyphView(size: 500, color: .white) }
            .frame(width: 1024, height: 1024)
    }
}
