import SwiftUI

struct RootView: View {
    @ObservedObject var engine: Engine
    @State private var page: Page = .home

    enum Page { case home, settings }

    var body: some View {
        ZStack {
            if page == .home {
                HomeView(engine: engine, openSettings: { withAnimation(.snappy) { page = .settings } })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                SettingsView(engine: engine, back: { withAnimation(.snappy) { page = .home } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: 340)
        .background(
            LinearGradient(colors: [Palette.apricot.opacity(engine.isActive ? 0.14 : 0.05), .clear],
                           startPoint: .top, endPoint: .center)
                .animation(.easeInOut(duration: 0.6), value: engine.isActive)
        )
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var engine: Engine
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Header(engine: engine, openSettings: openSettings)
            HeroCard(engine: engine)
            if let summary = engine.summary {
                SummaryCard(summary: summary) { withAnimation { engine.summary = nil } }
            }
            AgentsCard(engine: engine)
            LidCard(engine: engine)
            VitalsStrip(engine: engine)
            Footer()
        }
        .padding(14)
    }
}

private struct Header: View {
    @ObservedObject var engine: Engine
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PugFace(mood: engine.mood, size: 52)
                .frame(width: 64, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("AFK Pug").font(.system(size: 15, weight: .heavy, design: .rounded))
                    StatusDot(engine: engine)
                }
                Text(engine.headline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))
                    .contentTransition(.opacity)
                Text(engine.subline)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "gearshape.fill", action: openSettings)
        }
    }
}

private struct StatusDot: View {
    @ObservedObject var engine: Engine
    @State private var pulse = false

    var color: Color {
        if engine.trip != nil { return Palette.warn }
        return engine.isActive ? Palette.awake : Color.secondary.opacity(0.5)
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

// MARK: Hero

private struct HeroCard: View {
    @ObservedObject var engine: Engine
    private let choices = [30, 60, 120, 240, 480, 0]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Ring(progress: engine.manualOn ? engine.progress : 0, active: engine.manualOn) {
                    VStack(spacing: 0) {
                        if engine.manualOn {
                            Text(engine.remaining.map { Fmt.clock($0) } ?? "∞")
                                .font(.system(size: engine.remaining == nil ? 26 : 15, weight: .bold, design: .rounded).monospacedDigit())
                                .minimumScaleFactor(0.6)
                            Text("left").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "moon.zzz.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Palette.night.opacity(0.8))
                        }
                    }
                }
                .frame(width: 78, height: 78)

                VStack(alignment: .leading, spacing: 8) {
                    Text(engine.manualOn ? "You're AFK" : "Going somewhere?")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(engine.manualOn ? "Close the lid. Agents, builds and downloads keep running." : "Keep your Mac awake, even with the lid closed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if engine.manualOn {
                        HStack(spacing: 6) {
                            PillButton(title: "+30m", style: .soft) { engine.addTime(minutes: 30) }
                            PillButton(title: "Stop", style: .quiet) { withAnimation(.snappy) { engine.stop() } }
                        }
                    } else {
                        PillButton(title: "Go AFK", symbol: "pawprint.fill", style: .primary) {
                            withAnimation(.snappy) { engine.start() }
                        }
                        .disabled(engine.trip != nil)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
                ForEach(choices, id: \.self) { m in
                    Chip(title: Fmt.minutes(m), selected: engine.selectedMinutes == m) {
                        withAnimation(.snappy) { engine.choose(minutes: m) }
                    }
                }
            }
        }
        .card(highlight: engine.manualOn)
    }
}

private struct Ring<Content: View>: View {
    var progress: Double
    var active: Bool
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 7)
            Circle()
                .trim(from: 0, to: active ? progress : 0)
                .stroke(AngularGradient(colors: [Palette.apricot, Palette.apricotDeep, Palette.apricot], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.4), value: progress)
            content
        }
    }
}

// MARK: Agents

private struct AgentsCard: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToggleRow(symbol: "sparkles", tint: Palette.awake, title: "Agent mode",
                      detail: "Awake only while your AI agents work", isOn: $engine.agentMode)

            if engine.agentMode {
                if !engine.claudeConnected {
                    HStack {
                        Text("Connect Claude Code to detect work automatically.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        PillButton(title: "Connect", style: .soft) { engine.connectClaude() }
                    }
                }
                if engine.holds.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                        Text(engine.graceUntil.map { $0 > engine.now } == true ? "All done. Cooling down before sleep" : "No agents working right now")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(engine.holds) { hold in
                            AgentRow(hold: hold, now: engine.now) { engine.release(hold) }
                        }
                    }
                }
            }
        }
        .card()
    }
}

private struct AgentRow: View {
    let hold: AgentHold
    let now: Date
    var release: () -> Void
    @State private var spin = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(Palette.awake.opacity(0.15)).frame(width: 24, height: 24)
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.awake)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(hold.displayName).font(.system(size: 12, weight: .semibold))
                Text(hold.expires.map { "until \($0.formatted(date: .omitted, time: .shortened))" } ?? "working for \(Fmt.duration(now.timeIntervalSince(hold.started)))")
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: release) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Stop keeping awake for this one")
        }
    }
}

// MARK: Lid

private struct LidCard: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToggleRow(symbol: "laptopcomputer", tint: Palette.apricot, title: "Lid-closed mode",
                      detail: engine.setupDone ? "Screen off, sound off, work keeps running" : "Needs a one-time permission",
                      isOn: $engine.lidMode)
            if engine.lidMode, !engine.setupDone {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(Palette.apricot)
                    Text("Asks for your password once. Only allows turning lid sleep on and off.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PillButton(title: "Set up", style: .primary) { engine.runSetup() }
                }
            }
            if let error = engine.setupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.warn)
            }
        }
        .card()
    }
}

// MARK: Vitals

private struct VitalsStrip: View {
    @ObservedObject var engine: Engine

    var batterySymbol: String {
        let p = engine.battery.percent
        if engine.battery.onAC { return "battery.100percent.bolt" }
        switch p {
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
        HStack(spacing: 6) {
            if engine.battery.hasBattery {
                Vital(symbol: batterySymbol, text: "\(engine.battery.percent)%",
                      tint: engine.battery.percent <= engine.batteryFloor && !engine.battery.onAC ? Palette.warn : .primary)
            }
            Vital(symbol: "thermometer.medium", text: engine.thermal.label, tint: thermalColor)
            Vital(symbol: engine.lidOverrideOn ? "lock.open.fill" : "lock.fill",
                  text: engine.lidOverrideOn ? "Lid armed" : "Lid normal",
                  tint: engine.lidOverrideOn ? Palette.apricot : .secondary)
        }
    }
}

private struct Vital: View {
    let symbol: String
    let text: String
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: Summary

private struct SummaryCard: View {
    let summary: LidSummary
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("While you were away", systemImage: "sun.horizon.fill")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.apricotDeep)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Stat(value: Fmt.duration(summary.duration), label: "lid closed")
                if summary.hadBattery {
                    Stat(value: "\(summary.startBattery - summary.endBattery)%", label: "battery used")
                }
                Stat(value: "\(summary.agentsFinished)", label: "agent turns")
                Stat(value: summary.peakThermal.label, label: "peak heat")
            }
        }
        .card(highlight: true)
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Footer: View {
    var body: some View {
        HStack {
            Text("tip: afkpug run -- <cmd>")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}
