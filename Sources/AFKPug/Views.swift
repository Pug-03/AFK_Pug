import SwiftUI

/// Dark, minimal palette and motion used across the popover.
enum Theme {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let surface = Color.white.opacity(0.045)
    static let surfaceHover = Color.white.opacity(0.08)
    static let line = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.94)
    static let sub = Color.white.opacity(0.50)
    static let faint = Color.white.opacity(0.42)
    static let accent = Color(red: 0.98, green: 0.63, blue: 0.35)
    static let live = Color(red: 0.40, green: 0.85, blue: 0.56)

    /// Page slide and segmented selection.
    static let smooth = Animation.smooth(duration: 0.3)
    /// Gentle crossfade for state changes (colors, text swaps).
    static let fade = Animation.easeInOut(duration: 0.2)
    /// Hover feedback.
    static let hover = Animation.easeOut(duration: 0.12)
}

struct RootView: View {
    @ObservedObject var engine: Engine
    @State var page: Page = .home
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Page { case home, settings }

    /// The window is exactly the content: home sizes itself, settings has a
    /// fixed height (one resize on page change, never a grey margin). The dark
    /// background fills the whole window, safe areas included.
    var body: some View {
        ZStack(alignment: .top) {
            if page == .home {
                HomeView(engine: engine, openSettings: { go(.settings) })
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(slide(from: .leading))
            } else {
                SettingsView(engine: engine, back: { go(.home) })
                    .frame(height: 520)
                    .transition(slide(from: .trailing))
            }
        }
        .frame(width: 340, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .background(Theme.bg.ignoresSafeArea())
        .modifier(WindowBackground())
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private func go(_ target: Page) {
        withAnimation(reduceMotion ? Theme.fade : Theme.smooth) { page = target }
    }

    private func slide(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
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

/// No container-level implicit animations here: animating layout inside a
/// MenuBarExtra window makes it jump.
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
            Modes(engine: engine)
            StatusBar(engine: engine)
        }
        .padding(18)
    }
}

private struct Header: View {
    @ObservedObject var engine: Engine
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PugFace(mood: engine.mood, size: 34)
                .frame(width: 44, height: 36)
                .animation(Theme.fade, value: engine.mood)
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

    private var dotColor: Color {
        if engine.trip != nil { return Palette.warn }
        return engine.isActive ? Theme.live : Theme.faint
    }
}

/// Static status dot. Color changes crossfade; nothing loops.
struct LiveDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .animation(Theme.fade, value: color)
    }
}

// MARK: Timer

private struct TimerBlock: View {
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
            VStack(alignment: .leading, spacing: 8) {
                Text(bigText(mode, at: date))
                    .font(.system(size: 46, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(mode == .idle ? Theme.faint : (mode == .trip ? Palette.warn : Theme.text))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // Only animates inside an explicit transaction (picking a duration),
                    // never on the per-second redraw.
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Theme.fade, value: engine.manualOn)
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
            if let end = engine.manualEnd { return tr("until %@", end.formatted(date: .omitted, time: .shortened)) }
        case .grace:
            // A duration with units: "14:38" here once read as a clock time.
            return tr("Sleeping in %@", Fmt.countdown((engine.graceUntil ?? date).timeIntervalSince(date)))
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
            let total = TimeInterval(max(1, engine.graceMinutes) * 60)
            return CGFloat(max(0, min(1, (engine.graceUntil ?? date).timeIntervalSince(date) / total)))
        default:
            return 0
        }
    }
}

// MARK: Durations

private struct Durations: View {
    @ObservedObject var engine: Engine
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let choices = [30, 60, 120, 240, 480, 0]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.self) { m in
                Segment(title: Fmt.minutes(m), selected: engine.selectedMinutes == m, ns: ns) {
                    guard engine.selectedMinutes != m else { return }
                    if reduceMotion { engine.choose(minutes: m) } else { withAnimation(Theme.smooth) { engine.choose(minutes: m) } }
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface))
        // Agents, grace or a trigger are in charge: picking a time would do nothing visible.
        .opacity(!engine.manualOn && engine.isActive ? 0.45 : 1)
        .help(engine.manualOn ? tr("Picking a time restarts the countdown") : "")
        .accessibilityLabel(tr("Duration"))
    }

    private struct Segment: View {
        let title: String
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
                                .fill(Color.white.opacity(0.1))
                                .matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(Theme.hover, value: hover)
        }
    }
}

// MARK: Main action

