import SwiftUI

struct SettingsView: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine
    var back: () -> Void
    @State private var confirmRemove = false
    @State private var confirmUninstall = false
    @State private var phoneSent = false
    @State private var showDev = false

    private var musicDetail: String {
        if engine.keepMusic, engine.musicPlaying, !engine.musicApps.isEmpty {
            return tr("Playing: %@", engine.musicApps.prefix(2).joined(separator: ", "))
        }
        return tr("Keeps playing after you close the lid")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", label: tr("Back"), action: back)
                    .keyboardShortcut(.cancelAction)
                Text(tr("Settings")).font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            ScrollView {
                VStack(spacing: 18) {
                    Section(title: tr("Keep awake")) {
                        Row(symbol: "laptopcomputer", title: tr("Lid-closed mode"),
                            detail: engine.setupDone ? tr("Screen off, work keeps running") : tr("Needs a one-time permission")) {
                            Toggle(tr("Lid-closed mode"), isOn: $engine.lidMode).toggleStyle(MiniSwitch()).labelsHidden()
                        }
                        if engine.lidMode, !engine.setupDone {
                            HStack(spacing: 8) {
                                Text(tr("Asks for your password once. Only allows turning lid sleep and Low Power Mode on and off."))
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
                            .padding(.leading, 30)
                        }
                        if engine.lidMode, let error = engine.setupError {
                            ErrorText(error).padding(.leading, 30)
                        }
                        Row(symbol: "sun.max", title: tr("Keep the screen on"), detail: tr("On the charger, lid open")) {
                            KeepScreenPicker(engine: engine)
                        }
                        ToggleRow(symbol: "music.note", title: tr("Keep music playing"), detail: musicDetail, isOn: $engine.keepMusic)
                    }

                    Section(title: tr("When the lid closes")) {
                        ToggleRow(symbol: "display", title: tr("Turn the screen off"),
                                  detail: tr("Keeps the panel dark under the lid"), isOn: $engine.displayOffOnClose)
                        ToggleRow(symbol: "speaker.slash", title: tr("Mute sound"),
                                  detail: tr("Restored when you open the lid"), isOn: $engine.muteOnClose)
                        ToggleRow(symbol: "leaf", title: tr("Low Power Mode on battery"),
                                  detail: tr("Also turns on if the Mac gets hot"), isOn: $engine.lowPowerOnClose)
                        ToggleRow(symbol: "lock", title: tr("Lock the screen"),
                                  detail: tr("Nobody can use your Mac while you're away"), isOn: $engine.lockOnClose)
                        ToggleRow(symbol: "bubble.left.and.bubble.right", title: tr("Pause chat apps"),
                                  detail: tr("Slack, Discord, LINE and others. Resumed when you open the lid"), isOn: $engine.pauseChatApps)
                        ToggleRow(symbol: "powerplug", title: tr("Only when plugged in"),
                                  detail: tr("On battery, closing the lid sleeps the Mac as usual"), isOn: $engine.lidOnlyOnPower)
                    }

                    Section(title: tr("Safety")) {
                        Row(symbol: "battery.25percent", title: tr("Stop at battery"),
                            detail: tr("AFK Pug lets the Mac sleep at this level")) {
                            Text("\(engine.batteryFloor)%")
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        }
                        Slider(value: Binding(get: { Double(engine.batteryFloor) },
                                              set: { engine.batteryFloor = Int($0) }), in: 5...50, step: 5)
                            .padding(.leading, 30)
                            .accessibilityLabel(tr("Stop at battery"))
                            .accessibilityValue("\(engine.batteryFloor)%")
                        Footnote(tr("If the Mac gets critically hot, AFK Pug always lets it sleep."))
                    }

                    Section(title: tr("Agents")) {
                        ToggleRow(symbol: "bell", title: tr("Notify me"),
                                  detail: tr("When an agent finishes or needs you"), isOn: $engine.notifyAgents)
                        Row(symbol: "hourglass", title: tr("Wait before sleeping"),
                            detail: tr("After the last agent finishes")) {
                            Picker(tr("Wait before sleeping"), selection: $engine.graceMinutes) {
                                Text(tr("Off")).tag(0); Text(tr("2 min")).tag(2); Text(tr("5 min")).tag(5); Text(tr("15 min")).tag(15)
                            }
                            .labelsHidden().frame(width: 92)
                        }
                        ForEach(AgentIntegrations.all) { item in
                            AgentConnectionRow(engine: engine, item: item)
                        }
                        if ClaudeStatusLine.isAvailable() || engine.claudeUsageOn {
                            Row(symbol: "gauge.with.dots.needle.67percent", title: tr("Claude Code usage limits"),
                                detail: tr("Read from its status line. Yours keeps showing")) {
                                Toggle(tr("Claude Code usage limits"), isOn: Binding(get: { engine.claudeUsageOn }, set: { engine.setClaudeUsage($0) }))
                                    .toggleStyle(MiniSwitch()).labelsHidden()
                            }
                            if let error = engine.claudeUsageError { ErrorText(error).padding(.leading, 30) }
                        }
                        ToggleRow(symbol: "magnifyingglass", title: tr("Detect other agents"),
                                  detail: tr("Codex, Gemini CLI, Cursor Agent, Aider, OpenCode and more"), isOn: $engine.detectOtherAgents)
                        // The plugin ships its own MCP server, so there's nothing to connect here.
                        if MCPInstaller.providedByPlugin {
                            Row(symbol: "cpu", title: tr("Let agents keep the Mac awake"),
                                detail: tr("Provided by the AFK Pug plugin")) { EmptyView() }
                        } else {
                            // Text gets the full width; the button sits on its own line (long Thai titles).
                            Row(symbol: "cpu", title: tr("Let agents keep the Mac awake"),
                                detail: tr("Adds an AFK Pug tool to Claude Code for long builds and deploys")) { EmptyView() }
                            HStack {
                                let titles = [tr("Connect"), tr("Disconnect"), tr("Working…")]
                                if engine.mcpBusy {
                                    PillButton(title: tr("Working…"), style: .soft, reserve: titles) {}.disabled(true)
                                } else if engine.mcpConnected {
                                    PillButton(title: tr("Disconnect"), style: .soft, reserve: titles) { engine.disconnectMCP() }
                                } else {
                                    PillButton(title: tr("Connect"), style: .primary, reserve: titles) { engine.connectMCP() }
                                }
                            }
                            .padding(.leading, 30)
                            if let error = engine.mcpError { ErrorText(error).padding(.leading, 30) }
                        }
                    }

                    Section(title: tr("Phone notifications")) {
                        Text(tr("Install the free ntfy app on your phone, subscribe to a topic name only you know, then enter the same name here."))
                            .font(.system(size: 11)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            TextField(tr("topic name, e.g. afkpug-ab12cd"), text: $engine.phoneTopic)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                            PillButton(title: phoneSent ? tr("Sent") : tr("Test"), style: .soft) {
                                engine.testPhone()
                                phoneSent = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { phoneSent = false }
                            }
                            .disabled(engine.phoneTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Section(title: tr("Start automatically")) {
                        ToggleRow(symbol: "bolt", title: tr("When the charger is connected"),
                                  detail: tr("Stays awake whenever it's plugged in"), isOn: $engine.autoOnPower)
                        Row(symbol: "app.badge", title: tr("While these apps are open"),
                            detail: tr("App names as shown in the Dock, separated by commas")) { EmptyView() }
                        TextField(tr("e.g. Xcode, Docker Desktop, OBS"), text: $engine.autoApps)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                            .padding(.leading, 30)
                    }

                    Section(title: tr("Appearance")) {
                        AppearanceRows()
                    }

                    Section(title: tr("General")) {
                        Row(symbol: "power", title: tr("Open at login"), detail: loginDetail) {
                            Toggle(tr("Open at login"), isOn: Binding(get: { engine.launchAtLogin == .on },
                                                                       set: { engine.setLaunchAtLogin($0) }))
                                .toggleStyle(MiniSwitch()).labelsHidden()
                        }
                        if let error = engine.loginError { ErrorText(error).padding(.leading, 30) }
                        Row(symbol: "hand.wave", title: tr("Show welcome again"), detail: tr("Set up lid-closed mode and agents step by step")) {
                            PillButton(title: tr("Open"), style: .soft) { OnboardingWindow.shared.show() }
                        }
                        ToggleRow(symbol: "menubar.rectangle", title: tr("Show status in the menu bar"),
                              detail: tr("Time left or agents working, beside the A"), isOn: $engine.menuBarStatus)
                    ToggleRow(symbol: "arrow.down.circle", title: tr("Check for updates"),
                              detail: tr("Once a day, asks GitHub for the latest version. Nothing about you is sent."), isOn: $engine.checkUpdates)
                    Row(symbol: "info.circle", title: tr("Version %@", Updater.currentVersion), detail: engine.update == nil ? (engine.updateMessage ?? "") : "") {
                        if let update = engine.update {
                            PillButton(title: tr("Update to %@", update.version), style: .primary) { engine.installUpdate() }
                                .disabled(engine.updateWorking)
                        } else {
                            PillButton(title: engine.updateWorking ? tr("Working…") : tr("Check now"), style: .soft) { engine.checkForUpdatesNow() }
                                .disabled(engine.updateWorking)
                        }
                    }
                    ToggleRow(symbol: "command", title: tr("⌥⌘A starts or stops AFK"),
                                  detail: tr("Works from any app"), isOn: $engine.hotkeyEnabled)
                        Row(symbol: "globe", title: tr("Language"), detail: "") {
                            Picker(tr("Language"), selection: $engine.language) {
                                ForEach(AppLanguage.allCases) { lang in Text(lang.label).tag(lang) }
                            }
                            .labelsHidden().frame(width: 110)
                        }
                    }

                    Section(title: tr("Activity")) {
                        if engine.activity.isEmpty {
                            Text(tr("Nothing yet")).font(.system(size: 11)).foregroundStyle(Theme.sub)
                        }
                        ForEach(engine.activity.prefix(8)) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.icon).font(.system(size: 10)).foregroundStyle(Theme.sub).frame(width: 18)
                                Text(item.text).font(.system(size: 11)).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(Fmt.time(item.date))
                                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.sub)
                            }
                        }
                    }

                    Section(title: tr("For developers")) {
                        Button {
                            showDev.toggle()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "terminal").font(.system(size: 12.5)).foregroundStyle(Theme.sub).frame(width: 18)
                                Text(tr("Command line and URL commands")).font(.system(size: 12.5, weight: .medium))
                                Spacer()
                                Image(systemName: showDev ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.sub)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showDev ? tr("Expanded") : tr("Collapsed"))
                        .accessibilityHint(showDev ? tr("Hides the commands") : tr("Shows the commands"))
                        if showDev {
                            Text("~/.afkpug/bin/afkpug run -- <command>\n~/.afkpug/bin/afkpug hold --for 2h\n~/.afkpug/bin/afkpug status\nafkpug://start?minutes=90  ·  afkpug://stop\nafkpug://toggle  ·  afkpug://sleep-now")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.sub)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if engine.setupDone {
                            ConfirmButton(title: tr("Remove lid-closed permission"), confirm: tr("Remove it? Lid-closed mode stops working."),
                                          busy: engine.setupWorking, armed: $confirmRemove) { engine.removeSetup() }
                        }
                        ConfirmButton(title: tr("Uninstall AFK Pug…"), confirm: tr("Remove hooks, permission and all AFK Pug files, then quit?"),
                                      busy: engine.uninstalling, armed: $confirmUninstall) { engine.uninstallEverything() }
                        ForEach(engine.uninstallErrors, id: \.self) { ErrorText($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
                }
                // Clears the fade below, so the last row can be read at the end.
                .padding(.bottom, 22)
            }
            // A scrollbar would sit on top of the switches. The fade shows there's more.
            .scrollIndicators(.hidden)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
                }
            }
            .frame(maxHeight: .infinity)
            // Momentum ends in didEndLiveScroll too; the timeout covers a scroll with no end.
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in
                CursorSteadier.hold(for: 30)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification)) { _ in
                CursorSteadier.release()
            }
        }
        .padding(18)
        .onAppear { engine.refreshIntegrations() }
    }

    private var loginDetail: String {
        switch engine.launchAtLogin {
        case .on: return tr("Agent mode works right after a restart")
        case .off: return tr("Off: after a restart, open AFK Pug yourself")
        case .needsApproval: return tr("Allow it in System Settings → General → Login Items")
        }
    }
}

