import AppKit

/// Headless checks for the parts that are pure logic: state aggregation, event
/// parsing, asset priority, reply placement, and the language switch.
/// Run with `RexPet --selftest`; exit code 0 means all passed.
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    static func run() -> Int32 {
        stateMachine()
        watcherParsing()
        assetResolution()
        replyPlacement()
        replies()
        uiHelpers()
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

        // Error also survives immediate idle and expires after stickyTTL.
        machine.reset()
        machine.apply(update(.error, "block:a"), now: start)
        machine.apply(update(.idle, "block:a"), now: start + 0.2)
        expect(machine.snapshot(now: start + 0.3).state == .error, "error survives an immediate idle")
        expect(machine.snapshot(now: start + 9).state == .idle, "error expires after its TTL")

        // A progress report from the same pane must not steal the check mark either.
        machine.reset()
        machine.apply(update(.done, "block:a"), now: start)
        machine.apply(update(.working, "block:a"), now: start + 0.5)
        expect(machine.snapshot(now: start + 0.6).state == .done, "working inside the quiet window does not override done")
        machine.apply(update(.working, "block:a"), now: start + 3)
        expect(machine.snapshot(now: start + 3.1).state == .working, "working applies once the quiet window passes")

        // Answering a blocked pane must switch back to working immediately, even inside quietWindow.
        machine.reset()
        machine.apply(update(.blocked, "block:a"), now: start)
        machine.apply(update(.working, "block:a"), now: start + 0.4)
        expect(machine.snapshot(now: start + 0.5).state == .working, "blocked switches to working immediately without waiting for quiet window")

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
        expect(mixed.blockedCount == 1, "single blocked pane reports count 1")

        // Multiple blocked panes are tracked and ordered newest first.
        machine.apply(update(.blocked, "block:c"), now: start + 7)
        let multi = machine.snapshot(now: start + 8)
        expect(multi.blockedCount == 2 && multi.blockedPanes.map(\.blockID) == ["block:c", "block:b"],
               "multiple blocked panes are tracked newest-first")
        machine.apply(update(.idle, "block:c"), now: start + 9)
        expect(machine.snapshot(now: start + 9.1).blockedCount == 1, "clearing one blocked pane drops count to 1")

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

    // MARK: - Event parsing

    private static func watcherParsing() {
        func line(_ obj: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        }
        func blockEvent(name: String, blockID: String = "block:1", creator: String = "com.superlogical.terminal", payload: [String: Any]) -> Data {
            line([
                "type": "session_event",
                "payload": [
                    "event": [
                        "type": "block_event",
                        "payload": [
                            "block_id": blockID,
                            "creator_name": creator,
                            "name": name,
                            "payload": payload,
                        ],
                    ],
                ],
            ])
        }

        let prog = RexWatcher.parse(line: blockEvent(name: "progress_report", payload: ["state": "running", "title": ""]))
        expect(prog?.state == .working && prog?.blockID == "block:1" && prog?.title == nil,
               "progress_report normalizes empty title and maps running to working")

        let waiting = RexWatcher.parse(line: blockEvent(name: "progress_report", payload: ["state": "waiting_input", "title": "codex"]))
        expect(waiting?.state == .blocked && waiting?.title == "codex",
               "progress_report maps waiting to blocked and keeps title")

        let status = RexWatcher.parse(line: blockEvent(name: "program_status_changed", payload: ["record": ["state": "done", "msg": "ok"]]))
        expect(status?.state == .done && status?.title == "ok",
               "program_status_changed reads state and msg fallback")

        let bell = RexWatcher.parse(line: blockEvent(name: "bell", payload: [:]))
        expect(bell?.state == .blocked && bell?.blockID == "block:1",
               "bell maps to blocked")

        let exitErr = RexWatcher.parse(line: blockEvent(name: "child_exited", payload: ["exit_code": 2]))
        expect(exitErr?.state == .error, "non-zero child_exited maps to error")

        let nonTerm = RexWatcher.parse(line: blockEvent(name: "bell", creator: "com.example.other", payload: [:]))
        expect(nonTerm == nil, "non-terminal creator events are ignored")

        let closed = RexWatcher.parse(line: line([
            "type": "session_event",
            "payload": ["event": ["type": "block_closed", "payload": ["block_id": "block:9"]]],
        ]))
        expect(closed?.state == .idle && closed?.blockID == "block:9", "block_closed clears pane to idle")

        expect(RexWatcher.parse(line: Data("not-json".utf8)) == nil, "malformed event line is safely ignored")
    }

    // MARK: - Asset resolution

    private static func assetResolution() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("rex-pet-selftest-\(UUID().uuidString)")
        let userRoot = tmp.appendingPathComponent("user")
        let bundledRoot = tmp.appendingPathComponent("bundled")
        defer { try? fm.removeItem(at: tmp) }

        do {
            try fm.createDirectory(at: userRoot.appendingPathComponent("idle"), withIntermediateDirectories: true)
            try fm.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
            try Data().write(to: userRoot.appendingPathComponent("idle/001.png"))
            try Data().write(to: bundledRoot.appendingPathComponent("idle.mov"))

            // User PNG folder must beat bundled .mov.
            let res1 = PetView.resolveAsset(for: .idle, in: [userRoot, bundledRoot])
            if case .frames(let dir, _) = res1 {
                expect(dir.standardizedFileURL == userRoot.appendingPathComponent("idle").standardizedFileURL,
                       "user PNG directory takes precedence over bundled mov")
            } else {
                expect(false, "user PNG directory takes precedence over bundled mov")
            }

            // Within the same root, .mov beats PNG folder.
            let userMov = userRoot.appendingPathComponent("idle.mov")
            try Data().write(to: userMov)
            let res2 = PetView.resolveAsset(for: .idle, in: [userRoot, bundledRoot])
            if case .movie(let url, _) = res2 {
                expect(url.standardizedFileURL == userMov.standardizedFileURL,
                       "mov beats PNG folder within the same root")
            } else {
                expect(false, "mov beats PNG folder within the same root")
            }

            // A failed .mov falls back to PNG frames in the same root instead of staying stuck.
            let res3 = PetView.resolveAsset(for: .idle, in: [userRoot, bundledRoot], failedMovies: [userMov])
            if case .frames = res3 {
                expect(true, "failed mov falls back to PNG frames")
            } else {
                expect(false, "failed mov falls back to PNG frames")
            }

            // Missing state resolves to vector fallback.
            let res4 = PetView.resolveAsset(for: .error, in: [userRoot, bundledRoot])
            expect(res4 == .vector, "missing asset falls back to vector cat")

            // Default theme checks only user Assets/ so empty user folder falls back to built-in Cat.
            let defaultRoots = PetView.assetRoots(forTheme: PetView.defaultThemeID, appSupport: tmp, bundleResources: bundledRoot)
            expect(defaultRoots.count == 1 && defaultRoots[0].path.hasSuffix("/Assets"),
                   "default theme checks user Assets only and falls back to built-in cat")

            // Whale Girl theme resolves explicitly to bundled Assets/.
            let whaleRoots = PetView.assetRoots(forTheme: PetView.whaleThemeID, appSupport: tmp, bundleResources: bundledRoot)
            expect(whaleRoots.count == 1 && whaleRoots[0].standardizedFileURL == bundledRoot.appendingPathComponent("Assets").standardizedFileURL,
                   "whale-girl theme resolves explicitly to bundled Assets")

            // Named theme isolates roots away from default Assets, and vector theme clears roots.
            let themeRoots = PetView.assetRoots(forTheme: "shiba", appSupport: tmp, bundleResources: bundledRoot)
            expect(themeRoots.count == 2 && themeRoots[0].path.hasSuffix("/Themes/shiba"),
                   "named theme resolves against Themes/<name> instead of default Assets")
            expect(PetView.assetRoots(forTheme: PetView.vectorThemeID, appSupport: tmp, bundleResources: bundledRoot).isEmpty,
                   "vector theme skips image/movie asset roots")
        } catch {
            expect(false, "asset resolution setup failed: \(error)")
        }
    }

    // MARK: - Reply HUD placement

    private static func replyPlacement() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let normalPet = NSRect(x: 1200, y: 80, width: 180, height: 180)
        let normalOrigin = ReplyPanel.placementOrigin(near: normalPet, in: screen)
        expect(normalOrigin.y >= normalPet.maxY, "reply panel opens above pet when space allows")
        expect(normalOrigin.x + ReplyPanel.panelSize.width <= screen.maxX - 8, "reply panel clamps to right edge")

        let topPet = NSRect(x: 10, y: 710, width: 180, height: 180)
        let topOrigin = ReplyPanel.placementOrigin(near: topPet, in: screen)
        expect(topOrigin.y + ReplyPanel.panelSize.height <= topPet.minY, "reply panel flips below pet near top edge")
        expect(topOrigin.x >= screen.minX + 8, "reply panel clamps to left edge")
    }

    // MARK: - What a click actually sends

    private static func replies() {
        expect(ReplyPanel.payload(forTag: 0) == "y\r", "the allow button answers y")
        expect(ReplyPanel.payload(forTag: 2) == "n\r", "the deny button answers n")
        expect(ReplyPanel.payload(forTag: 1) == "1\r", "the middle button picks 1")
        expect(ReplyPanel.payload(forTag: 3) == "\u{03}", "the interrupt button sends ctrl-c")
        expect(ReplyPanel.payload(forTag: 9) == nil, "an unknown button sends nothing")

        // Typed answers go through JSON, so quotes and backslashes must survive.
        let awkward = "say \"hello\" \\ ok"
        let payload = RexBridge.jsonPayload(data: awkward)
        let decoded = payload
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        expect(decoded?["data"] == awkward, "a typed answer with quotes round-trips through the CLI payload")
    }

    // MARK: - UI helpers

    private static func uiHelpers() {
        expect(PetView.PetSize.small.petSide == 140 && PetView.PetSize.medium.petSide == 180 && PetView.PetSize.large.petSide == 220,
               "pet size presets match expected dimensions")
        expect(CatSprite.menuBarImage(height: 16, blocked: false).isTemplate && CatSprite.menuBarImage(height: 16, blocked: true).isTemplate,
               "menu bar icons render as template images in both normal and blocked states")
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
