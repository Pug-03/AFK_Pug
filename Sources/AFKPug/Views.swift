import SwiftUI

struct RootView: View {
    @ObservedObject var engine: Engine
    @State var page: Page = .home

    enum Page { case home, settings }

    var body: some View {
        ZStack {
            if page == .home {
                HomeView(engine: engine, openSettings: { withAnimation(.snappy(duration: 0.3)) { page = .settings } })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                SettingsView(engine: engine, back: { withAnimation(.snappy(duration: 0.3)) { page = .home } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: 360)
    }
}

// MARK: - Scene colours per state

private enum StageMood {
    case night, day, alert

    @MainActor init(_ engine: Engine) {
        if engine.trip != nil { self = .alert } else { self = engine.isActive ? .day : .night }
    }

    var gradient: [Color] {
        switch self {
        case .night: return [Color(red: 0.13, green: 0.14, blue: 0.30), Color(red: 0.27, green: 0.22, blue: 0.45)]
        case .day: return [Color(red: 1.00, green: 0.72, blue: 0.42), Color(red: 0.93, green: 0.42, blue: 0.24)]
        case .alert: return [Color(red: 0.45, green: 0.18, blue: 0.20), Color(red: 0.70, green: 0.28, blue: 0.24)]
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var engine: Engine
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Stage(engine: engine, openSettings: openSettings)
            Controls(engine: engine)
            if let summary = engine.summary {
                SummaryCard(summary: summary) { withAnimation { engine.summary = nil } }
            }
            ModesList(engine: engine)
            StatusBar(engine: engine)
        }
        .padding(12)
    }
}

// MARK: Stage (hero)

private struct Stage: View {
    @ObservedObject var engine: Engine
    var openSettings: () -> Void

    var body: some View {
        let scene = StageMood(engine)
        ZStack(alignment: .top) {
            LinearGradient(colors: scene.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                .animation(.easeInOut(duration: 0.8), value: engine.isActive)

            if scene == .night { Stars().transition(.opacity) }
            if scene == .day { Sun().transition(.opacity) }

            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "pawprint.fill").font(.system(size: 10, weight: .bold))
                        Text("AFK PUG").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1.5)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    GlassButton(symbol: "slider.horizontal.3", action: openSettings)
                }

                ZStack(alignment: .bottom) {
                    Ellipse()
                        .fill(.black.opacity(0.18))
                        .frame(width: 92, height: 14)
                        .blur(radius: 3)
                        .offset(y: 4)
                    PugFace(mood: engine.mood, size: 92)
                        .frame(width: 120, height: 96)
                }
                .padding(.top, 2)

                VStack(spacing: 3) {
                    if engine.manualOn, let r = engine.remaining {
                        Text(Fmt.clock(r))
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy, value: Int(r))
                    } else {
                        Text(engine.headline)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                    }
                    Text(engine.manualOn && engine.remaining != nil ? engine.headline : engine.subline)
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.82)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            }
            .padding(14)

            if engine.manualOn, engine.remaining != nil {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.22))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: geo.size.width * engine.progress)
                                    .animation(.linear(duration: 0.4), value: engine.progress)
                            }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(height: 252)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: scene.gradient[1].opacity(0.35), radius: 14, y: 6)
        .animation(.easeInOut(duration: 0.6), value: scene)
    }
}

private struct Stars: View {
    private let stars: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (0.10, 0.22, 2.0, 0.0), (0.22, 0.10, 1.4, 0.6), (0.82, 0.30, 2.2, 1.2), (0.70, 0.12, 1.3, 0.3),
        (0.92, 0.55, 1.5, 0.9), (0.06, 0.62, 1.3, 1.5), (0.30, 0.40, 1.1, 0.4), (0.60, 0.48, 1.0, 1.1),
        (0.15, 0.85, 1.6, 0.7), (0.88, 0.80, 1.2, 0.2),
    ]
    @State private var twinkle = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<stars.count, id: \.self) { i in
                    let s = stars[i]
                    Circle().fill(.white)
                        .frame(width: s.2 * 1.6, height: s.2 * 1.6)
                        .position(x: geo.size.width * s.0, y: geo.size.height * s.1)
                        .opacity(twinkle ? 0.25 + (s.3 / 3) : 0.9)
                        .animation(.easeInOut(duration: 1.6 + s.3).repeatForever(autoreverses: true), value: twinkle)
                }
                Circle()
                    .fill(Color(red: 1, green: 0.95, blue: 0.82))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().fill(StageMood.night.gradient[0]).frame(width: 22, height: 22).offset(x: 8, y: -5))
                    .position(x: geo.size.width * 0.16, y: geo.size.height * 0.36)
                    .opacity(0.9)
            }
        }
        .onAppear { twinkle = true }
        .allowsHitTesting(false)
    }
}

