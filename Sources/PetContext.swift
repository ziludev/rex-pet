import AppKit

/// State plus the pane the pet is currently surfacing.
/// Written by the feeder as JSON; the plain-text state file still works alone.
struct PetContext {
    var state: PetState = .idle
    var blockID: String?
    var title: String?

    static let statePath = ("~/.cache/rex-pet/state" as NSString).expandingTildeInPath
    static let contextPath = ("~/.cache/rex-pet/context.json" as NSString).expandingTildeInPath

    static func load() -> PetContext {
        if let context = loadJSON() { return context }
        if let raw = try? String(contentsOfFile: statePath, encoding: .utf8),
           let state = PetState(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return PetContext(state: state)
        }
        return PetContext()
    }

    private static func loadJSON() -> PetContext? {
        guard let data = FileManager.default.contents(atPath: contextPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var context = PetContext()
        if let raw = object["state"] as? String, let state = PetState(rawValue: raw.lowercased()) {
            context.state = state
        } else {
            return nil
        }
        context.blockID = (object["block"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        context.title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return context
    }

    var shortBlock: String {
        guard let blockID else { return "" }
        return blockID.count > 14 ? String(blockID.suffix(10)) : blockID
    }
}
