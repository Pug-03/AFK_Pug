import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.boot() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.shutdown() }
    }
}

struct AFKPugApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var engine = Engine.shared

    var body: some Scene {
        MenuBarExtra {
            RootView(engine: engine)
        } label: {
            Image(nsImage: MenuIcon.make(active: engine.isActive))
        }
        .menuBarExtraStyle(.window)
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
        let view = RootView(engine: engine, page: settings ? .settings : .home).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        write(renderer.nsImage, to: path)
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