private struct Sun: View {
    @State private var spin = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle().fill(.white.opacity(0.18)).frame(width: 220, height: 220)
                Circle().fill(.white.opacity(0.14)).frame(width: 150, height: 150)
            }
            .position(x: geo.size.width * 0.5, y: geo.size.height * 0.42)
            .scaleEffect(spin ? 1.06 : 0.96)
            .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: spin)
        }
        .onAppear { spin = true }
        .allowsHitTesting(false)
    }
}

private struct GlassButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hover ? 0.3 : 0.18)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tr("Settings"))
    }
}

// MARK: Controls

private struct Controls: View {
    @ObservedObject var engine: Engine
    @Namespace private var ns
    private let choices = [30, 60, 120, 240, 480, 0]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(choices, id: \.self) { m in
                    let selected = engine.selectedMinutes == m
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { engine.choose(minutes: m) }
                    } label: {
                        Text(Fmt.minutes(m))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background {
                                if selected {
                                    Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                        .matchedGeometryEffect(id: "chip", in: ns)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))

            if engine.manualOn {
                HStack(spacing: 8) {
                    BigButton(title: tr("Stop"), symbol: "stop.fill", style: .secondary) { withAnimation(.snappy) { engine.stop() } }
                    BigButton(title: tr("+30m"), symbol: "plus", style: .tinted) { engine.addTime(minutes: 30) }
                        .frame(width: 118)
                }
            } else {
                BigButton(title: tr("Go AFK"), symbol: "pawprint.fill", style: .primary) { withAnimation(.snappy) { engine.start() } }
                    .disabled(engine.trip != nil)
            }
        }
    }
}

private struct BigButton: View {
    enum Style { case primary, secondary, tinted }
    let title: String
    let symbol: String
    var style: Style = .primary
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                Text(title).font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(background))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(style == .primary ? 0.25 : 0), lineWidth: 1)
                    .blendMode(.overlay)
            )
            .shadow(color: style == .primary ? Palette.apricotDeep.opacity(hover ? 0.45 : 0.28) : .clear, radius: hover ? 10 : 6, y: 3)
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(duration: 0.25)) { pressed = false } })
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .primary
        case .tinted: return Palette.apricotDeep
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .primary: return AnyShapeStyle(LinearGradient(colors: [Palette.apricot, Palette.apricotDeep], startPoint: .top, endPoint: .bottom))
        case .secondary: return AnyShapeStyle(Color.primary.opacity(hover ? 0.11 : 0.07))
        case .tinted: return AnyShapeStyle(Palette.apricot.opacity(hover ? 0.24 : 0.16))
        }
    }
}

// MARK: Modes (grouped list)

