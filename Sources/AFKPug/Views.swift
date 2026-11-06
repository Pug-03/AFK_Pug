import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine
    @State var page: Page = .home
    @State private var homeHeight: CGFloat = 520
    /// What the window should be; follows the content on the same curve. 0 until first measured.
    @State private var windowHeight: CGFloat = 0
    @State private var measured: Measured?
    /// Off for PNG previews: ImageRenderer can't draw an NSView and shows a placeholder.
    var fitsWindow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Page { case home, settings }

    private struct Measured: Equatable {
        let height: CGFloat
        let holdIDs: [String]
        let page: Page
    }

    /// The window is exactly the content: home sizes itself and settings takes
    /// the same height, so changing page never resizes the window mid-slide. The
    /// dark background fills the whole window, safe areas included.
    var body: some View {
        WindowHeightLayout(height: windowHeight) {
            ZStack(alignment: .top) {
                if page == .home {
                    HomeView(engine: engine, openSettings: { go(.settings) })
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { homeHeight = $0 }
                        .transition(slide(from: .leading))
                } else {
                    SettingsView(engine: engine, back: { go(.home) })
                        .frame(height: homeHeight)
                        .transition(slide(from: .trailing))
                }
            }
            .frame(width: 340, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .animation(listAnimation, value: holdIDs)
            .onGeometryChange(for: Measured.self, of: { Measured(height: $0.size.height, holdIDs: holdIDs, page: page) }) { new in
                guard fitsWindow else { return }
                // Only the agent list and the page slide animate their content; anything else
                // appears at once and the window must not lag behind it. Opening neither.
                let animate = measured.map { $0.holdIDs != new.holdIDs || $0.page != new.page } ?? false
                measured = new
                var transaction = Transaction(animation: animate ? listAnimation : nil)
                transaction.disablesAnimations = !animate
                withTransaction(transaction) { windowHeight = new.height }
            }
        }
        .background { if fitsWindow { WindowHeightFitter() } }
        .background(Theme.bg.ignoresSafeArea())
        .modifier(WindowBackground())
        .foregroundStyle(Theme.text)
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.accent)
    }

    /// Agent rows coming and going: the rows below slide and the window follows.
    private var listAnimation: Animation? { reduceMotion ? nil : Theme.smooth }
    /// Everything that changes the list's height, and nothing else: new steps keep it still.
    private var holdIDs: [String] {
        engine.holds.map { "\($0.id)|\($0.task?.title != nil)|\($0.isHookHold)" } + engine.finished.prefix(3).map(\.id.uuidString)
    }

    private func go(_ target: Page) {
        withAnimation(reduceMotion ? Theme.fade : Theme.smooth) { page = target }
    }

    private func slide(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

/// Reports `height` as the root's size and interpolates it, so a change reaches the
/// window frame by frame. The hosting view centres the root in the window and sizes the
/// window up to it, so the root must always be exactly as tall as the window.
private struct WindowHeightLayout: Layout, Animatable {
    /// 0: not measured yet, use the content's own height.
    var height: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        // Whole points: the hosting view rounds its minimum up, and would then resize the
        // window itself if the root were a fraction taller than the window.
        return CGSize(width: content.width, height: (height > 0 ? height : content.height).rounded())
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

/// A MenuBarExtra window grows with its content but never shrinks. This keeps it at the
/// root's height as that animates, and its top where it is: the content must not move.
private struct WindowHeightFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private var moveObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
            moveObserver = window.map { window in
                // SwiftUI also re-anchors the window on its own (reactivation).
                NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                    self?.fit()
                }
            }
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        /// Called mid-layout, on purpose: a resize made later shows one frame of the root
        /// centred in the old window, and SwiftUI would grow the window first.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fit()
        }

        private func fit() {
            let height = bounds.height
            guard let window, height > 0 else { return }
            var frame = window.frame
            // MenuBarExtraWindow hangs the window from the status item, which can sit
            // above the screen when the menu bar hides.
            var top = frame.maxY
            if let limit = window.screen?.visibleFrame.maxY, top > limit { top = limit - 2 }
            guard abs(frame.height - height) > 0.25 || abs(frame.maxY - top) > 0.25 else { return }
            frame.size.height = height
            frame.origin.y = top - height
            // NSWindow's own setFrame: MenuBarExtraWindow overrides it to replace the origin,
            // and correcting that afterwards would show the window moving.
            let selector = #selector(NSWindow.setFrame(_:display:))
            typealias SetFrame = @convention(c) (NSWindow, Selector, NSRect, Bool) -> Void
            unsafeBitCast(class_getMethodImplementation(NSWindow.self, selector), to: SetFrame.self)(window, selector, frame, false)
        }
    }
}

