import AppKit

/// Headless checks for the parts that are pure logic: state aggregation and the
/// language switch. Run with `RexPet --selftest`; exit code 0 means all passed.
///
/// These exist because the interesting bugs in this app have all been about
/// *when* a state stops being true — a shell emits `idle` right after `done`,
/// several panes disagree, and a dropped stream must not leave the cat amber
/// forever. None of that needs a window on screen.
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    static func run() -> Int32 {
        stateMachine()
        language()
        print("\(checks - failures)/\(checks) checks passed")
        return failures == 0 ? 0 : 1
    }

    // MARK: - State aggregation

    private static func stateMachine() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let machine = PetStateMachine()

        // A shell reports done, then idle as it tears down. The check mark must survive.
        machine.reset()
        machine.apply(update(.working, "block:a"), now: start)
        machine.apply(update(.done, "block:a"), now: start + 1)
        machine.apply(update(.idle, "block:a"), now: start + 1.2)
        expect(machine.snapshot(now: start + 1.3).state == .done, "done survives an immediate idle")

        // ...but not forever.
        expect(machine.snapshot(now: start + 12).state == .idle, "done expires after its TTL")

        // A progress report from the same pane must not steal the check mark either.
        machine.reset()
        machine.apply(update(.done, "block:a"), now: start)
        machine.apply(update(.working, "block:a"), now: start + 0.5)
        expect(machine.snapshot(now: start + 0.6).state == .done, "working inside the quiet window does not override done")
        machine.apply(update(.working, "block:a"), now: start + 3)
        expect(machine.snapshot(now: start + 3.1).state == .working, "working applies once the quiet window passes")

        // Working alone expires: a pane that dies without saying goodbye.
        machine.reset()
        machine.apply(update(.working, "block:a"), now: start)
        expect(machine.snapshot(now: start + 5).state == .working, "working is visible while fresh")
        expect(machine.snapshot(now: start + 30).state == .idle, "working expires when nothing refreshes it")

        // Two panes disagree: the risky state wins, and it wins over recency.
        machine.reset()
        machine.apply(update(.working, "block:a"), now: start)
        machine.apply(update(.blocked, "block:b"), now: start + 1)
        machine.apply(update(.working, "block:a"), now: start + 5)
        let mixed = machine.snapshot(now: start + 6)
        expect(mixed.state == .blocked, "blocked outranks a newer working")
        expect(mixed.blockID == "block:b", "the snapshot names the pane that needs attention")

        // Error outranks done, done outranks working.
        machine.reset()
        machine.apply(update(.done, "block:a"), now: start)
        machine.apply(update(.error, "block:b"), now: start + 1)
        expect(machine.snapshot(now: start + 2).state == .error, "error outranks done")

        // A blocked pane that exits must not leave the cat red forever.
        machine.reset()
        machine.apply(update(.blocked, "block:a"), now: start)
        machine.apply(update(.idle, "block:a"), now: start + 1)
        expect(machine.snapshot(now: start + 2).state == .idle, "idle clears blocked")

        // An idle-only world is idle, and carries no pane.
        machine.reset()
        machine.apply(update(.idle, "block:a"), now: start)
        let empty = machine.snapshot(now: start + 1)
        expect(empty.state == .idle && empty.blockID == nil, "nothing running means idle with no block")
    }

    private static func update(_ state: PetState, _ blockID: String?) -> RexWatcher.Update {
        RexWatcher.Update(state: state, blockID: blockID, title: nil)
    }

    // MARK: - Language

    private static func language() {
        // Forced by the environment, which is what the screenshots rely on.
        let text = L10n.t("Allow (y)", "允许 (y)")
        if let forced = ProcessInfo.processInfo.environment["REX_PET_LANG"], !forced.isEmpty {
            let expected = forced.lowercased().hasPrefix("zh") ? "允许 (y)" : "Allow (y)"
            expect(text == expected, "REX_PET_LANG=\(forced) picks that language")
        } else {
            // Whatever the machine prefers, it has to be one of the two known strings.
            expect(text == "Allow (y)" || text == "允许 (y)", "an unforced language still resolves")
        }
    }

    // MARK: - Plumbing

    private static func expect(_ condition: Bool, _ what: String) {
        checks += 1
        if condition {
            print("ok   \(what)")
        } else {
            failures += 1
            print("FAIL \(what)")
        }
    }
}