/// A red text action that asks once inline before doing something destructive.
private struct ConfirmButton: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let title: String
    let confirm: String
    var busy: Bool
    @Binding var armed: Bool
    let action: () -> Void

    var body: some View {
        if busy {
            Text(tr("Working…")).font(.system(size: 11)).foregroundStyle(Theme.sub)
        } else if armed {
            VStack(alignment: .leading, spacing: 6) {
                Text(confirm).font(.system(size: 11)).foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(title: tr("Yes, remove"), style: .primary) { armed = false; action() }
                    PillButton(title: tr("Cancel"), style: .soft) { armed = false }
                }
            }
        } else {
            Button(title) { armed = true }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.warn)
        }
    }
}

private struct Section<Content: View>: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Only Latin titles are uppercased; Thai has no case.
            // Thai needs the larger size to stay legible (stacked vowels and tone marks).
            Text(L10n.isThai ? title : title.uppercased())
                .font(.system(size: L10n.isThai ? 11.5 : 10, weight: .semibold)).foregroundStyle(Theme.sub).tracking(L10n.isThai ? 0 : 1)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground(radius: 12)
        }
    }
}

// MARK: - Shared components

/// One agent from `AgentIntegrations.all`: connected / not installed / config
/// path, Connect or Disconnect, and the last error inline.
struct AgentConnectionRow: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var engine: Engine
    let item: AgentIntegration
    /// Onboarding only offers Connect and shows "Connected" once done.
    var allowDisconnect = true

    var body: some View {
        let connected = engine.connected[item.id] ?? false
        let available = connected || item.isAvailable()
        VStack(alignment: .leading, spacing: 6) {
            Row(symbol: "link", title: item.name, detail: detail(connected: connected, available: available)) {
                if connected {
                    if allowDisconnect {
                        PillButton(title: tr("Disconnect"), style: .soft) { engine.disconnect(item.id) }
                    } else {
                        DoneMark(title: tr("Connected"))
                    }
                } else if available {
                    PillButton(title: tr("Connect"), style: .primary) { engine.connect(item.id) }
                }
            }
            .opacity(available ? 1 : 0.6)
            if let error = engine.integrationErrors[item.id] { ErrorText(error).padding(.leading, 30) }
            // e.g. Codex only runs new hooks after the user trusts them in /hooks.
            if connected, let note = setupNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
        }
    }

    private var setupNote: String? { item.setupNote }

    private func detail(connected: Bool, available: Bool) -> String {
        if !available { return tr("Not installed") }
        if connected { return allowDisconnect ? tr("Connected") : item.configPath }
        return item.configPath
    }
}