/// Paints the MenuBarExtra window itself dark on macOS 15+, so no lighter
/// window material shows around the content.
private struct WindowBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(Theme.bg, for: .window)
        } else {
            content
        }
    }
}

// MARK: - Home

/// No container-level implicit animations here: RootView animates layout only when the
/// agent list changes, and the window follows. Anything else must not animate its height.
struct HomeView: View {
    @ObservedObject var engine: Engine
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(engine: engine, openSettings: openSettings)
            TimerBlock(engine: engine)
            Durations(engine: engine)
            MainAction(engine: engine)
            if let summary = engine.summary {
                SummaryCard(summary: summary) { engine.summary = nil }
            }
            if let update = engine.update {
                UpdateCard(update: update, engine: engine)
            }
            Modes(engine: engine)
            StatusBar(engine: engine)
        }
        .padding(18)
    }
}

private struct Header: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppMark()
            VStack(alignment: .leading, spacing: 2) {
                Text("AFK Pug").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    LiveDot(color: dotColor)
                    Text(engine.headline)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(Theme.fade, value: engine.headline)
                }
            }
            Spacer(minLength: 8)
            IconButton(symbol: "gearshape", label: tr("Settings"), action: openSettings)
        }
    }

    /// Every hold is an agent paused on its usage limit: nothing is working right now.
    private var allWaiting: Bool {
        engine.trip == nil && !engine.manualOn && !engine.holds.isEmpty && engine.waitingAgents == engine.holds.count
    }

    private var dotColor: Color {
        if engine.trip != nil { return Theme.warn }
        if allWaiting { return Theme.wait }
        return engine.isActive ? Theme.live : Theme.faint
    }
}

/// Static status dot. Color changes crossfade; nothing loops.
struct LiveDot: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .animation(Theme.fade, value: color)
    }
}

// MARK: Timer

