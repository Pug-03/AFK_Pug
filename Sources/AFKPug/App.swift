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

/// Menu bar icon and optional status. Re-renders only when one of them actually changes,
/// or a few times a second while the icon moves.
private struct MenuBarLabel: View {
    @State private var active = Engine.shared.isActive
    @State private var status = Engine.shared.menuBarText
    @State private var motion = Engine.shared.menuMotion
    @State private var frame: NSImage?

    /// Breathing: the crossbar fades between these over 2.4 s, 8 frames a second.
    private static let breath: [NSImage] = (0..<20).map { i in
        AppGlyph.menuImage(crossbar: 0.6 + 0.4 * cos(Double(i) / 20 * 2 * .pi))
    }
    private static let amber = AppGlyph.menuImage(crossbar: 1, tint: .systemOrange)

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: frame ?? AppGlyph.menuImage(active: active))
            if let status { Text(status).monospacedDigit() }
        }
        .onReceive(Engine.shared.$isActive.removeDuplicates()) { value in
            if value != active { active = value }
        }
        .onReceive(Engine.shared.$menuBarText.removeDuplicates()) { value in
            if value != status { status = value }
        }
        .onReceive(Engine.shared.$menuMotion.removeDuplicates()) { value in
            if value != motion { motion = value }
        }
        .task(id: motion) { await animate(motion) }
    }

    private func animate(_ motion: MenuMotion) async {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch motion {
        case .still:
            frame = nil
        case .working:
            if still { frame = nil; return }
            var i = 0
            while !Task.isCancelled {
                frame = Self.breath[i % Self.breath.count]; i += 1
                try? await Task.sleep(for: .milliseconds(120))
            }
        case .waiting:
            if still { frame = Self.amber; return }
            var on = true
            while !Task.isCancelled {
                frame = on ? Self.amber : AppGlyph.menuImage(active: true); on.toggle()
                try? await Task.sleep(for: .milliseconds(700))
            }
        case let .countdown(until, length):
            while !Task.isCancelled {
                let left = until.timeIntervalSince(Clock.now())
                frame = AppGlyph.menuImage(crossbar: 1, ring: left / length)
                if left <= 0 { return }
                // 120 steps around the ring, never faster than once a second.
                try? await Task.sleep(for: .seconds(max(1, length / 120)))
            }
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

    /// Renders one onboarding step (--step 1...10) to a PNG for design review.
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