private struct ModesList: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            ListRow(symbol: "sparkles", tint: Palette.awake, title: tr("Agent mode"),
                    detail: agentDetail) {
                Toggle("", isOn: $engine.agentMode).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Palette.awake)
            }
            if engine.agentMode, !engine.holds.isEmpty {
                VStack(spacing: 6) {
                    ForEach(engine.holds) { hold in
                        AgentRow(hold: hold, now: engine.now) { engine.release(hold) }
                    }
                }
                .padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 10)
            }
            if engine.agentMode, !engine.claudeConnected {
                HStack {
                    Text(tr("Connect Claude Code to detect work automatically."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    PillButton(title: tr("Connect"), style: .soft) { engine.connectClaude() }
                }
                .padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 10)
            }

            Divider().padding(.leading, 44)

            ListRow(symbol: "laptopcomputer", tint: Palette.apricot, title: tr("Lid-closed mode"),
                    detail: engine.setupDone ? tr("Screen off, sound off, work keeps running") : tr("Needs a one-time permission")) {
                if engine.setupDone || !engine.lidMode {
                    Toggle("", isOn: $engine.lidMode).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Palette.apricot)
                } else {
                    PillButton(title: tr("Set up"), style: .primary) { engine.runSetup() }
                }
            }
            if let error = engine.setupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.warn)
                    .padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().padding(.leading, 44)

            ListRow(symbol: engine.musicPlaying ? "music.note" : "music.note.list", tint: Palette.night, title: tr("Keep music playing"),
                    detail: engine.musicPlaying && engine.keepMusic ? tr("music playing") : tr("YouTube, Spotify, Apple Music keep playing and sound stays on")) {
                Toggle("", isOn: $engine.keepMusic).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Palette.night)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var agentDetail: String {
        if !engine.agentMode { return tr("Awake only while your AI agents work") }
        if engine.holds.isEmpty {
            return engine.graceUntil.map { $0 > engine.now } == true ? tr("All done. Cooling down before sleep") : tr("No agents working right now")
        }
        return tr("Awake only while your AI agents work")
    }
}

private struct ListRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 28, height: 28)
                Image(systemName: symbol).font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

private struct AgentRow: View {
    let hold: AgentHold
    let now: Date
    var release: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.awake).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Palette.awake.opacity(0.6), lineWidth: 2).scaleEffect(pulse ? 2.4 : 1).opacity(pulse ? 0 : 1))
                .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true } }
            Text(hold.displayName).font(.system(size: 12, weight: .semibold))
            Text(hold.expires.map { tr("until %@", $0.formatted(date: .omitted, time: .shortened)) } ?? tr("working for %@", Fmt.duration(now.timeIntervalSince(hold.started))))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button(action: release) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help(tr("Stop keeping awake for this one"))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.awake.opacity(0.08)))
    }
}

// MARK: Status bar

private struct StatusBar: View {
    @ObservedObject var engine: Engine

    var batterySymbol: String {
        if engine.battery.onAC { return "battery.100percent.bolt" }
        switch engine.battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var thermalColor: Color {
        switch engine.thermal {
        case .nominal: return Palette.awake
        case .fair: return Palette.apricot
        default: return Palette.warn
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if engine.battery.hasBattery {
                Stat(symbol: batterySymbol, text: "\(engine.battery.percent)%",
                     tint: engine.battery.percent <= engine.batteryFloor && !engine.battery.onAC ? Palette.warn : .secondary)
            }
            Stat(symbol: "thermometer.medium", text: engine.thermal.label, tint: thermalColor)
            Stat(symbol: engine.lidOverrideOn ? "lock.open.fill" : "lock.fill",
                 text: engine.lidOverrideOn ? tr("Lid armed") : tr("Lid normal"),
                 tint: engine.lidOverrideOn ? Palette.apricot : .secondary)
            Spacer()
            Button(tr("Quit")) { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    private struct Stat: View {
        let symbol: String
        let text: String
        let tint: Color
        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                Text(text).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Summary

private struct SummaryCard: View {
    let summary: LidSummary
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("While you were away"), systemImage: "sun.horizon.fill")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.apricotDeep)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Figure(value: Fmt.duration(summary.duration), label: tr("lid closed"))
                if summary.hadBattery {
                    Figure(value: "\(summary.startBattery - summary.endBattery)%", label: tr("battery used"))
                }
                Figure(value: "\(summary.agentsFinished)", label: tr("agent turns"))
                Figure(value: summary.peakThermal.label, label: tr("peak heat"))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.apricot.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.apricot.opacity(0.3), lineWidth: 1))
    }

    private struct Figure: View {
        let value: String
        let label: String
        var body: some View {
            VStack(spacing: 1) {
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
