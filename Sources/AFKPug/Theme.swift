import SwiftUI
import AppKit

/// An sRGB color that can be stored as a hex string and measured for contrast.
struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    init?(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    var hex: String {
        let byte = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    /// WCAG relative luminance.
    var luminance: Double {
        let linear = { (v: Double) in v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// A point on the color pad: hue runs left to right, white at the top, black at the bottom.
    static func pad(x: Double, y: Double) -> RGB {
        let h = x * 6
        let channel = { (offset: Double) in min(max(abs((h + offset).truncatingRemainder(dividingBy: 6) - 3) - 1, 0), 1) }
        let (r, g, b) = (channel(0), channel(4), channel(2))
        let mix = { (v: Double) in y < 0.5 ? 1 + (v - 1) * y * 2 : v * (1 - y) * 2 }
        return RGB(mix(r), mix(g), mix(b))
    }

    /// Where this color sits on the pad, or the closest point for a grayer color.
    var padPosition: (x: Double, y: Double) {
        let (high, low) = (max(r, g, b), min(r, g, b))
        let range = high - low
        var hue = 0.0
        if range > 0 {
            if high == r { hue = (g - b) / range } else if high == g { hue = (b - r) / range + 2 } else { hue = (r - g) / range + 4 }
            if hue < 0 { hue += 6 }
        }
        return (hue / 6, 0.5 - low / 2 + (1 - high) / 2)
    }

    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color at `amount` opacity on top of `base`.
    func over(_ base: RGB, amount: Double) -> RGB {
        RGB(base.r + (r - base.r) * amount, base.g + (g - base.g) * amount, base.b + (b - base.b) * amount)
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return tr("Match Mac")
        case .light: return tr("White")
        case .dark: return tr("Black")
        case .custom: return tr("Custom")
        }
    }
}

/// Every color the UI draws with, derived from a background and an accent. Text
/// is raised until it's legible, so no choice of colors can make the app unreadable.
struct ThemePalette {
    let background: RGB
    let accentRGB: RGB
    let isDark: Bool
    let ink: Color, onInk: Color, onAccent: Color, knobOff: Color
    let textRGB: RGB, subRGB: RGB, faintRGB: RGB, warnRGB: RGB, liveRGB: RGB, waitRGB: RGB, liveTextRGB: RGB, waitTextRGB: RGB

    static let dark = RGB(0.055, 0.055, 0.063)
    static let brand = RGB(0.98, 0.63, 0.35)
    static let defaultAccent = RGB(1, 1, 1)
    /// Minimum contrast for small text (WCAG AA).
    static let textContrast = 4.5
    /// Minimum contrast for dots and for the accent against the background.
    static let markContrast = 1.6

    init(background: RGB, accent: RGB) {
        self.background = background
        isDark = background.luminance < 0.179
        // Soft black, or pure black on mid tones where that's what it takes to stay legible.
        let softBlack = RGB(0.07, 0.07, 0.09)
        let inkRGB = isDark ? RGB(1, 1, 1) : (softBlack.contrast(with: background) >= Self.textContrast ? softBlack : RGB(0, 0, 0))

        /// The lowest opacity from `start` up that reaches `target`.
        func raised(from start: Double, target: Double) -> RGB {
            var amount = start
            while amount < 1, inkRGB.over(background, amount: amount).contrast(with: background) < target { amount += 0.01 }
            return inkRGB.over(background, amount: min(amount, 1))
        }
        /// `color`, moved toward the ink only as far as `target` needs.
        func legible(_ color: RGB, target: Double) -> RGB {
            var amount = 0.0
            while amount < 1, inkRGB.over(color, amount: amount).contrast(with: background) < target { amount += 0.02 }
            return inkRGB.over(color, amount: min(amount, 1))
        }

        ink = inkRGB.color
        onInk = isDark ? .black : .white
        knobOff = isDark ? Color.white.opacity(0.75) : .white
        textRGB = raised(from: 0.94, target: Self.textContrast)
        subRGB = raised(from: isDark ? 0.50 : 0.60, target: Self.textContrast)
        faintRGB = raised(from: isDark ? 0.47 : 0.58, target: Self.textContrast)
        warnRGB = legible(RGB(0.93, 0.36, 0.33), target: Self.textContrast)
        liveRGB = legible(RGB(0.40, 0.85, 0.56), target: Self.markContrast)
        waitRGB = legible(RGB(0.96, 0.76, 0.30), target: Self.markContrast)
        liveTextRGB = legible(RGB(0.40, 0.85, 0.56), target: Self.textContrast)
        waitTextRGB = legible(RGB(0.96, 0.76, 0.30), target: Self.textContrast)
        accentRGB = legible(accent, target: Self.markContrast)
        onAccent = accentRGB.contrast(with: RGB(0, 0, 0)) >= accentRGB.contrast(with: RGB(1, 1, 1)) ? Color.black.opacity(0.85) : .white
    }
}

/// The current colors. Views read these statics and observe `ThemeStore`, which
/// redraws them when the colors change.
enum Theme {
    nonisolated(unsafe) static var palette = ThemeStore.loadPalette()

    static var bg: Color { palette.background.color }
    static var ink: Color { palette.ink }
    /// Text and icons on a fill of `ink`.
    static var onInk: Color { palette.onInk }
    static var surface: Color { ink.opacity(palette.isDark ? 0.045 : 0.05) }
    static var surfaceHover: Color { ink.opacity(palette.isDark ? 0.08 : 0.09) }
    static var line: Color { ink.opacity(palette.isDark ? 0.07 : 0.10) }
    static var text: Color { palette.textRGB.color }
    static var sub: Color { palette.subRGB.color }
    /// Idle headline.
    static var faint: Color { palette.faintRGB.color }
    static var accent: Color { palette.accentRGB.color }
    static var onAccent: Color { palette.onAccent }
    static var trackOff: Color { ink.opacity(0.14) }
    static var knobOff: Color { palette.knobOff }
    static var live: Color { palette.liveRGB.color }
    /// An agent paused on its usage limit: still held, not working.
    static var wait: Color { palette.waitRGB.color }
    static var warn: Color { palette.warnRGB.color }
    /// `live` and `wait` for words: dots only need to be seen, text has to be read.
    static var liveText: Color { palette.liveTextRGB.color }
    static var waitText: Color { palette.waitTextRGB.color }
    static var scheme: ColorScheme { palette.isDark ? .dark : .light }

    /// Page slide and segmented selection.
    static let smooth = Animation.smooth(duration: 0.3)
    /// Gentle crossfade for state changes (colors, text swaps).
    static let fade = Animation.easeInOut(duration: 0.2)
    /// Hover feedback.
    static let hover = Animation.easeOut(duration: 0.12)
}

/// A quiet card or tile: Liquid Glass on macOS 26, a flat fill before that and in
/// PNG previews, which can't draw glass. The glass sits on the app's solid
/// background, so text keeps the contrast the palette guarantees.
struct CardBackground: ViewModifier {
    @ObservedObject var themeStore = ThemeStore.shared
    let radius: CGFloat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !Sim.enabled {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            flat(content)
        }
        #else
        flat(content)
        #endif
    }

    private func flat(_ content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surface))
    }
}

