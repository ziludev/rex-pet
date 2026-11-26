import AppKit

/// Mirror of the rex-beacon OSC 7501 / daemon state vocabulary.
enum PetState: String, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case error

    var label: String {
        switch self {
        case .idle: return L10n.t("idle", "空闲")
        case .working: return L10n.t("working", "工作中")
        case .blocked: return L10n.t("needs you", "等你确认")
        case .done: return L10n.t("done", "完成")
        case .error: return L10n.t("error", "出错了")
        }
    }
}
