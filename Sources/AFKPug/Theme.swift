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
    let textRGB: RGB, subRGB: RGB, faintRGB: RGB, warnRGB: RGB, liveRGB: RGB, waitRGB: RGB

    static let dark = RGB(0.055, 0.055, 0.063)
    static let brand = RGB(0.98, 0.63, 0.35)
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

/// The user's appearance choices. Black and orange are the defaults.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    static let accents: [(name: String, hex: String)] = [
        ("Orange", ThemePalette.brand.hex), ("Blue", "#4C9AFF"), ("Green", "#3CCB7F"),
        ("Pink", "#F472B6"), ("Purple", "#A78BFA"), ("Red", "#F87171"),
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

    var accent: Binding<Color> { hexBinding(\.accentHex) }
    var background: Binding<Color> { hexBinding(\.backgroundHex) }

    private func hexBinding(_ path: ReferenceWritableKeyPath<ThemeStore, String>) -> Binding<Color> {
        Binding(get: { RGB(hex: self[keyPath: path])?.color ?? .clear },
                set: { color in
                    if let rgb = RGB(color), rgb.hex != self[keyPath: path] { self[keyPath: path] = rgb.hex }
                })
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
        RGB(hex: Engine.store.string(forKey: "accentColor") ?? "") ?? ThemePalette.brand
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

/// Settings rows: background and accent.
struct AppearanceRows: View {
    @ObservedObject var store = ThemeStore.shared

    var body: some View {
        Row(symbol: "circle.lefthalf.filled", title: tr("Background"), detail: "") {
            if store.mode == .custom {
                ColorPicker(tr("Background color"), selection: store.background, supportsOpacity: false).labelsHidden().frame(width: 36)
            }
            Picker(tr("Background"), selection: $store.mode) {
                ForEach(AppearanceMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .labelsHidden().frame(width: 100)
        }
        Row(symbol: "paintpalette", title: tr("Accent color"), detail: tr("Switches and the app mark")) { EmptyView() }
        HStack(spacing: 9) {
            ForEach(ThemeStore.accents, id: \.hex) { accent in
                Button {
                    Haptics.tap()
                    store.accentHex = accent.hex
                } label: {
                    Circle()
                        .fill(RGB(hex: accent.hex)?.color ?? .clear)
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay(Circle().stroke(store.accentHex == accent.hex ? Theme.text : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(accent.name))
                .accessibilityAddTraits(store.accentHex == accent.hex ? .isSelected : [])
            }
            Spacer(minLength: 0)
            ColorPicker(tr("Custom accent color"), selection: store.accent, supportsOpacity: false).labelsHidden().frame(width: 36)
        }
        .padding(.leading, 30)
    }
}
