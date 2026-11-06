import SwiftUI
import AppKit

/// First-run welcome, shown in its own window (the app has no Dock icon or
/// main window). Opened on first launch, from Settings → General and from the
/// home screen's "Connect your agents" hint.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    enum Step: Int, CaseIterable { case welcome, lid, agents, finish }

    /// Opens the welcome at `step`. If it's already open, it only comes to the
    /// front: the step the user is on is kept.
    func show(step: Step = .welcome) {
        let engine = Engine.shared
        engine.refreshIntegrations()
        if let window, window.isVisible {
            present(window)
            return
        }
        let root = OnboardingView(engine: engine, start: step, close: { [weak self] in self?.close() })
            .id(UUID()) // fresh step state each time it opens
        if let window {
            (window.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(root)
            present(window)
            return
        }
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = tr("Welcome to AFK Pug")
        window.isMovableByWindowBackground = true
        applyTheme(to: window)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        // Opens on the Space the user is on, not the one where it was first shown.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.center()
        self.window = window
        present(window)
    }

    func applyTheme() {
        if let window { applyTheme(to: window) }
    }

    private func applyTheme(to window: NSWindow) {
        window.appearance = NSAppearance(named: Theme.palette.isDark ? .darkAqua : .aqua)
        window.backgroundColor = NSColor(Theme.bg)
    }

    /// An LSUIElement app isn't active on its own, and `activate()` is only a
    /// request: order the window front regardless, and once more on the next
    /// run loop pass in case activation landed late (e.g. right after launch).
    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            guard window.isVisible else { return }
            if !NSApp.isActive { NSApp.activate() }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() { window?.close() }

    /// Closing the window any way (Done, Skip, Esc, the close button) counts as seen.
    func windowWillClose(_ notification: Notification) {
        if Engine.shared.showOnboarding { Engine.shared.finishOnboarding() }
    }
}

struct OnboardingView: View {
    @ObservedObject var themeStore = ThemeStore.shared
    typealias Step = OnboardingWindow.Step

    @ObservedObject var engine: Engine
    var close: () -> Void
    @State private var step: Step
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width is fixed; the height is at least this and grows with the content
    /// (four agents with a note and an error in English don't fit in 500).
    static let size = CGSize(width: 460, height: 500)

    init(engine: Engine, start: Step = .welcome, close: @escaping () -> Void = {}) {
        self.engine = engine
        self.close = close
        _step = State(initialValue: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                // Esc skips the whole welcome; kept in place (invisible) on the last step.
                Button(tr("Skip"), action: finish)
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.sub)
                    .keyboardShortcut(.cancelAction)
                    .opacity(step == .finish ? 0 : 1)
                    .accessibilityHidden(step == .finish)
            }
            .frame(height: 20)

            AppMark(size: 48)
                .padding(.top, 6)
                .padding(.bottom, 24)