extension View {
    func cardBackground(radius: CGFloat = 12) -> some View { modifier(CardBackground(radius: radius)) }
}

/// A light tap on Force Touch trackpads, for controls that change state.
enum Haptics {
    static func tap() {
        guard !Sim.enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

/// The user's appearance choices. Black and white are the defaults.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    static let accents: [(name: String, hex: String)] = [
        ("White", ThemePalette.defaultAccent.hex), ("Orange", ThemePalette.brand.hex), ("Blue", "#4C9AFF"),
        ("Green", "#3CCB7F"), ("Pink", "#F472B6"), ("Purple", "#A78BFA"),
    ]

    /// Backgrounds offered beside white and black.
    static let backgrounds: [(name: String, hex: String)] = [
        ("Navy", "#1B2A4A"), ("Forest", "#17332B"), ("Plum", "#2E1F3D"),
    ]

    @Published var mode: AppearanceMode { didSet { save() } }
    @Published var accentHex: String { didSet { save() } }
    @Published var backgroundHex: String { didSet { save() } }

    private init() {
        mode = Self.storedMode
        accentHex = Self.storedAccent.hex
        backgroundHex = Self.storedBackground.hex
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeStore.shared.apply() }
        }
    }

    var backgroundName: String {
        guard mode == .custom else { return mode.label }
        return Self.backgrounds.first { $0.hex == backgroundHex }.map { tr($0.name) } ?? mode.label
    }

    func pickBackground(hex: String) {
        backgroundHex = hex
        mode = .custom
    }

    private func save() {
        Engine.store.set(mode.rawValue, forKey: "appearance")
        Engine.store.set(accentHex, forKey: "accentColor")
        Engine.store.set(backgroundHex, forKey: "backgroundColor")
        apply()
    }

    private func apply() {
        objectWillChange.send()
        Theme.palette = Self.loadPalette()
        OnboardingWindow.shared.applyTheme()
    }

    nonisolated private static var storedMode: AppearanceMode {
        AppearanceMode(rawValue: Engine.store.string(forKey: "appearance") ?? "") ?? .dark
    }
    nonisolated private static var storedAccent: RGB {
        RGB(hex: Engine.store.string(forKey: "accentColor") ?? "") ?? ThemePalette.defaultAccent
    }
    nonisolated private static var storedBackground: RGB {
        RGB(hex: Engine.store.string(forKey: "backgroundColor") ?? "") ?? RGB(0.11, 0.13, 0.20)
    }

    nonisolated static func loadPalette() -> ThemePalette {
        let background: RGB
        switch storedMode {
        case .system: background = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? ThemePalette.dark : RGB(1, 1, 1)
        case .light: background = RGB(1, 1, 1)
        case .dark: background = ThemePalette.dark
        case .custom: background = storedBackground
        }
        return ThemePalette(background: background, accent: storedAccent)
    }
}