private struct TimerBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine

    /// What the big text shows outside a guard trip.
    private enum Mode { case manual, grace, working, awake, trip, idle }

    private var mode: Mode {
        if engine.trip != nil { return .trip }
        if engine.manualOn { return .manual }
        if !engine.holds.isEmpty { return .working }
        if engine.graceActive { return .grace }
        // Only a real trigger shows "Awake"; the tick right after grace ends must not flash it.
        if engine.isActive, engine.triggerReason != nil { return .awake }
        return .idle
    }

    /// A seconds display redraws from the end date once per second while a
    /// countdown is visible. The timeline is paused otherwise, and stops with the window.
    private var counting: Bool {
        switch mode {
        case .manual: return engine.manualEnd != nil
        case .grace: return true
        default: return false
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !counting)) { _ in
            // Clock.now() is the timeline date in the app, and the shifted clock in the simulator.
            let date = Clock.now()
            let mode = mode
            let big = bigText(mode, at: date)
            VStack(alignment: .leading, spacing: 8) {
                Text(big)
                    .font(.system(size: 46, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(mode == .idle ? Theme.faint : (mode == .trip ? Theme.warn : Theme.text))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // Digits roll as they change. The font is monospaced and the height
                    // fixed, so this can't resize the window. A new identity for each
                    // mode swaps the text cleanly, so "1 agent" never morphs into "30:00".
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : Theme.fade, value: big)
                    .id(String(describing: mode))
                Text(subline(mode, at: date))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Only while counting down; an empty track at rest looked like a stopped timer.
                GeometryReader { geo in
                    Capsule().fill(Theme.line)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.text)
                                .frame(width: geo.size.width * progress(mode, at: date))
                        }
                }
                .frame(height: 2)
                .padding(.top, 4)
                .opacity(counting ? 1 : 0)
            }
        }
    }

    private func bigText(_ mode: Mode, at date: Date) -> String {
        switch mode {
        case .manual:
            guard let end = engine.manualEnd else { return "∞" }
            return Fmt.clock(max(0, end.timeIntervalSince(date)))
        case .grace:
            return Fmt.clock(max(0, (engine.graceUntil ?? date).timeIntervalSince(date)))
        case .working:
            return engine.holds.count == 1 ? tr("1 agent") : tr("%d agents", engine.holds.count)
        case .awake:
            return tr("Awake")
        case .trip:
            if case .battery(let p) = engine.trip { return "\(p)%" }
            return tr("Too hot")
        case .idle:
            let m = engine.selectedMinutes
            return m > 0 ? Fmt.clock(TimeInterval(m * 60)) : "∞"
        }
    }

    private func subline(_ mode: Mode, at date: Date) -> String {
        switch mode {
        case .manual:
            if let end = engine.manualEnd { return tr("until %@", Fmt.time(end)) }
        case .trip:
            switch engine.trip {
            case .thermal:
                if let left = engine.thermalCooldownRemaining {
                    return tr("Cooling down. You can start again in about %@", Fmt.aboutMinutes(left))
                }
            case .battery:
                // The engine's line says where it stopped and to plug in; once the
                // charger is in, the trip still waits for steady power.
                if !engine.batteryTripNeedsCharger { return tr("Charging. You can start again in a moment") }
            case nil:
                break
            }
        case .grace:
            // A duration with units: "14:38" here once read as a clock time.
            return tr(engine.keepingScreenOn ? "Screen on. Sleeping in %@" : "Sleeping in %@", Fmt.countdown((engine.graceUntil ?? date).timeIntervalSince(date)))
        case .idle:
            let m = engine.selectedMinutes
            return m > 0 ? tr("Press Go AFK to stay awake for %@", Fmt.minutes(m)) : tr("Press Go AFK to stay awake until you stop")
        default:
            break
        }
        return engine.subline
    }

    private func progress(_ mode: Mode, at date: Date) -> CGFloat {
        switch mode {
        case .manual:
            guard let start = engine.manualStart, let end = engine.manualEnd else { return 0 }
            let total = end.timeIntervalSince(start)
            guard total > 0 else { return 0 }
            return CGFloat(max(0, min(1, end.timeIntervalSince(date) / total)))
        case .grace:
            let total = max(60, engine.graceLength)
            return CGFloat(max(0, min(1, (engine.graceUntil ?? date).timeIntervalSince(date) / total)))
        default:
            return 0
        }
    }
}

// MARK: Durations

private struct Durations: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let choices = [30, 60, 120, 240, 480, 0]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.self) { m in
                Segment(title: Fmt.minutes(m), spoken: m == 0 ? tr("Until you stop") : Fmt.minutes(m),
                        selected: engine.selectedMinutes == m, ns: ns) {
                    guard engine.selectedMinutes != m else { return }
                    Haptics.tap()
                    if reduceMotion { engine.choose(minutes: m) } else { withAnimation(Theme.smooth) { engine.choose(minutes: m) } }
                }
            }
        }
        .padding(3)
        .cardBackground(radius: 11)
        // Agents, grace or a trigger are in charge: picking a time would do nothing visible.
        .opacity(!engine.manualOn && engine.isActive ? 0.45 : 1)
        .help(engine.manualOn ? tr("Picking a time restarts the countdown") : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Duration"))
    }

    private struct Segment: View {
        @ObservedObject var themeStore = ThemeStore.shared
        let title: String
        let spoken: String
        let selected: Bool
        let ns: Namespace.ID
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || hover ? Theme.text : Theme.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.ink.opacity(0.1))
                                .matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(Theme.hover, value: hover)
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

