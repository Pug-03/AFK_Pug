import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.boot() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.shutdown() }
    }

    /// afkpug://start?minutes=90, stop, toggle, sleep-now (Shortcuts, scripts, Raycast …).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { Engine.shared.handle(url: $0) } }
    }
}

struct AFKPugApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The App does not observe Engine: it republishes every tick, which would
    // re-evaluate the whole scene and redraw the menu bar label each time.
    // RootView observes it itself; the label only follows `isActive`.
    var body: some Scene {
        MenuBarExtra {
            RootView(engine: Engine.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar icon. Re-renders only when `Engine.isActive` actually flips.
private struct MenuBarLabel: View {
    @State private var active = Engine.shared.isActive

    var body: some View {
        Image(systemName: active ? "pawprint.fill" : "pawprint")
            .onReceive(Engine.shared.$isActive.removeDuplicates()) { value in
                if value != active { active = value }
            }
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--mcp") { MCPServer.run(); return }
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            MainActor.assumeIsolated { renderIcon(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--render-menuicon"), i + 1 < args.count {
            MainActor.assumeIsolated { renderMenuIcon(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            MainActor.assumeIsolated {
                _ = Engine.shared
                if let l = args.firstIndex(of: "--lang"), l + 1 < args.count { L10n.language = AppLanguage(rawValue: args[l + 1]) ?? .system }
                renderPreview(to: args[i + 1], settings: args.contains("--settings"))
            }
            return
        }
        if let i = args.firstIndex(of: "--simulate") {
            exit(MainActor.assumeIsolated { Simulation.main(Array(args[(i + 1)...])) })
        }
        AFKPugApp.main()
    }

    @MainActor
    static func renderIcon(to path: String) {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        write(renderer.nsImage, to: path)
    }

    /// Renders the popover to a PNG for design review.
    @MainActor
    static func renderPreview(to path: String, settings: Bool) {
        let engine = Engine.shared
        let view = RootView(engine: engine, page: settings ? .settings : .home).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        write(renderer.nsImage, to: path)
    }

    /// Both menu bar icon states, enlarged, on light and dark strips.
    @MainActor
    static func renderMenuIcon(to path: String) {
        let scale: CGFloat = 10
        let image = NSImage(size: NSSize(width: 22 * scale * 2 + 60, height: 18 * scale * 2 + 60), flipped: false) { rect in
            for (row, bg) in [NSColor.white, NSColor(white: 0.12, alpha: 1)].enumerated() {
                bg.setFill()
                NSRect(x: 0, y: CGFloat(row) * (rect.height / 2), width: rect.width, height: rect.height / 2).fill()
                for (col, active) in [false, true].enumerated() {
                    let icon = MenuIcon.make(active: active)
                    let tinted = NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r)
                        (row == 0 ? NSColor.black : NSColor.white).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: 20 + CGFloat(col) * (22 * scale + 20), y: CGFloat(row) * (rect.height / 2) + 10,
                                           width: 22 * scale, height: 18 * scale))
                }
            }
            return true
        }
        write(image, to: path)
    }

    private static func write(_ image: NSImage?, to path: String) {
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
