import SwiftUI

/// One hour of agent work. `hour` is hours since 1970, so buckets line up with the clock.
struct HustleBucket: Codable, Equatable {
    var hour: Int
    /// Agent-seconds: two agents working for a minute count 120.
    var seconds: Double = 0
    /// Tool calls seen, roughly: a new tool or target on a tick.
    var steps: Int = 0
    /// Turns that ended without an error.
    var jobs: Int = 0
    /// The part of `seconds` worked while you were away: lid closed, or nobody at the Mac for 5 minutes.
    var away: Double = 0
    /// Agent-seconds spent waiting for your answer.
    var waited: Double = 0

    init(hour: Int, seconds: Double = 0, steps: Int = 0, jobs: Int = 0, away: Double = 0, waited: Double = 0) {
        (self.hour, self.seconds, self.steps, self.jobs, self.away, self.waited) = (hour, seconds, steps, jobs, away, waited)
    }

    /// Files from 0.7 have no `away` or `waited`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = try c.decode(Int.self, forKey: .hour)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0
        jobs = try c.decodeIfPresent(Int.self, forKey: .jobs) ?? 0
        away = try c.decodeIfPresent(Double.self, forKey: .away) ?? 0
        waited = try c.decodeIfPresent(Double.self, forKey: .waited) ?? 0
    }
}

/// How hard the agents worked, by the hour. Counted from the holds the engine already
/// scans, saved on this Mac only (`~/.afkpug/state/hustle.json`), kept for 8 days.
@MainActor
final class HustleStore: ObservableObject {
    static let shared = HustleStore()
    static let keepHours = 24 * 8
    /// Ticks further apart than this are a sleep or a stall, not work.
    static let maxGap: TimeInterval = 10
    /// Nobody touched the Mac for this long: you're away, even with the lid open.
    static let awayAfter: TimeInterval = 5 * 60

    /// What the UI draws. Published at most every 15 s, so a tick doesn't redraw the card.
    @Published private(set) var buckets: [HustleBucket]
    /// Always up to date; tests read this.
    private(set) var current: [HustleBucket]
    private let file: URL
    private var lastTick: Date?
    private var lastStep: [String: String] = [:]
    private var lastPublish = Date.distantPast
    private var lastSave = Date.distantPast
    private var dirty = false

    init(file: URL = Paths.state.appendingPathComponent("hustle.json")) {
        self.file = file
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([HustleBucket].self, from: $0) } ?? []
        current = loaded.sorted { $0.hour < $1.hour }
        buckets = current
    }

    /// Shows `buckets` and nothing else: never recorded into or saved. For the welcome tour.
    init(showing buckets: [HustleBucket]) {
        file = URL(fileURLWithPath: "/dev/null")
        current = buckets.sorted { $0.hour < $1.hour }
        self.buckets = current
    }

    /// A believable week of agent work: busy afternoons, a late night, a quiet weekend.
    /// Used by the welcome tour and the README screenshots.
    static func sample(now: Date) -> [HustleBucket] {
        let hour = hour(of: now)
        let daily: [Double] = [0.5, 0.9, 0.7, 1.0, 0.25, 0.1, 0.8]
        var buckets: [HustleBucket] = []
        for back in 0..<(24 * 7) {
            let h = hour - back
            let day = daily[(back / 24) % 7]
            let local = (h + TimeZone.current.secondsFromGMT() / 3600 + 240) % 24
            let curve: Double = [0.7, 0.5, 0.3, 0, 0, 0, 0, 0, 0.2, 0.5, 0.8, 0.9, 0.4, 0.7, 1, 1, 0.9, 0.8, 0.5, 0.3, 0.6, 0.8, 0.5, 0.2][local]
            let wobble = 0.75 + 0.5 * abs(sin(Double(h) * 1.7))
            let seconds = (3600 * 1.6 * curve * day * wobble).rounded()
            guard seconds > 0 else { continue }
            let awayShare = local >= 20 || local < 3 ? 0.9 : (local == 12 ? 0.8 : 0.25)
            buckets.append(HustleBucket(hour: h, seconds: seconds, steps: Int(seconds / 25), jobs: Int(seconds / 1500),
                                        away: (seconds * awayShare).rounded(), waited: (seconds * 0.04).rounded()))
        }
        return buckets.reversed()
    }

    /// Called every engine tick with this tick's holds. `away` is only asked for while an agent works.
    func record(holds: [AgentHold], now: Date, away: () -> Bool) {
        let gap = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        if gap > 0, gap <= Self.maxGap {
            let working = Double(holds.filter(Self.isWorking).count)
            let waiting = Double(holds.filter { !$0.isUsageLimitWait && $0.task?.waiting == true }.count)
            if working > 0 {
                let isAway = away()
                add(now) {
                    $0.seconds += gap * working
                    if isAway { $0.away += gap * working }
                }
            }
            if waiting > 0 { add(now) { $0.waited += gap * waiting } }
        }
        var seen: [String: String] = [:]
        var steps = 0
        for hold in holds {
            guard let task = hold.task, let tool = task.tool else { continue }
            let key = tool + "|" + (task.target ?? "")
            seen[hold.id] = key
            if lastStep[hold.id] != key { steps += 1 }
        }
        lastStep = seen
        if steps > 0 { add(now) { $0.steps += steps } }
        flush(now)
    }

    func jobDone(now: Date) {
        add(now) { $0.jobs += 1 }
        flush(now, force: true)
    }

    /// Writes what's pending, e.g. before quitting.
    func save() {
        guard dirty else { return }
        Paths.ensure()
        if let data = try? JSONEncoder().encode(current) { try? data.write(to: file, options: .atomic) }
        dirty = false
    }

    /// Agents doing something: not paused on a limit, not waiting for you, not a hold from the terminal.
    static func isWorking(_ hold: AgentHold) -> Bool {
        !hold.isUsageLimitWait && hold.task?.waiting != true && hold.agent.lowercased() != "cli"
    }

    private func add(_ now: Date, _ change: (inout HustleBucket) -> Void) {
        let hour = Self.hour(of: now)
        if let i = current.lastIndex(where: { $0.hour == hour }) {
            change(&current[i])
        } else {
            var bucket = HustleBucket(hour: hour)
            change(&bucket)
            current.append(bucket)
            current.sort { $0.hour < $1.hour }
            current.removeAll { $0.hour <= hour - Self.keepHours }
        }
        dirty = true
    }

    private func flush(_ now: Date, force: Bool = false) {
        guard dirty else { return }
        if force || abs(now.timeIntervalSince(lastPublish)) >= 15, buckets != current {
            buckets = current
            lastPublish = now
        }
        if force || abs(now.timeIntervalSince(lastSave)) >= 60 {
            save()
            lastSave = now
        }
    }

    nonisolated static func hour(of date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) }
}

