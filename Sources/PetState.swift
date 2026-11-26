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
        case .idle: return "空闲"
        case .working: return "工作中"
        case .blocked: return "等你确认"
        case .done: return "完成"
        case .error: return "出错了"
        }
    }
}
