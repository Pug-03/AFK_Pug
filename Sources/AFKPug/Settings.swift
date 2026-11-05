import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: Engine
    var back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", action: back)
                Text(tr("Settings")).font(.system(size: 15, weight: .heavy, design: .rounded))
                Spacer()
            }

            ScrollView {
                VStack(spacing: 12) {
                    Section(title: tr("Language")) {
                        Picker("", selection: $engine.language) {
                            ForEach(AppLanguage.allCases) { lang in Text(lang.label).tag(lang) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Section(title: tr("When the lid closes")) {
                        ToggleRow(symbol: "music.note", tint: Palette.night, title: tr("Keep music playing"),
                                  detail: tr("YouTube, Spotify, Apple Music keep playing and sound stays on"), isOn: $engine.keepMusic)
                        ToggleRow(symbol: "display", tint: Palette.night, title: tr("Turn the screen off"),
                                  detail: tr("Keeps the panel dark under the lid"), isOn: $engine.displayOffOnClose)
                        ToggleRow(symbol: "speaker.slash.fill", tint: Palette.night, title: tr("Mute sound"),
                                  detail: tr("Restored when you open the lid"), isOn: $engine.muteOnClose)
                        ToggleRow(symbol: "leaf.fill", tint: Palette.awake, title: tr("Low Power Mode on battery"),
                                  detail: tr("Also turns on if the Mac gets hot"), isOn: $engine.lowPowerOnClose)
                        ToggleRow(symbol: "powerplug.fill", tint: Palette.apricot, title: tr("Only when plugged in"),
                                  detail: tr("Lid-closed mode needs a charger"), isOn: $engine.lidOnlyOnPower)
                        ToggleRow(symbol: "lock.fill", tint: Palette.mask, title: tr("Lock the screen"),
                                  detail: tr("Nobody can use your Mac while you're away"), isOn: $engine.lockOnClose)
                        ToggleRow(symbol: "bubble.left.and.bubble.right.fill", tint: Palette.night, title: tr("Pause chat apps"),
                                  detail: tr("Slack, Discord, LINE and others. Resumed when you open the lid"), isOn: $engine.pauseChatApps)
                    }

                    Section(title: tr("Safety")) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(tr("Stop at battery"), systemImage: "battery.25percent")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("\(engine.batteryFloor)%")
                                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Palette.apricotDeep)
                            }
                            Slider(value: Binding(get: { Double(engine.batteryFloor) },
                                                  set: { engine.batteryFloor = Int($0) }), in: 5...50, step: 5)
                                .tint(Palette.apricot)
                        }
                        Text(tr("If the Mac gets critically hot, AFK Pug always lets it sleep."))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }

                    Section(title: tr("Agents")) {
                        ToggleRow(symbol: "bell.badge.fill", tint: Palette.apricot, title: tr("Notify me"),
                                  detail: tr("When an agent finishes or needs you"), isOn: $engine.notifyAgents)
                        HStack {
                            Label(tr("Wait before sleeping"), systemImage: "hourglass").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Picker("", selection: $engine.graceMinutes) {
                                Text(tr("Off")).tag(0); Text(tr("2 min")).tag(2); Text(tr("5 min")).tag(5); Text(tr("15 min")).tag(15)
                            }
                            .labelsHidden().frame(width: 90)
                        }
                        HStack {
                            Label("Claude Code", systemImage: "link").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            if engine.claudeConnected {
                                PillButton(title: tr("Disconnect"), style: .quiet) { engine.disconnectClaude() }
                            } else {
                                PillButton(title: tr("Connect"), style: .soft) { engine.connectClaude() }
                            }
                        }
                        ToggleRow(symbol: "magnifyingglass", tint: Palette.awake, title: tr("Detect other agents"),
                                  detail: tr("Codex, Gemini CLI, Cursor Agent, Aider, OpenCode and more"), isOn: $engine.detectOtherAgents)
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Label(tr("Let agents keep the Mac awake"), systemImage: "cpu").font(.system(size: 12, weight: .semibold))
                                Text(tr("Adds an AFK Pug tool to Claude Code for long builds and deploys"))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if engine.mcpConnected {
                                PillButton(title: tr("Disconnect"), style: .quiet) { engine.disconnectMCP() }
                            } else {
                                PillButton(title: tr("Connect"), style: .soft) { engine.connectMCP() }
                            }
                        }
                        Text(tr("Any other tool: run  afkpug run -- <command>  or  afkpug hold --for 2h  (in ~/.afkpug/bin)"))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Section(title: tr("Phone notifications")) {
                        Text(tr("Install the free ntfy app on your phone, subscribe to a topic name only you know, then enter the same name here."))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            TextField(tr("topic name, e.g. afkpug-nathaporn-82"), text: $engine.phoneTopic)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                            PillButton(title: tr("Test"), style: .soft) { engine.testPhone() }
                                .disabled(engine.phoneTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Section(title: tr("Start automatically")) {
                        ToggleRow(symbol: "bolt.fill", tint: Palette.apricot, title: tr("When the charger is connected"),
                                  detail: tr("Stays awake whenever it's plugged in"), isOn: $engine.autoOnPower)
                        VStack(alignment: .leading, spacing: 4) {
                            Label(tr("While these apps are open"), systemImage: "app.badge").font(.system(size: 12, weight: .semibold))
                            TextField(tr("e.g. Xcode, Docker, OBS"), text: $engine.autoApps)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                        }
                    }

                    Section(title: tr("Shortcut")) {
                        ToggleRow(symbol: "command", tint: Palette.night, title: tr("⌥⌘A starts or stops AFK"),
                                  detail: tr("Works from any app"), isOn: $engine.hotkeyEnabled)
                    }

                    Section(title: tr("Activity")) {
                        if engine.activity.isEmpty {
                            Text(tr("Nothing yet")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(engine.activity.prefix(8)) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.icon).font(.system(size: 10)).foregroundStyle(Palette.apricot).frame(width: 14)
                                Text(item.text).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Text(item.date.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if engine.setupDone {
                        Button(tr("Remove lid-closed permission")) { engine.removeSetup() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.warn)
                    }
                }
            }
            .frame(height: 470)
        }
        .padding(14)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).tracking(0.8)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }
}

// MARK: - Shared components

struct ToggleRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 26, height: 26)
                Image(systemName: symbol).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(tint)
        }
    }
}

struct PillButton: View {
    enum Style { case primary, soft, quiet }
    let title: String
    var symbol: String?
    var style: Style = .primary
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, style == .primary ? 14 : 11)
            .padding(.vertical, 6)
            .foregroundStyle(style == .primary ? Color.white : (style == .soft ? Palette.apricotDeep : Color.secondary))
            .background(
                Capsule().fill(background)
            )
            .shadow(color: style == .primary ? Palette.apricotDeep.opacity(hover ? 0.45 : 0.25) : .clear, radius: hover ? 6 : 3, y: 2)
            .scaleEffect(hover ? 1.03 : 1)
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .primary: return AnyShapeStyle(LinearGradient(colors: [Palette.apricot, Palette.apricotDeep], startPoint: .top, endPoint: .bottom))
        case .soft: return AnyShapeStyle(Palette.apricot.opacity(0.16))
        case .quiet: return AnyShapeStyle(Color.primary.opacity(0.07))
        }
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Palette.apricotDeep : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Palette.apricot.opacity(0.18) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? Palette.apricot.opacity(0.6) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.1 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension View {
    func card(highlight: Bool = false) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(highlight ? Palette.apricot.opacity(0.09) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(highlight ? Palette.apricot.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}
