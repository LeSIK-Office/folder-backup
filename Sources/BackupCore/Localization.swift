import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, en, ko, ja, zh, es

    public var name: String {
        switch self {
        case .system: return L10n.text("System Language")
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        case .zh: return "简体中文"
        case .es: return "Español"
        }
    }
}

public enum L10n {
    public static let preferenceKey = "appLanguage"
    public static var selection: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
            prepareNativeLanguage()
        }
    }

    public static func resolve(_ selection: AppLanguage, preferredLanguages: [String]) -> AppLanguage {
        guard selection == .system else { return selection }
        let primary = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased() ?? "en"
        return AppLanguage(rawValue: primary).flatMap { $0 == .system ? nil : $0 } ?? .en
    }

    private static var systemLanguages: [String] {
        (UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String])
            ?? (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String])
            ?? Locale.preferredLanguages
    }
    public static var language: AppLanguage { resolve(selection, preferredLanguages: systemLanguages) }

    public static func prepareNativeLanguage() {
        // App-only preference: native macOS menus use this on the next launch.
        UserDefaults.standard.set([language == .zh ? "zh-Hans" : language.rawValue], forKey: "AppleLanguages")
    }
    public static var locale: Locale { Locale(identifier: language == .zh ? "zh-Hans" : language.rawValue) }
    public static var resources: Bundle {
        if let url = Bundle.main.url(forResource: "FolderBackup_BackupCore", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return .module
    }

    public static func text(_ key: String, _ arguments: CustomStringConvertible...) -> String {
        format(key, arguments: arguments.map(\.description))
    }

    private static func format(_ key: String, arguments: [String]) -> String {
        let path = resources.path(forResource: language == .zh ? "zh-hans" : language.rawValue, ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:)) ?? resources
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return String(format: format, locale: locale, arguments: arguments)
    }

    private static let recordedTemplates: [(key: String, value: String)] = {
        ["en", "ko", "ja", "zh-Hans", "es"].flatMap { language -> [(key: String, value: String)] in
            guard let url = resources.url(forResource: "Localizable", withExtension: "strings", subdirectory: language + ".lproj"),
                  let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [] }
            return values.map { (key: $0.key, value: $0.value) }
        }.sorted { $0.value.count > $1.value.count }
    }()

    // Translate known recorded messages without changing stored records or user paths.
    public static func message(_ value: String) -> String {
        knownMessage(value) ?? value
    }

    private static func knownMessage(_ value: String) -> String? {
        for entry in recordedTemplates {
            if value == entry.value { return text(entry.key) }
            let parts = entry.value.components(separatedBy: "%@")
            if parts.count == 1 {
                if (entry.value.hasSuffix(": ") || entry.value.hasSuffix(" · ")) && value.hasPrefix(entry.value) {
                    return text(entry.key) + value.dropFirst(entry.value.count)
                }
                continue
            }
            guard value.hasPrefix(parts.first!), value.hasSuffix(parts.last!) else { continue }
            let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { continue }
            let arguments = (1..<match.numberOfRanges).map { String(value[Range(match.range(at: $0), in: value)!]) }
            return format(entry.key, arguments: arguments)
        }
        for separator in ["\n", " · "] where value.contains(separator) {
            let parts = value.components(separatedBy: separator).map(knownMessage)
            if parts.allSatisfy({ $0 != nil }) { return parts.compactMap { $0 }.joined(separator: separator) }
        }
        return nil
    }

    public static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    public static func bytes(_ value: Int64) -> String {
        value.formatted(ByteCountFormatStyle(style: .file, locale: locale))
    }
}