            ZStack(alignment: .topLeading) {
                page(step)
                    .id(step)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)
            footer.padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .frame(width: Self.size.width)
        .frame(minHeight: Self.size.height, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.accent)
        .onAppear { engine.refreshIntegrations() }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: welcome
        case .lid: lid
        case .agents: agents
        case .finish: finishPage
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("Meet AFK Pug"),
                    text: tr("Keeps your Mac awake with the lid closed while your AI agents work, then lets it sleep when they're done."))
            MenuBarHint().padding(.top, 26)
            Text(tr("Find the A icon in the menu bar, at the top right of your screen."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private var lid: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("Allow lid-closed mode"),
                    text: tr("So work keeps running when you close the lid. macOS asks for your password once."))
            Card {
                Row(symbol: "laptopcomputer", title: tr("Lid-closed mode"), detail: lidDetail) {
                    if engine.setupDone {
                        DoneMark()
                    } else if engine.setupWorking {
                        PillButton(title: tr("Working…"), style: .soft,
                                   reserve: [tr("Allow"), tr("Try again"), tr("Working…")]) {}.disabled(true)
                    } else {
                        // Return allows (the footer's Continue takes it once this is done).
                        PillButton(title: engine.setupError == nil ? tr("Allow") : tr("Try again"), style: .primary,
                                   reserve: [tr("Allow"), tr("Try again"), tr("Working…")]) {
                            engine.runSetup()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                if let error = engine.setupError { ErrorText(error).padding(.leading, 30) }
            }
            .padding(.top, 22)
            Text(tr("Only allows turning lid sleep on and off. You can remove it in Settings."))
                .font(.system(size: 11)).foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private var lidDetail: String {
        if engine.setupDone { return tr("Ready") }
        if engine.setupWorking { return tr("Waiting for your password…") }
        return tr("Needs a one-time permission")
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("Connect your agents"),
                    text: tr("AFK Pug adds a small hook so it knows when an agent starts and finishes."))
            Card {
                ForEach(AgentIntegrations.all) { item in
                    AgentConnectionRow(engine: engine, item: item, allowDisconnect: false)
                }
            }
            .padding(.top, 22)
            Text(tr("Other agents are detected while they run. Change this any time in Settings."))
                .font(.system(size: 11)).foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("You're all set"),
                    text: tr("Turn on Agent mode, close the lid and walk away. AFK Pug keeps watch."))
            Card {
                ToggleRow(symbol: "sparkles", title: tr("Agent mode"),
                          detail: tr("Awake only while your AI agents work"), isOn: $engine.agentMode)
                Row(symbol: "power", title: tr("Open at login"), detail: loginDetail) {
                    Toggle(tr("Open at login"), isOn: Binding(get: { engine.launchAtLogin == .on },
                                                               set: { engine.setLaunchAtLogin($0) }))
                        .toggleStyle(MiniSwitch()).labelsHidden()
                }
                if let error = engine.loginError { ErrorText(error).padding(.leading, 30) }
            }
            .padding(.top, 22)
        }
    }

    private var loginDetail: String {
        switch engine.launchAtLogin {
        case .on: return tr("Agent mode keeps working after a restart")
        case .off: return tr("Off: after a restart, open AFK Pug yourself")
        case .needsApproval: return tr("Allow it in System Settings → General → Login Items")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s == step ? Theme.text : Theme.ink.opacity(0.18))
                        .frame(width: s == step ? 14 : 5, height: 5)
                }
            }
            .animation(Theme.fade, value: step)
            .accessibilityElement()
            .accessibilityLabel(tr("Step %d of %d", step.rawValue + 1, Step.allCases.count))
            Spacer()
            if step != .welcome {
                PillButton(title: tr("Back"), style: .quiet) { go(step.rawValue - 1) }
            }
            PillButton(title: step == .finish ? tr("Done") : tr("Continue"), style: stepDone ? .primary : .soft) {
                step == .finish ? finish() : go(step.rawValue + 1)
            }
            // On the lid step Return belongs to Allow until the permission is set up.
            .keyboardShortcut(returnAllows ? nil : .defaultAction)
        }
    }

    private var returnAllows: Bool { step == .lid && !engine.setupDone && !engine.setupWorking }

    /// The step's own action is done (or there is none), so Continue is the main button.
    private var stepDone: Bool {
        switch step {
        case .lid: return engine.setupDone
        case .agents: return engine.connected.values.contains(true)
        default: return true
        }
    }

    private func go(_ raw: Int) {
        guard let target = Step(rawValue: raw) else { return }
        if target == .agents { engine.refreshIntegrations() }
        withAnimation(reduceMotion ? nil : Theme.fade) { step = target }
    }

    private func finish() {
        engine.finishOnboarding()
        close()
    }
}

// MARK: - Pieces

private struct Heading: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.sub)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Card<Content: View>: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(radius: 12)
    }
}

/// Green check + "Connected"/"Done" style label used instead of a button once done.
struct DoneMark: View {
    @ObservedObject var themeStore = ThemeStore.shared
    var title: String = tr("Done")

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(Theme.live)
        .lineLimit(1)
        .fixedSize()
    }
}

/// A sketch of the right end of the menu bar with the icon picked out.
private struct MenuBarHint: View {
    @ObservedObject var themeStore = ThemeStore.shared
    var body: some View {
        HStack(spacing: 16) {
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            GlyphView(size: 16, color: Theme.text)
                .frame(width: 30, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.ink.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.accent.opacity(0.9), lineWidth: 1.2))
            Image(systemName: "magnifyingglass")
            Text(Date.now.formatted(date: .omitted, time: .shortened)).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.faint)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .cardBackground(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
