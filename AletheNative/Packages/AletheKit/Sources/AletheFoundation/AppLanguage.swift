import Foundation

/// The interface language. macOS picks an app's localization at launch from its `AppleLanguages`
/// default — the same key System Settings › Language & Region › Applications writes — so a change
/// applies on the next launch.
public enum AppLanguage: String, CaseIterable, Sendable {
    /// Follow the system's preferred languages.
    case system
    case english = "en"
    case portugueseBrazil = "pt-BR"

    /// The language's own name; not translated, so it is recognizable from any interface language.
    public var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .portugueseBrazil: "Português (Brasil)"
        }
    }
}

/// Reads and writes the app's own `AppleLanguages` (its persistent domain, not the argument or
/// global domains, which a launch argument or the system would otherwise report).
public struct LanguageSetting: Sendable {
    public static let key = "AppleLanguages"
    public let domain: String

    public init(domain: String = AppIdentity.bundleIdentifier) {
        self.domain = domain
    }

    public func current(in defaults: UserDefaults = .standard) -> AppLanguage {
        let stored = defaults.persistentDomain(forName: domain)?[Self.key] as? [String]
        guard let first = stored?.first else { return .system }
        return AppLanguage.allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    public func set(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        var values = defaults.persistentDomain(forName: domain) ?? [:]
        if language == .system {
            values.removeValue(forKey: Self.key)
        } else {
            values[Self.key] = [language.rawValue]
        }
        defaults.setPersistentDomain(values, forName: domain)
    }

    /// Launch arguments for a relaunch that should pick up the stored language: drops
    /// `-AppleLanguages` / `-AppleLocale` overrides (and their values), keeps everything else.
    public static func relaunchArguments(_ arguments: [String]) -> [String] {
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == "-AppleLanguages" || arguments[index] == "-AppleLocale" {
                index += 2
                continue
            }
            kept.append(arguments[index])
            index += 1
        }
        return kept
    }
}