/// Settings rows: pick a background and an accent right in the window.
struct AppearanceRows: View {
    private enum Editing { case background, accent }

    @ObservedObject var store = ThemeStore.shared
    @State private var editing: Editing?

    var body: some View {
        Row(symbol: "circle.lefthalf.filled", title: tr("Background"), detail: store.backgroundName) { EmptyView() }
        HStack(spacing: 9) {
            Swatch(label: tr("Match Mac"), selected: store.mode == .system, action: { pick(.system) }) {
                Circle().fill(LinearGradient(stops: [.init(color: .white, location: 0.5), .init(color: .black, location: 0.5)],
                                             startPoint: .leading, endPoint: .trailing))
            }
            Swatch(label: tr("White"), selected: store.mode == .light, action: { pick(.light) }) { Circle().fill(.white) }
            Swatch(label: tr("Black"), selected: store.mode == .dark, action: { pick(.dark) }) { Circle().fill(ThemePalette.dark.color) }
            ForEach(ThemeStore.backgrounds, id: \.hex) { preset in
                Swatch(label: tr(preset.name), selected: store.mode == .custom && store.backgroundHex == preset.hex, action: {
                    editing = nil
                    store.pickBackground(hex: preset.hex)
                }) { Circle().fill(RGB(hex: preset.hex)?.color ?? .clear) }
            }
            CustomSwatch(label: tr("Background color"), hex: store.backgroundHex,
                         chosen: store.mode == .custom && !ThemeStore.backgrounds.contains { $0.hex == store.backgroundHex },
                         open: editing == .background) {
                editing = editing == .background ? nil : .background
                if editing != nil { store.pickBackground(hex: store.backgroundHex) }
            }
        }
        .padding(.leading, 30)
        if editing == .background {
            ColorEditor(label: tr("Background color"), hex: $store.backgroundHex).padding(.leading, 30)
        }

        Row(symbol: "paintpalette", title: tr("Accent color"), detail: tr("Switches and the app mark")) { EmptyView() }
        HStack(spacing: 9) {
            ForEach(ThemeStore.accents, id: \.hex) { accent in
                Swatch(label: tr(accent.name), selected: store.accentHex == accent.hex, action: {
                    editing = nil
                    store.accentHex = accent.hex
                }) { Circle().fill(RGB(hex: accent.hex)?.color ?? .clear) }
            }
            CustomSwatch(label: tr("Custom accent color"), hex: store.accentHex,
                         chosen: !ThemeStore.accents.contains { $0.hex == store.accentHex },
                         open: editing == .accent) {
                editing = editing == .accent ? nil : .accent
            }
        }
        .padding(.leading, 30)
        if editing == .accent {
            ColorEditor(label: tr("Custom accent color"), hex: $store.accentHex).padding(.leading, 30)
        }
    }