// MARK: Reading the numbers

struct HustleSummary: Equatable {
    var seconds: Double = 0
    var steps = 0
    var jobs = 0
    var away: Double = 0
    var waited: Double = 0

    static func + (a: Self, b: HustleBucket) -> Self {
        Self(seconds: a.seconds + b.seconds, steps: a.steps + b.steps, jobs: a.jobs + b.jobs,
             away: a.away + b.away, waited: a.waited + b.waited)
    }

    /// How much of the work happened while you were away, 0...1.
    var awayShare: Double { seconds > 0 ? min(1, away / seconds) : 0 }
}

/// One bar: a span of time and what happened in it.
struct HustleBar: Identifiable, Equatable {
    let id: Int
    let start: Date
    let total: HustleSummary
}

enum HustleRange: String, CaseIterable { case day, week }

enum Hustle {
    /// Since midnight, local time.
    static func today(_ buckets: [HustleBucket], now: Date, calendar: Calendar = .current) -> HustleSummary {
        let from = HustleStore.hour(of: calendar.startOfDay(for: now))
        return buckets.filter { $0.hour >= from }.reduce(HustleSummary(), +)
    }

    /// 24 hourly bars ending with this hour, or 7 daily bars ending today.
    static func bars(_ buckets: [HustleBucket], range: HustleRange, now: Date, calendar: Calendar = .current) -> [HustleBar] {
        switch range {
        case .day:
            let last = HustleStore.hour(of: now)
            return (0..<24).map { i in
                let hour = last - 23 + i
                let total = buckets.filter { $0.hour == hour }.reduce(HustleSummary(), +)
                return HustleBar(id: i, start: Date(timeIntervalSince1970: Double(hour) * 3600), total: total)
            }
        case .week:
            let today = calendar.startOfDay(for: now)
            return (0..<7).map { i in
                let start = calendar.date(byAdding: .day, value: i - 6, to: today) ?? today
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                let (a, b) = (HustleStore.hour(of: start), HustleStore.hour(of: end))
                let total = buckets.filter { $0.hour >= a && $0.hour < b }.reduce(HustleSummary(), +)
                return HustleBar(id: i, start: start, total: total)
            }
        }
    }
}

/// How busy today was, by agent time.
enum HustleLevel: Int, CaseIterable {
    case napping, warmingUp, busy, grinding, onFire

    init(seconds: Double) {
        switch seconds {
        case ..<60: self = .napping
        case ..<1800: self = .warmingUp
        case ..<7200: self = .busy
        case ..<18000: self = .grinding
        default: self = .onFire
        }
    }

    var title: String {
        switch self {
        case .napping: return tr("Napping")
        case .warmingUp: return tr("Warming up")
        case .busy: return tr("Busy")
        case .grinding: return tr("Grinding")
        case .onFire: return tr("On fire")
        }
    }

