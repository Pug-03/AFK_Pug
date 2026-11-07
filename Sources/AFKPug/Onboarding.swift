import SwiftUI
import AppKit

/// First-run welcome, shown in its own window (the app has no Dock icon or
/// main window). Opened on first launch, from Settings → General and from the
/// home screen's "Connect your agents" hint.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    /// Choose a language, set up the two things that need a yes, then one part of the app at a time.
    enum Step: Int, CaseIterable { case language, welcome, lid, agents, tourAgents, tourTimer, tourLid, tourScreen, tourLook, finish }

    /// Opens the welcome at `step`. If it's already open, it only comes to the
    /// front: the step the user is on is kept.
    func show(step: Step = .language) {
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
            refreshTitle()
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

    /// VoiceOver and Mission Control read the title, even though it's hidden.
    func refreshTitle() { window?.title = tr("Welcome to AFK Pug") }

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

    /// Growing keeps the top where it is, which can push a low window off the screen.
    func windowDidResize(_ notification: Notification) {
        guard let window, let visible = window.screen?.visibleFrame, window.frame.minY < visible.minY else { return }
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: min(visible.minY, visible.maxY - window.frame.height)))
    }

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

    init(engine: Engine, start: Step = .language, close: @escaping () -> Void = {}) {
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
        .onChange(of: engine.language) { OnboardingWindow.shared.refreshTitle() }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        switch step {
        case .language: languagePage
        case .welcome: welcome
        case .lid: lid
        case .agents: agents
        case .tourAgents: tourAgents
        case .tourTimer: tourTimer
        case .tourLid: tourLid
        case .tourScreen: tourScreen
        case .tourLook: tourLook
        case .finish: finishPage
        }
    }

    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // In both languages: nobody has chosen yet.
            Heading(title: tr("Welcome to AFK Pug"), text: "Choose your language · เลือกภาษาที่ต้องการ")
            VStack(spacing: 8) {
                LanguageChoice(title: "English", selected: !L10n.isThai) { engine.language = .en }
                LanguageChoice(title: "ไทย", selected: L10n.isThai) { engine.language = .th }
            }
            .padding(.top, 22)
        }
    }

    private var tourAgents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("See what each agent is doing"),
                    text: tr("Click the A to see each job and its current step, and click a job to go to its window. When a job ends, it moves to Just finished."))
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    AgentRow(hold: Self.sampleHold("claude", prompt: tr("Fix the failing payment tests"), cwd: "/billing-api",
                                                   tool: "Edit", target: "checkout.ts")) {}
                    AgentRow(hold: Self.sampleHold("codex", prompt: tr("Move the site to Astro"), cwd: "/website", waiting: true)) {}
                    Text(tr("Just finished")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.sub)
                    FinishedRow(item: FinishedTask(id: UUID(), agent: "gemini",
                                                   task: AgentTask(cwd: "/docs", prompt: tr("Update the README")),
                                                   at: Clock.now().addingTimeInterval(-300), failed: false)) {}
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
            .padding(.top, 22)
        }
    }

    private static func sampleHold(_ agent: String, prompt: String, cwd: String, tool: String? = nil, target: String? = nil, waiting: Bool = false) -> AgentHold {
        AgentHold(id: "\(agent)-sample", agent: agent, started: Clock.now().addingTimeInterval(-720), expires: nil, reason: nil,
                  task: AgentTask(cwd: cwd, prompt: prompt, tool: tool, target: target, waiting: waiting))
    }

    private var tourTimer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("Stay awake without an agent"),
                    text: tr("For a long download or a backup, click the A, pick a time and press Go AFK. ⌥⌘A starts or stops it from any app."))
            Card {
                Durations(engine: engine)
                ActionButton(title: tr("Go AFK"), style: .solid) {}
            }
            .allowsHitTesting(false)
            // A picture of the home screen. Durations is the real control: nothing here may reach it.
            .accessibilityHidden(true)
            .padding(.top, 22)
        }
    }

    private var tourLid: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("Close the lid and go"),
                    text: tr("Here's what happens while AFK Pug keeps your Mac awake. Sound comes back when you open the lid. Change any of this in Settings."))
            Card {
                Row(symbol: "display", title: tr("The screen turns off"), detail: tr("Saves battery while work keeps running")) { EmptyView() }
                Row(symbol: "speaker.slash", title: tr("Sound is muted"), detail: tr("Unless music is playing")) { EmptyView() }
                Row(symbol: "lock", title: tr("The Mac locks"), detail: tr("Nobody can use it while you're away")) { EmptyView() }
                Row(symbol: "battery.25percent", title: tr("AFK Pug stops when it has to"), detail: tr("At low battery or critical heat, the Mac sleeps")) { EmptyView() }
            }
            .padding(.top, 22)
        }
    }

    private var tourScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("Keep the screen on"),
                    text: tr("Leaving agents running? Choose how long the screen stays on, so you can check them at a glance."))
            Card {
                Row(symbol: "sun.max", title: tr("Keep the screen on"), detail: tr("On the charger, lid open")) {
                    KeepScreenPicker(engine: engine)
                }
            }
            .padding(.top, 22)
        }
    }

    private var tourLook: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: tr("Make it yours"),
                    text: tr("Pick a background and an accent color. Text stays readable on any choice."))
            Card { AppearanceRows() }
                .padding(.top, 22)
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
            Text(tr("Only allows turning lid sleep and Low Power Mode on and off. You can remove it in Settings."))
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
                    text: tr("AFK Pug adds a small hook so it can show what each agent is doing and when it finishes. This stays on your Mac."))
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
            if engine.setupDone {
                Heading(title: tr("You're all set"),
                        text: tr("Keep Agent mode on, close the lid and walk away. AFK Pug keeps watch."))
            } else {
                // Skipped the permission: closing the lid would still sleep the Mac.
                Heading(title: tr("Almost ready"),
                        text: tr("Lid-closed mode isn't allowed yet, so closing the lid still sleeps the Mac. Click the A and press Set up."))
            }
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
            if step != .language {
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

/// One language, as a large row with a check when chosen.
private struct LanguageChoice: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack {
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(hover || selected ? Theme.surfaceHover : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(selected ? Theme.text.opacity(0.7) : Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.hover, value: hover)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

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
        .foregroundStyle(Theme.liveText)
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
