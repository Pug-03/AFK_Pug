import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Engine.shared.boot()
            if Engine.shared.showOnboarding { OnboardingWindow.shared.show() }
        }
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
        Image(nsImage: AppGlyph.menuImage(active: active))
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
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            MainActor.assumeIsolated {
                _ = Engine.shared
                if let l = args.firstIndex(of: "--lang"), l + 1 < args.count { L10n.language = AppLanguage(rawValue: args[l + 1]) ?? .system }
                renderPreview(to: args[i + 1], settings: args.contains("--settings"))
            }
            return
        }
        if let i = args.firstIndex(of: "--render-onboarding"), i + 1 < args.count {
            MainActor.assumeIsolated {
                _ = Engine.shared
                if let l = args.firstIndex(of: "--lang"), l + 1 < args.count { L10n.language = AppLanguage(rawValue: args[l + 1]) ?? .system }
                var step = OnboardingWindow.Step.welcome
                if let s = args.firstIndex(of: "--step"), s + 1 < args.count, let n = Int(args[s + 1]),
                   let parsed = OnboardingWindow.Step(rawValue: n - 1) { step = parsed }
                renderOnboarding(to: args[i + 1], step: step)
            }
            return
        }
        if let i = args.firstIndex(of: "--render-screen"), i + 2 < args.count {
            var language = AppLanguage.en
            if let l = args.firstIndex(of: "--lang"), l + 1 < args.count { language = AppLanguage(rawValue: args[l + 1]) ?? .en }
            exit(MainActor.assumeIsolated { Screens.render(args[i + 1], to: args[i + 2], language: language) })
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
        let view = RootView(engine: engine, page: settings ? .settings : .home, fitsWindow: false).environment(\.colorScheme, Theme.scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        write(renderer.nsImage, to: path)
    }

    /// Renders one onboarding step (--step 1...4) to a PNG for design review.
    @MainActor
    static func renderOnboarding(to path: String, step: OnboardingWindow.Step) {
        Engine.shared.refreshIntegrations()
        let view = OnboardingView(engine: Engine.shared, start: step).environment(\.colorScheme, Theme.scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        write(renderer.nsImage, to: path)
    }

    static func write(_ image: NSImage?, to path: String) {
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