    private func pick(_ mode: AppearanceMode) {
        editing = nil
        store.mode = mode
    }
}

/// One round choice. The ring marks what's selected, and the hairline keeps a
/// swatch visible on a background of the same color.
private struct Swatch<Fill: View>: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let fill: () -> Fill

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            fill()
                .overlay(Circle().stroke(Theme.ink.opacity(0.25), lineWidth: 0.5))
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().stroke(selected ? Theme.text : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The rainbow swatch that opens the color editor, showing the color once one is chosen.
private struct CustomSwatch: View {
    let label: String
    let hex: String
    let chosen: Bool
    let open: Bool
    let action: () -> Void

    private static let rainbow = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { RGB.pad(x: $0, y: 0.5).color }

    var body: some View {
        Swatch(label: label, selected: chosen || open, action: action) {
            ZStack {
                Circle().fill(AngularGradient(colors: Self.rainbow, center: .center))
                if chosen { Circle().fill(RGB(hex: hex)?.color ?? .clear).padding(4) }
            }
        }
    }
}

/// Drag anywhere on the pad, or type a hex code for an exact color.
private struct ColorEditor: View {
    let label: String
    @Binding var hex: String
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pad
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(RGB(hex: hex)?.color ?? .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.ink.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 22, height: 22)
                TextField(label, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .labelsHidden()
                    .frame(width: 86)
                    .onChange(of: typed) { _, text in
                        let code = text.trimmingCharacters(in: .whitespaces)
                        if let rgb = RGB(hex: code), rgb.hex != hex { hex = rgb.hex }
                    }
            }
        }
        .onAppear { typed = hex }
        .onChange(of: hex) { _, value in
            if RGB(hex: typed)?.hex != value { typed = value }
        }
    }

    private var pad: some View {
        GeometryReader { geo in
            let position = (RGB(hex: hex) ?? ThemePalette.brand).padPosition
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { RGB.pad(x: $0, y: 0.5).color },
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white.opacity(0), location: 0.5),
                                       .init(color: .black.opacity(0), location: 0.5), .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                Circle()
                    .stroke(.white, lineWidth: 2)
                    .background(Circle().stroke(.black.opacity(0.45), lineWidth: 3))
                    .frame(width: 12, height: 12)
                    .position(x: position.x * geo.size.width, y: position.y * geo.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                // Kept just inside the edges, where a color still has a hue for the marker to follow.
                let x = min(max(drag.location.x / geo.size.width, 0), 0.99)
                let y = min(max(drag.location.y / geo.size.height, 0.03), 0.97)
                hex = RGB.pad(x: x, y: y).hex
            })
        }
        .frame(height: 96)
        // The hex field is the way to reach this with VoiceOver or the keyboard.
        .accessibilityHidden(true)
    }
}