/// Small secondary note under a control, aligned with the row text.
struct Footnote: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.sub)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 30)
    }
}

/// One settings row: icon (18) + 12 + title / detail + trailing control.
struct Row<Trailing: View>: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.sub)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.sub)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            trailing
        }
    }
}

struct ToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Row(symbol: symbol, title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(MiniSwitch()).labelsHidden()
        }
    }
}

struct PillButton: View {
    @ObservedObject var themeStore = ThemeStore.shared
    enum Style { case primary, soft, quiet }
    let title: String
    var symbol: String?
    var style: Style = .primary
    /// Titles this button can switch between ("Connect" / "Working…"): it keeps the
    /// width of the widest, so the row next to it never re-wraps.
    var reserve: [String] = []
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                ZStack {
                    ForEach(Array(reserve.enumerated()), id: \.offset) { Text($0.element).hidden() }
                    Text(title)
                }
                .font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(style == .primary ? Theme.onInk : (style == .soft ? Theme.text : Theme.sub))
            .background(Capsule().fill(background))
            .overlay(Capsule().stroke(style == .soft ? Theme.line : .clear, lineWidth: 1))
            .lineLimit(1)
            .fixedSize()
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(Theme.hover, value: hover)
    }

    private var lit: Bool { hover && enabled }

    private var background: Color {
        switch style {
        case .primary: return Theme.ink.opacity(lit ? 1 : 0.9)
        case .soft: return lit ? Theme.surfaceHover : Theme.ink.opacity(0.06)
        case .quiet: return lit ? Theme.surface : .clear
        }
    }
}

struct IconButton: View {
    @ObservedObject var themeStore = ThemeStore.shared
    let symbol: String
    var size: CGFloat = 28
    var label: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(hover ? Theme.text : Theme.sub)
                .frame(width: size, height: size)
                .background(Circle().fill(hover ? Theme.surfaceHover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(Theme.hover, value: hover)
        .accessibilityLabel(label.isEmpty ? symbol : label)
        .help(label)
    }
}
