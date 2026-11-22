import SwiftUI

enum PulseTheme: String, CaseIterable {
    case `default`, grayscale
    static let storageKey = "pulseTheme"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .default
    }
    var title: String { self == .default ? L10n.text("默认") : L10n.text("灰阶") }
    var accent: Color { self == .default ? Color("AccentColor") : Color(red: 0.16, green: 0.65, blue: 0.60) }
    var ink: Color { self == .default ? .mint : Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .init(white: 0.78, alpha: 1) : .init(white: 0.28, alpha: 1) }) }
    var secondaryInk: Color { self == .default ? .cyan : .gray }
    var warning: Color { self == .default ? .orange : Color(red: 0.77, green: 0.50, blue: 0.15) }
    var critical: Color { self == .default ? .red : Color(red: 0.80, green: 0.29, blue: 0.29) }
    var surface: Color { self == .default ? Color(uiColor: .secondarySystemGroupedBackground) : Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .init(white: 0.115, alpha: 1) : .white }) }
    var background: Color { self == .default ? Color(uiColor: .systemGroupedBackground) : Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .init(white: 0.045, alpha: 1) : .init(white: 0.95, alpha: 1) }) }
    func gauge(_ value: Double) -> Color { value < 60 ? ink : value < 85 ? warning : critical }
}

private struct PulseThemeKey: EnvironmentKey {
    static let defaultValue = PulseTheme.default
}
extension EnvironmentValues {
    var pulseTheme: PulseTheme {
        get { self[PulseThemeKey.self] }
        set { self[PulseThemeKey.self] = newValue }
    }
}

struct PulsePanel: ViewModifier {
    @Environment(\.pulseTheme) private var theme
    func body(content: Content) -> some View {
        content.padding(20).background(theme.surface, in: RoundedRectangle(cornerRadius: 26))
    }
}
