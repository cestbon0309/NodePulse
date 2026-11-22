import Foundation

enum L10n {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: nil, table: "Localizable")
        return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
    }
}