    var symbol: String {
        switch self {
        case .napping: return "moon.zzz.fill"
        case .warmingUp: return "sparkle"
        case .busy: return "bolt.fill"
        case .grinding: return "hammer.fill"
        case .onFire: return "flame.fill"
        }
    }
}

// MARK: Card

/// What the bars mean, on the welcome tour's chart page.
struct HustleLegend: View {
    @ObservedObject var themeStore = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Key(fill: Theme.accent, text: tr("Solid: work done while you were away"))
            Key(fill: Theme.accent.opacity(0.3), text: tr("Faint: work done while you were at the Mac"))
            Key(symbol: "cursorarrow", text: tr("Point at a bar to see that hour"))
        }
    }

    private struct Key: View {
        @ObservedObject var themeStore = ThemeStore.shared
        var fill: Color? = nil
        var symbol: String? = nil
        let text: String

        var body: some View {
            HStack(spacing: 8) {
                Group {
                    if let fill {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(fill).frame(width: 9, height: 14)
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.sub)
                    }
                }
                .frame(width: 14)
                .accessibilityHidden(true)
                Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Counts up each time the panel opens, so the chart can grow in again.
private struct PanelOpensKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var panelOpens: Int {
        get { self[PanelOpensKey.self] }
        set { self[PanelOpensKey.self] = newValue }
    }
}

struct HustleCard: View {
    @ObservedObject var themeStore = ThemeStore.shared
    @ObservedObject var store: HustleStore
    @State private var range: HustleRange = .day
    @State private var hovered: Int?
    /// True for still renders, which never appear; opening the panel grows the bars from zero.
    @State private var grown = true
    /// A job just finished: the count pops and this hour's bar flashes.
    @State private var cheer = 0
    @State private var flash = false
    @Environment(\.panelOpens) private var panelOpens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let chartHeight: CGFloat = 64

    @MainActor init(store: HustleStore? = nil) { self.store = store ?? .shared }

    var body: some View {
        // The minute is enough: the store publishes every 15 s at most.
        let now = Clock.now()
        let today = Hustle.today(store.buckets, now: now)
        let bars = Hustle.bars(store.buckets, range: range, now: now)
        VStack(alignment: .leading, spacing: 12) {
            header(level: HustleLevel(seconds: today.seconds))
            HStack(alignment: .top, spacing: 8) {
                Figure(value: Self.time(today.seconds), label: tr("agent time today"))
                Figure(value: "\(today.steps)", label: tr("steps"))
                Figure(value: "\(today.jobs)", label: tr("jobs done"), pop: cheer)
            }
            HStack(spacing: 6) {
                Chip(swatch: Theme.accent, symbol: nil,
                     text: tr("%@ while you were away", Self.time(today.away)) + (today.seconds >= 60 ? " · \(Int((today.awayShare * 100).rounded()))%" : ""),
                     color: Theme.text)
                Chip(swatch: nil, symbol: "hourglass",
                     text: tr("Waited for you %@", Self.time(today.waited)),
                     color: today.waited >= 60 ? Theme.waitText : Theme.sub)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(caption(bars))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(hovered == nil ? Theme.sub : Theme.text)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(Theme.hover, value: hovered)
                    Spacer(minLength: 4)
                    rangePicker
                }
                chart(bars)
                axis(bars)
            }
        }
        .padding(12)
        .cardBackground(radius: 12)
        .onChange(of: panelOpens) { grow() }
        .onChange(of: range) { grow() }
        .onChange(of: today.jobs) { old, new in
            guard new > old, !reduceMotion else { return }
            cheer += 1
            withAnimation(.easeOut(duration: 0.15)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { withAnimation(.easeOut(duration: 0.6)) { flash = false } }
        }
    }

    private func header(level: HustleLevel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill").font(.system(size: 12)).foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(tr("Agent hustle")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: level.symbol).font(.system(size: 9, weight: .bold))
                    .symbolEffect(.bounce, value: level)
                Text(level.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(level == .onFire ? Theme.onAccent : (level == .napping ? Theme.sub : Theme.text))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(level == .onFire ? Theme.accent : Theme.surfaceHover))
            .animation(Theme.smooth, value: level)
            .accessibilityElement(children: .combine)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(HustleRange.allCases, id: \.self) { option in
                let on = option == range
                Button {
                    Haptics.tap()
                    withAnimation(Theme.smooth) { range = option; hovered = nil }
                } label: {
                    Text(option == .day ? tr("24h") : tr("7d"))
                        .font(.system(size: 10, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.text : Theme.sub)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(on ? Theme.surfaceHover : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func chart(_ bars: [HustleBar]) -> some View {
        let peak = max(bars.map(\.total.seconds).max() ?? 0, 1)
        let peakID = bars.max { $0.total.seconds < $1.total.seconds }.flatMap { $0.total.seconds > 0 ? $0.id : nil }
        let last = bars.last?.id
        return HStack(alignment: .bottom, spacing: range == .day ? 3 : 6) {
            ForEach(bars) { bar in
                let fraction = bar.total.seconds / peak
                let dim = hovered != nil && hovered != bar.id
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.clear)
                    if bar.total.seconds > 0 {
                        // Faint: while you were here. Solid, from the bottom: while you were away.
                        let shape = RoundedRectangle(cornerRadius: range == .day ? 2.5 : 4, style: .continuous)
                        shape.fill(Theme.accent.opacity(0.3))
                            .overlay(alignment: .bottom) {
                                GeometryReader { box in
                                    LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                                        .frame(height: box.size.height * bar.total.awayShare)
                                        .frame(maxHeight: .infinity, alignment: .bottom)
                                }
                            }
                            .clipShape(shape)
                            .frame(height: max(4, Self.chartHeight * fraction))
                            .brightness(flash && bar.id == last ? 0.25 : 0)
                            .opacity(dim ? 0.3 : (bar.id == peakID || bar.id == hovered || (flash && bar.id == last) ? 1 : 0.78))
                            .shadow(color: Theme.accent.opacity(flash && bar.id == last ? 0.8 : (bar.id == peakID && !dim ? 0.45 : 0)),
                                    radius: flash && bar.id == last ? 10 : 6)
                    } else {
                        Capsule().fill(bar.id == last ? Theme.sub : Theme.line).frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.chartHeight)
                .scaleEffect(x: 1, y: grown || reduceMotion ? 1 : 0.02, anchor: .bottom)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7).delay(Double(bar.id) * (range == .day ? 0.014 : 0.04)), value: grown)
                .animation(Theme.hover, value: hovered)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hovered = bar.id } else if hovered == bar.id { hovered = nil }
                }
                .accessibilityElement()
                .accessibilityLabel(detail(bar))
            }
        }
        .frame(height: Self.chartHeight)
    }

    private func axis(_ bars: [HustleBar]) -> some View {
        HStack(spacing: 0) {
            switch range {
            case .day:
                ForEach([0, 6, 12, 18], id: \.self) { i in
                    Text(bars.indices.contains(i) ? Self.hourLabel(bars[i].start) : "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(tr("now"))
            case .week:
                ForEach(bars) { bar in
                    Text(Self.dayLabel(bar.start)).frame(maxWidth: .infinity)
                }
            }
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(Theme.faint)
        .lineLimit(1)
    }

    private func caption(_ bars: [HustleBar]) -> String {
        if let hovered, let bar = bars.first(where: { $0.id == hovered }) { return detail(bar) }
        if bars.allSatisfy({ $0.total.seconds == 0 && $0.total.steps == 0 }) { return tr("No agent work yet") }
        return range == .day ? tr("Last 24 hours") : tr("Last 7 days")
    }

    private func detail(_ bar: HustleBar) -> String {
        let when = range == .day ? Fmt.time(bar.start) : Self.dayLabel(bar.start)
        return tr("%@ · %@ · %@ away · %d steps", when, Self.time(bar.total.seconds), Self.time(bar.total.away), bar.total.steps)
    }

    private func grow() {
        guard !reduceMotion else { return }
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) { grown = false }
        DispatchQueue.main.async { grown = true }
    }

    static func time(_ seconds: Double) -> String {
        seconds < 60 ? tr("%dm", 0) : Fmt.compact(seconds)
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.isThai ? "th_TH" : "en_US")
        f.calendar = Calendar(identifier: .gregorian)
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static func hourLabel(_ date: Date) -> String {
        L10n.isThai ? formatter("HH").string(from: date) + ":00" : formatter("j").string(from: date)
    }

    static func dayLabel(_ date: Date) -> String { formatter("EEE").string(from: date) }

    private struct Chip: View {
        @ObservedObject var themeStore = ThemeStore.shared
        let swatch: Color?
        let symbol: String?
        let text: String
        let color: Color
        var body: some View {
            HStack(spacing: 5) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(swatch).frame(width: 7, height: 7)
                }
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                }
                Text(text).font(.system(size: 10.5).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .animation(Theme.smooth, value: text)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Theme.surfaceHover))
            .accessibilityElement(children: .combine)
        }
    }

    private struct Figure: View {
        @ObservedObject var themeStore = ThemeStore.shared
        let value: String
        let label: String
        var pop = 0
        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(Theme.smooth, value: value)
                    .keyframeAnimator(initialValue: 1.0, trigger: pop) { view, scale in
                        view.scaleEffect(scale, anchor: .bottomLeading)
                    } keyframes: { _ in
                        SpringKeyframe(1.3, duration: 0.18, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
                    }
                Text(label).font(.system(size: 10)).foregroundStyle(Theme.sub)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