// MARK: Main action

private struct MainAction: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 8) {
            if engine.manualOn {
                ActionButton(title: tr("Stop"), style: .outline) { engine.stop() }
                if engine.manualEnd != nil {
                    ActionButton(title: tr("+30m"), style: .quiet) { engine.addTime(minutes: 30) }
                        .frame(width: 104)
                }
            } else {
                // During a guard trip the button says why it's off, not just a tooltip.
                ActionButton(title: engine.trip == nil ? tr("Go AFK") : tripHelp, style: .solid) { engine.start() }
                    .disabled(engine.trip != nil)
                    .keyboardShortcut(.defaultAction)
                if engine.canSleepNow, engine.trip == nil {
                    ActionButton(title: tr("Allow sleep"), style: .outline) { engine.sleepNow() }
                        .frame(width: 118)
                        .help(tr("Stop keeping the Mac awake. It sleeps when macOS decides; music or the charger won't keep it awake until they stop and start again"))
                }
            }
        }
        .frame(height: 40)
        .animation(Theme.fade, value: engine.manualOn)
    }

    private var tripHelp: String {
        switch engine.trip {
        case .battery: return engine.batteryTripNeedsCharger ? tr("Plug in the charger to keep going") : tr("Charging…")
        case .thermal: return tr("Waiting for the Mac to cool down")
        case nil: return ""
        }
    }
}

private struct ActionButton: View {
    @ObservedObject var themeStore = ThemeStore.shared
    enum Style { case solid, outline, quiet }
    let title: String
    var style: Style
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundStyle(style == .solid ? Theme.onInk : Theme.text)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(style == .outline ? Theme.ink.opacity(lit ? 0.35 : 0.2) : .clear, lineWidth: 1)
                )
                .opacity(enabled ? 1 : 0.35)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(Theme.hover, value: hover)
    }

    private var lit: Bool { hover && enabled }

    private var fill: Color {
        switch style {
        case .solid: return Theme.ink.opacity(lit ? 1 : 0.92)
        case .outline: return lit ? Theme.surface : .clear
        case .quiet: return lit ? Theme.surfaceHover : Theme.surface
        }
    }
}

