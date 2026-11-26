import Foundation

/// The app speaks English unless the system asks for Chinese. Two languages do
/// not justify a .strings pipeline, so the English text stays in the call site
/// and Chinese lives beside it.
enum L10n {
    /// `REX_PET_LANG=zh` / `REX_PET_LANG=en` overrides the system choice, which
    /// keeps screenshots and manual checks deterministic.
    static let isChinese: Bool = {
        if let forced = ProcessInfo.processInfo.environment["REX_PET_LANG"], !forced.isEmpty {
            return forced.lowercased().hasPrefix("zh")
        }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }()

    static func t(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }
}
