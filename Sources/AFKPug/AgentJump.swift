import AppKit

/// Where an agent's session runs, as its hook saw it. The values come from a file and end up
/// as arguments to other programs, so anything that isn't plainly what it should be is dropped.
struct AgentPlace: Equatable, Sendable {
    var bundle: String?
    var tty: String?
    var tmuxPane: String?
    var tmuxSocket: String?
    var root: String?

    init(bundle: String? = nil, tty: String? = nil, tmuxPane: String? = nil, tmuxSocket: String? = nil, root: String? = nil) {
        self.bundle = bundle
        self.tty = tty
        self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket
        self.root = root
    }

    init?(_ json: [String: Any]) {
        func valid(_ key: String, _ pattern: String) -> String? {
            guard let value = json[key] as? String, value.range(of: "^\(pattern)\\z", options: .regularExpression) != nil else { return nil }
            return value
        }
        bundle = valid("app", "[A-Za-z0-9][A-Za-z0-9.-]{0,99}")
        tty = valid("tty", "ttys[0-9]{1,5}")
        tmuxPane = valid("pane", "%[0-9]{1,6}")
        tmuxSocket = valid("socket", "/[A-Za-z0-9/._-]{1,200}")
        root = (json["root"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        guard bundle != nil || (tmuxPane != nil && tmuxSocket != nil) else { return nil }
    }
}

/// Brings an agent's session to the front when its row is clicked. It only ever shows what's
/// already running: it never launches an app, and only opens the folder the session is in.
enum AgentJump {
    enum Step: Equatable {
        case tmux(socket: String, pane: String)
        case terminalTab(tty: String)
        case itermSession(tty: String)
        case openFolder(bundle: String, path: String)
        case activate(bundle: String)
    }

    /// These open a folder in the window that already shows it. No way in to a terminal panel.
    /// The value is the editor's folder under Application Support.
    private static let editors: [String: String] = [
        "com.microsoft.VSCode": "Code", "com.microsoft.VSCodeInsiders": "Code - Insiders", "com.vscodium": "VSCodium",
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.exafunction.windsurf": "Windsurf",
    ]

    /// The folders an editor has open. Its own state file, so this can stop working with an
    /// update; the click then only brings the app forward.
    private static func openFolders(_ editor: String) -> [String] {
        if Sim.enabled { return Sim.value("open-folders")?.split(separator: "\n").map(String.init) ?? [] }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(editor)/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = json["windowsState"] as? [String: Any] else { return [] }
        let windows = (state["openedWindows"] as? [[String: Any]] ?? []) + [state["lastActiveWindow"] as? [String: Any] ?? [:]]
        return windows.compactMap { window in
            guard let text = window["folder"] as? String, let url = URL(string: text), url.isFileURL else { return nil }
            return url.path
        }
    }

    /// The open folder holding `root`, the deepest if they nest. Asking an editor for a folder
    /// it doesn't have open would open a new window, so without a match there's no folder.
    static func window(for root: String, in folders: [String]) -> String? {
        folders.filter { root == $0 || root.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
    }

    static func steps(for place: AgentPlace) -> [Step] {
        var steps: [Step] = []
        if let socket = place.tmuxSocket, let pane = place.tmuxPane { steps.append(.tmux(socket: socket, pane: pane)) }
        guard let bundle = place.bundle else { return steps }
        if bundle == "com.apple.Terminal", let tty = place.tty {
            steps.append(.terminalTab(tty: tty))
        } else if bundle == "com.googlecode.iterm2", let tty = place.tty {
            steps.append(.itermSession(tty: tty))
        } else if let editor = editors[bundle], let root = place.root, let folder = window(for: root, in: openFolders(editor)) {
            steps.append(.openFolder(bundle: bundle, path: folder))
        } else {
            steps.append(.activate(bundle: bundle))
        }
        return steps
    }

    static func go(_ place: AgentPlace) {
        let steps = steps(for: place)
        if Sim.enabled {
            Sim.record("jump: \(steps)")
            return
        }
        // An editor that's already active won't change Space for its other windows. Being active
        // ourselves first makes the click count as a switch, whichever Space the window is on.
        if steps.contains(where: { if case .openFolder = $0 { return true } else { return false } }) {
            NSApp.activate(ignoringOtherApps: true)
        }
        // osascript waits for as long as the Automation question stays on screen.
        DispatchQueue.global(qos: .userInitiated).async {
            for step in steps { perform(step, bundle: place.bundle) }
        }
    }

    private static func perform(_ step: Step, bundle: String?) {
        switch step {
        case let .tmux(socket, pane):
            guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first(where: FileManager.default.isExecutableFile) else { return }
            _ = run(tmux, ["-S", socket, "select-window", "-t", pane])
            _ = run(tmux, ["-S", socket, "select-pane", "-t", pane])
        case let .terminalTab(tty):
            selectTab(terminalScript, tty: tty, bundle: bundle)
        case let .itermSession(tty):
            selectTab(itermScript, tty: tty, bundle: bundle)
        case let .openFolder(bundle, path):
            guard let app = running(bundle)?.bundleURL else { return }
            NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case let .activate(bundle):
            activate(bundle)
        }
    }

    /// The app comes forward first, so a click always shows something, even with the Automation
    /// question unanswered or refused. Telling an app that isn't running would launch it.
    private static func selectTab(_ script: String, tty: String, bundle: String?) {
        guard let bundle, running(bundle) != nil else { return }
        activate(bundle)
        _ = run("/usr/bin/osascript", ["-e", script, tty], timeout: 60)
    }

    private static func running(_ bundle: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    private static func activate(_ bundle: String) {
        guard let app = running(bundle)?.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let stop = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        process.waitUntilExit()
        stop.cancel()
        return process.terminationStatus == 0
    }

    // The terminal comes in as an argument, never as part of the script's text.
    static let terminalScript = """
    on run argv
      set target to "/dev/" & item 1 of argv
      tell application "Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is target then
              set miniaturized of w to false
              set selected tab of w to t
              set index of w to 1
              activate
              return
            end if
          end repeat
        end repeat
      end tell
      error "No such terminal"
    end run
    """

    static let itermScript = """
    on run argv
      set target to "/dev/" & item 1 of argv
      tell application "iTerm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if tty of s is target then
                select w
                tell t to select
                tell s to select
                activate
                return
              end if
            end repeat
          end repeat
        end repeat
      end tell
      error "No such terminal"
    end run
    """
}