/// Small custom switch that matches the dark theme. Only the knob animates;
/// the toggle does not open an animation transaction, so rows that appear or
/// disappear because of it don't animate the window height.
struct MiniSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration)
    }

    private struct Switch: View {
        @ObservedObject var themeStore = ThemeStore.shared
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let on = configuration.isOn
            Button {
                Haptics.tap()
                configuration.isOn.toggle()
            } label: {
                Capsule()
                    .fill(on ? Theme.accent : Theme.trackOff)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(on ? Theme.onAccent : Theme.knobOff)
                            .frame(width: 14, height: 14)
                            .padding(2)
                    }
                    .animation(.smooth(duration: 0.2), value: on)
                    .opacity(enabled ? 1 : 0.4)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: Modes

private struct Modes: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine
    @State private var showAllAgents = false

    var body: some View {
        VStack(spacing: 0) {
            ModeRow(symbol: "sparkles", title: tr("Agent mode"), detail: agentDetail) {
                Toggle(tr("Agent mode"), isOn: $engine.agentMode).toggleStyle(MiniSwitch()).labelsHidden()
            }
            if engine.agentMode, !engine.holds.isEmpty {
                // 3 rows by default so the window doesn't keep growing; "+N more" shows the rest.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(showAllAgents ? engine.holds : Array(engine.holds.prefix(3))) { hold in
                        AgentRow(hold: hold) { engine.release(hold) }
                            .transition(.opacity.animation(Theme.hover))
                    }
                    if engine.holds.count > 3 {
                        MoreButton(title: showAllAgents ? tr("Show less") : tr("+%d more", engine.holds.count - 3)) {
                            showAllAgents.toggle()
                        }
                        .padding(.leading, 14)
                    }
                }
                .padding(.leading, 30).padding(.bottom, 8)
            }
            if engine.agentMode, !engine.finished.isEmpty {
                FinishedList(engine: engine)
                    .padding(.leading, 30).padding(.bottom, 8)
            }
            if engine.agentMode, needsAgents {
                HStack(spacing: 8) {
                    Text(tr("Connect your agents to detect work automatically."))
                        .font(.system(size: 11)).foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PillButton(title: tr("Connect"), style: .soft) { OnboardingWindow.shared.show(step: .agents) }
                }
                .padding(.leading, 30).padding(.bottom, 10)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            ModeRow(symbol: "sun.max", title: tr("Keep the screen on"), detail: tr("On the charger, lid open")) {
                KeepScreenPicker(engine: engine)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            ModeRow(symbol: "laptopcomputer", title: tr("Lid-closed mode"),
                    detail: engine.setupDone ? tr("Screen off, work keeps running") : tr("Needs a one-time permission")) {
                Toggle(tr("Lid-closed mode"), isOn: $engine.lidMode).toggleStyle(MiniSwitch()).labelsHidden()
            }
            if engine.lidMode, !engine.setupDone {
                HStack(spacing: 8) {
                    Text(tr("Asks for your password once. Only allows turning lid sleep on and off."))
                        .font(.system(size: 11)).foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    let titles = [tr("Set up"), tr("Try again"), tr("Working…")]
                    if engine.setupWorking {
                        PillButton(title: tr("Working…"), style: .soft, reserve: titles) {}.disabled(true)
                    } else {
                        PillButton(title: engine.setupError == nil ? tr("Set up") : tr("Try again"), style: .primary, reserve: titles) {
                            engine.runSetup()
                        }
                    }
                }
                .padding(.leading, 30).padding(.bottom, 10)
            }
            // Only relevant while lid-closed mode is on.
            if engine.lidMode, let error = engine.setupError {
                ErrorText(error).padding(.leading, 30).padding(.bottom, 10)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            ModeRow(symbol: "music.note", title: tr("Keep music playing"), detail: musicDetail) {
                Toggle(tr("Keep music playing"), isOn: $engine.keepMusic).toggleStyle(MiniSwitch()).labelsHidden()
            }
        }
    }

    /// No agent is connected, but at least one is installed and could be.
    private var needsAgents: Bool {
        guard !engine.connected.values.contains(true) else { return false }
        return AgentIntegrations.all.contains { $0.isAvailable() }
    }

    private var agentDetail: String {
        if engine.agentMode, engine.holds.isEmpty {
            return engine.graceActive ? tr("Waiting in case more work comes") : tr("No agents working right now")
        }
        return tr("Awake only while your AI agents work")
    }

    private var musicDetail: String {
        if engine.keepMusic, engine.musicPlaying, !engine.musicApps.isEmpty {
            return tr("Playing: %@", engine.musicApps.prefix(2).joined(separator: ", "))
        }
        return tr("Mac stays awake while audio plays")
    }
}

private struct ModeRow<Trailing: View>: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.sub)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                // One line, so a changing detail never resizes the window.
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.sub)
                    .lineLimit(1).truncationMode(.tail)
                    .help(detail)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 11)
    }
}

/// Inline warning under the control that failed.
struct ErrorText: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentRow: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let hold: AgentHold
    var release: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            nameLine
            if let title = hold.task?.title {
                Text(title)
                    .font(.system(size: 11)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 14)
                    .help(hold.task?.promptLine ?? title)
            }
            if hold.isHookHold, !hold.isUsageLimitWait {
                Text(hold.task?.waiting == true ? tr("Waiting for you") : (hold.task?.activity ?? tr("Starting")))
                    .font(.system(size: 10.5)).foregroundStyle(hold.task?.waiting == true ? Theme.waitText : Theme.sub)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 4)
    }

    private var nameLine: some View {
        HStack(spacing: 8) {
            // Amber: paused on its usage limit or waiting for you, held until it moves on.
            LiveDot(color: hold.isUsageLimitWait || hold.task?.waiting == true ? Theme.wait : Theme.live)
            Text(hold.displayName).font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            // Minute resolution, so a slow timeline is enough (and it only runs while visible).
            // The status keeps its width; a long name truncates instead.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(status)
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.sub)
                    .lineLimit(1)
                    .fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Button(action: release) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hover ? Theme.text : Theme.sub)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(hover ? Theme.surfaceHover : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(tr("Stop keeping awake for this one"))
            .accessibilityLabel(tr("Stop keeping awake for this one"))
        }
    }

    private var status: String {
        if hold.isUsageLimitWait {
            return hold.expires.map { tr("limit · until %@", Fmt.time($0)) } ?? tr("waiting for limit")
        }
        if let end = hold.expires { return tr("until %@", Fmt.time(end)) }
        let elapsed = Clock.now().timeIntervalSince(hold.started)
        return elapsed < 60 ? tr("just started") : tr("working for %@", Fmt.compact(elapsed))
    }
}

