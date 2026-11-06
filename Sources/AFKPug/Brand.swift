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
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(scaled(size, active: active).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
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
