import AppKit

/// Aggregates per-block activity into the single state the pet shows.
///
/// Several panes can be busy at once, so the last event cannot simply win: the
/// last `done` would be overwritten by an unrelated `progress_report` from another
/// pane one frame later. Entries are kept per block and merged by priority:
///
///     blocked > error > done > working
///
/// `done`/`error` stay visible for `stickyTTL` so the transition is noticeable,
/// and `working` expires when nothing refreshes it (a pane that exits without a
/// child_exited, or a dropped stream).
final class PetStateMachine {
    struct Snapshot {
        let state: PetState
        let blockID: String?
        let title: String?
    }

    private struct Entry {
        var state: PetState
        var updatedAt: Date
        var title: String?
    }

    private var entries: [String: Entry] = [:]
    private let stickyTTL: TimeInterval = 8
    private let workingTTL: TimeInterval = 15
    private let quietWindow: TimeInterval = 1.5
    private let unknownKey = "block:unknown"

    private static let priority: [PetState: Int] = [.blocked: 3, .error: 2, .done: 1, .working: 0, .idle: -1]

    func apply(_ update: RexWatcher.Update, now: Date = Date()) {
        let key = update.blockID ?? unknownKey

        if let title = update.title {
            entries[key]?.title = title
        }

        switch update.state {
        case .idle:
            // Shells emit `idle` right after `child_exited`; dropping the entry here
            // would erase the check mark before anyone sees it, so `done`/`error`
            // is left to expire on its own TTL. Anything else means the pane stopped:
            // a `blocked` pane that no longer exists would leave the cat red forever.
            switch entries[key]?.state {
            case .working, .blocked: entries[key] = nil
            default: break
            }
            return

        case .working:
            // A command that just reported done keeps the check mark for a moment:
            // shells keep emitting progress reports while they tear down.
            if let existing = entries[key], existing.state != .working,
               now.timeIntervalSince(existing.updatedAt) < quietWindow {
                return
            }
            entries[key] = Entry(state: .working, updatedAt: now, title: update.title ?? entries[key]?.title)

        case .blocked, .done, .error:
            entries[key] = Entry(state: update.state, updatedAt: now, title: update.title ?? entries[key]?.title)
        }
    }

    func snapshot(now: Date = Date()) -> Snapshot {
        prune(now: now)
        let best = entries
            .filter { $1.state != .idle }
            .max { lhs, rhs in
                let lp = Self.priority[lhs.value.state] ?? 0
                let rp = Self.priority[rhs.value.state] ?? 0
                if lp != rp { return lp < rp }
                return lhs.value.updatedAt < rhs.value.updatedAt
            }
        guard let best else { return Snapshot(state: .idle, blockID: nil, title: nil) }
        return Snapshot(state: best.value.state,
                        blockID: best.key == unknownKey ? nil : best.key,
                        title: best.value.title)
    }

    func reset() {
        entries.removeAll()
    }

    private func prune(now: Date) {
        for (key, entry) in entries {
            let age = now.timeIntervalSince(entry.updatedAt)
            switch entry.state {
            case .done, .error:
                if age >= stickyTTL { entries[key] = nil }
            case .working:
                if age >= workingTTL { entries[key] = nil }
            default:
                break
            }
        }
    }
}