/// Turns that ended: which job, and when. Three by default, the rest behind "+N more".
private struct FinishedList: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(tr("Just finished")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.sub)
                Spacer()
                Button(tr("Clear")) { engine.clearFinished() }
                    .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Theme.sub)
            }
            ForEach(showAll ? engine.finished : Array(engine.finished.prefix(3))) { item in
                FinishedRow(item: item) { engine.dismissFinished(item) }
                    .transition(.opacity.animation(Theme.hover))
            }
            if engine.finished.count > 3 {
                MoreButton(title: showAll ? tr("Show less") : tr("+%d more", engine.finished.count - 3)) { showAll.toggle() }
                    .padding(.leading, 14)
            }
        }
    }
}

struct FinishedRow: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let item: FinishedTask
    var dismiss: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: item.failed ? "exclamationmark.triangle.fill" : "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(item.failed ? Theme.warn : Theme.live)
                .frame(width: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.task?.title ?? AgentIntegrations.displayName(item.agent))
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    .help(item.task?.promptLine ?? AgentIntegrations.displayName(item.agent))
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.sub).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hover ? Theme.text : Theme.sub)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(hover ? Theme.surfaceHover : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(tr("Remove from the list"))
            .accessibilityLabel(tr("Remove from the list"))
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let elapsed = Clock.now().timeIntervalSince(item.at)
        let when = elapsed < 60 ? tr("just now") : tr("%@ ago", Fmt.compact(elapsed))
        let name = AgentIntegrations.displayName(item.agent)
        return (item.failed ? tr("%@ stopped with an error", name) : name) + " · " + when
    }
}

/// How long the screen stays on for agents. A PNG preview can't draw the menu's NSView.
struct KeepScreenPicker: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine

    private var options: [(minutes: Int, title: String)] {
        [(-1, tr("Off")), (0, tr("While they work")), (30, tr("30 min after")), (60, tr("1 hour after"))]
    }

    var body: some View {
        if Sim.enabled {
            Text(options.first { $0.minutes == engine.keepScreenMinutes }?.title ?? tr("Off"))
                .font(.system(size: 11.5)).foregroundStyle(Theme.sub)
        } else {
            Picker(tr("Keep the screen on"), selection: $engine.keepScreenMinutes) {
                ForEach(options, id: \.minutes) { Text($0.title).tag($0.minutes) }
            }
            .labelsHidden().frame(width: 132)
        }
    }
}

/// "+2 more" under the agent list: shows the hidden rows so they can be seen and released.
private struct MoreButton: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(hover ? Theme.text : Theme.sub)
                .underline(hover)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: Status bar