private struct MainAction: View {
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
                ActionButton(title: tr("Go AFK"), style: .solid) { engine.start() }
                    .disabled(engine.trip != nil)
                    .keyboardShortcut(.defaultAction)
                    .help(tripHelp)
                if engine.canSleepNow {
                    ActionButton(title: tr("Sleep now"), style: .outline) { engine.sleepNow() }
                        .frame(width: 118)
                        .help(tr("Let the Mac sleep now; music or the charger won't keep it awake until they stop and start again"))
                }
            }
        }
        .frame(height: 40)
        .animation(Theme.fade, value: engine.manualOn)
    }

    private var tripHelp: String {
        switch engine.trip {
        case .battery: return tr("Plug in the charger to keep going")
        case .thermal: return tr("Waiting for the Mac to cool down")
        case nil: return ""
        }
    }
}

private struct ActionButton: View {
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
                .foregroundStyle(style == .solid ? Color.black : Theme.text)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(style == .outline ? Color.white.opacity(lit ? 0.35 : 0.2) : .clear, lineWidth: 1)
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
        case .solid: return Color.white.opacity(lit ? 1 : 0.92)
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
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let on = configuration.isOn
            Button {
                configuration.isOn.toggle()
            } label: {
                Capsule()
                    .fill(on ? Theme.accent : Color.white.opacity(0.14))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(on ? Color.black.opacity(0.85) : Color.white.opacity(0.75))
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
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            ModeRow(symbol: "sparkles", title: tr("Agent mode"), detail: agentDetail) {
                Toggle(tr("Agent mode"), isOn: $engine.agentMode).toggleStyle(MiniSwitch()).labelsHidden()
            }
            if engine.agentMode, !engine.holds.isEmpty {
                // At most 3 rows so the window doesn't keep growing.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.holds.prefix(3)) { hold in
                        AgentRow(hold: hold) { engine.release(hold) }
                    }
                    if engine.holds.count > 3 {
                        Text(tr("+%d more", engine.holds.count - 3)).font(.system(size: 11)).foregroundStyle(Theme.sub)
                            .padding(.leading, 14)
                    }
                }
                .padding(.leading, 30).padding(.bottom, 8)
            }
            if engine.agentMode, !engine.claudeConnected {
                HStack(spacing: 8) {
                    Text(tr("Connect Claude Code to detect work automatically."))
                        .font(.system(size: 11)).foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PillButton(title: tr("Connect"), style: .soft) { engine.connectClaude() }
                }
                .padding(.leading, 30).padding(.bottom, engine.claudeError == nil ? 10 : 4)
                if let error = engine.claudeError {
                    ErrorText(error).padding(.leading, 30).padding(.bottom, 10)
                }
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
                    if engine.setupWorking {
                        PillButton(title: tr("Working…"), style: .soft) {}.disabled(true)
                    } else {
                        PillButton(title: tr("Set up"), style: .primary) { engine.runSetup() }
                    }
                }
                .padding(.leading, 30).padding(.bottom, 10)
            }
            if let error = engine.setupError {
                ErrorText(error).padding(.leading, 30).padding(.bottom, 10)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            ModeRow(symbol: "music.note", title: tr("Keep music playing"), detail: musicDetail) {
                Toggle(tr("Keep music playing"), isOn: $engine.keepMusic).toggleStyle(MiniSwitch()).labelsHidden()
            }
        }
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
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.warn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentRow: View {
    let hold: AgentHold
    var release: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            LiveDot(color: Theme.live)
            Text(hold.displayName).font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            // Minute resolution, so a slow timeline is enough (and it only runs while visible).
            // The time keeps its width; a long name truncates instead.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(hold.expires.map { tr("until %@", $0.formatted(date: .omitted, time: .shortened)) }
                     ?? tr("working for %@", Fmt.duration(Clock.now().timeIntervalSince(hold.started))))
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
        .padding(.vertical, 4)
    }
}

// MARK: Status bar

private struct StatusBar: View {
    @ObservedObject var engine: Engine
    @State private var quitHover = false

    var body: some View {
        HStack(spacing: 14) {
            if engine.battery.hasBattery {
                item(batterySymbol, "\(engine.battery.percent)%",
                     warn: engine.battery.percent <= engine.batteryFloor && !engine.battery.onAC)
            }
            item("thermometer.medium", engine.thermal.label, warn: engine.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
            item("laptopcomputer", engine.lidOverrideOn ? tr("Lid: keeps running") : tr("Lid: sleeps"), warn: false)
            Spacer(minLength: 8)
            Button(tr("Quit")) { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(quitHover ? Theme.text : Theme.faint)
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
        .foregroundStyle(warn ? Palette.warn : Theme.faint)
    }
}

// MARK: Summary

private struct SummaryCard: View {
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
                Figure(value: Fmt.duration(summary.duration), label: tr("lid closed"))
                if summary.hadBattery {
                    Figure(value: "\(max(0, summary.startBattery - summary.endBattery))%", label: tr("battery used"))
                }
                Figure(value: "\(summary.agentsFinished)", label: tr("agent turns"))
                Figure(value: summary.peakThermal.label, label: tr("peak heat"))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
    }

    private struct Figure: View {
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