private struct StatusBar: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine
    @State private var quitHover = false

    var body: some View {
        HStack(spacing: 10) {
            if engine.battery.hasBattery {
                item(batterySymbol, "\(engine.battery.percent)%",
                     warn: engine.battery.percent <= engine.batteryFloor && !engine.battery.onAC)
                    .fixedSize()
            }
            if case .thermal = engine.trip {
                // Never "Cool" next to a big "Too hot": show how long the cooldown has left.
                item("thermometer.high", engine.thermalCooldownRemaining.map { tr("Cooling · %@", Fmt.aboutMinutes($0, short: true)) } ?? tr("Too hot"),
                     warn: true)
                    .fixedSize()
            } else {
                item("thermometer.medium", engine.thermal.label, warn: engine.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
                    .fixedSize()
            }
            // Every label fits at full length in both languages (checked with the
            // longest heat label); a flexible one was cut short with room to spare.
            item("laptopcomputer", engine.lidOverrideOn ? tr("Lid: keeps running") : tr("Lid: sleeps"), warn: false)
                .fixedSize()
            Spacer(minLength: 4)
            Button { NSApp.terminate(nil) } label: {
                Text(tr("Quit")).lineLimit(1).fixedSize()
            }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(quitHover ? Theme.text : Theme.sub)
                .onHover { quitHover = $0 }
        }
        .padding(.top, 2)
    }

    private var batterySymbol: String {
        if engine.battery.onAC { return "battery.100percent.bolt" }
        switch engine.battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func item(_ symbol: String, _ text: String, warn: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5))
            Text(text).font(.system(size: 11).monospacedDigit()).lineLimit(1)
        }
        .foregroundStyle(warn ? Theme.warn : Theme.sub)
    }
}

// MARK: Summary

private struct UpdateCard: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let update: AvailableUpdate
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").font(.system(size: 13)).foregroundStyle(Theme.accent).accessibilityHidden(true)
                Text(tr("AFK Pug %@ is available", update.version)).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                let titles = [tr("Update"), tr("Working…")]
                PillButton(title: engine.updateWorking ? tr("Working…") : tr("Update"), style: engine.updateWorking ? .soft : .primary, reserve: titles) {
                    engine.installUpdate()
                }
                .disabled(engine.updateWorking)
                IconButton(symbol: "xmark", label: tr("Dismiss")) { engine.dismissUpdate() }
            }
            if let message = engine.updateMessage { ErrorText(message) }
        }
        .padding(12)
        .cardBackground(radius: 12)
    }
}

private struct SummaryCard: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let summary: LidSummary
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("While you were away")).font(.system(size: 12, weight: .semibold))
                Spacer()
                IconButton(symbol: "xmark", size: 22, label: tr("Close"), action: dismiss)
            }
            HStack(alignment: .top, spacing: 8) {
                Figure(value: Fmt.compact(summary.duration), label: tr("lid closed"))
                if summary.hadBattery {
                    Figure(value: "\(max(0, summary.startBattery - summary.endBattery))%", label: tr("battery used"))
                }
                Figure(value: "\(summary.agentsFinished)", label: tr("agent turns"))
                Figure(value: summary.peakThermal.label, label: tr("peak heat"))
            }
        }
        .padding(12)
        .cardBackground(radius: 12)
    }

    private struct Figure: View {
        @ObservedObject var themeStore = ThemeStore.shared
        let value: String
        let label: String
        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.system(size: 10)).foregroundStyle(Theme.sub)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Fmt {
    private static let thaiTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "th_TH")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HH:mm"
        return f
    }()

    /// A time of day for "until %@": 24-hour in Thai (never "5:48 PM น."), the system style otherwise.
    static func time(_ date: Date) -> String {
        L10n.isThai ? thaiTime.string(from: date) : date.formatted(date: .omitted, time: .shortened)
    }

    /// Compact elapsed time: "1h 25m" / "1 ชม. 25 น.", "2h" rather than "2h 0m".
    static func compact(_ t: TimeInterval) -> String {
        let m = Int(max(0, t) / 60)
        if m < 1 { return tr("under a minute") }
        if m < 60 { return tr("%dm", m) }
        return m % 60 == 0 ? tr("%dh", m / 60) : tr("%dh %dm", m / 60, m % 60)
    }

    /// A rough wait, rounded up to whole minutes: "4 min".
    static func aboutMinutes(_ t: TimeInterval, short: Bool = false) -> String {
        let m = max(1, Int((t / 60).rounded(.up)))
        return short && L10n.isThai ? tr("%d min·short", m) : tr("%d min", m)
    }
}
