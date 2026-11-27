import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var petSize: PetView.PetSize = PetView.PetSize(rawValue: UserDefaults.standard.string(forKey: "petSize") ?? "") ?? .medium
    private var panelSize: NSSize { petSize.panelSize }

    private var panel: PetPanel!
    private var petView: PetView!
    private var statusItem: NSStatusItem!
    private let statusIconNormal = CatSprite.menuBarImage(height: 16, blocked: false)
    private let statusIconBlocked = CatSprite.menuBarImage(height: 16, blocked: true)
    private var pollTimer: Timer?
    private var replyPanel: ReplyPanel?
    private var mouseMonitor: Any?
    private var cursorTimer: Timer?

    private var context = PetContext()
    private var blockedPanes: [PetStateMachine.BlockedPane] = []
    private var watcher: RexWatcher?
    private var watchStatusItem: NSMenuItem?
    private var lastEventAt = Date.distantPast
    private let machine = PetStateMachine()
    private var warnedAboutRex = false
    private var launchAtLoginItem: NSMenuItem?
    private var demoItem: NSMenuItem?
    private var clickThroughItem: NSMenuItem?
    private var notifyBlockedItem: NSMenuItem?
    private var soundOnDoneItem: NSMenuItem?
    private var stateMenuItem: NSMenuItem?
    private var themeMenuItem: NSMenuItem?
    private var sizeMenuItem: NSMenuItem?
    private var revealMenuItem: NSMenuItem?
    private var replyMenuItem: NSMenuItem?
    /// How long a manually written state file outranks the event stream.
    private static let overrideTTL: TimeInterval = 60
    private static let manualPickTTL: TimeInterval = 15
    private var manualStateUntil: Date?
    private var bubbleGeneration = 0
    private var clickThrough = (UserDefaults.standard.object(forKey: "clickThrough") as? Bool) ?? true
    private var notifyOnBlocked = (UserDefaults.standard.object(forKey: "notifyOnBlocked") as? Bool) ?? true
    private var soundOnDone = (UserDefaults.standard.object(forKey: "soundOnDone") as? Bool) ?? true
    private var selectedTheme = UserDefaults.standard.string(forKey: "selectedTheme") ?? PetView.defaultThemeID
    private var demoMode = UserDefaults.standard.bool(forKey: "demoMode")
    private var demoIndex = 0
    private var lastDemoSwap: CFTimeInterval = 0
    private let debug = ProcessInfo.processInfo.environment["REX_PET_DEBUG"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        buildStatusItem()
        startWatcher()
        startPolling()
        installClickThroughMonitor()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                              name: NSApplication.didChangeScreenParametersNotification,
                                              object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        cursorTimer?.invalidate()
        watcher?.stop()
    }

    // MARK: - Watch

    private func startWatcher() {
        guard ProcessInfo.processInfo.environment["REX_PET_NO_WATCH"] != "1" else {
            debugLog("event watching disabled by REX_PET_NO_WATCH")
            return
        }
        let stream = RexWatcher()
        stream.onUpdate = { [weak self] update in self?.handleWatchUpdate(update) }
        stream.onStatus = { [weak self] status in
            guard let self else { return }
            self.watchStatusItem?.title = L10n.t("rex events: ", "rex events：") + status.label
            // A stranger's first run usually fails here (GUI apps get launchd's PATH),
            // so say it out loud once instead of sitting there looking broken.
            if status == .missingBinary, !self.warnedAboutRex {
                self.warnedAboutRex = true
                self.showBubble(L10n.t("Rex not found — pick its path in the menu", "找不到 rex：菜单里选一下路径"), seconds: 8)
            }
        }
        stream.onLog = { [weak self] message in self?.debugLog("watch \(message)") }
        stream.start()
        watcher = stream
    }

    /// The watcher only reports what rex said; `PetStateMachine` decides which
    /// pane currently owns the pet.
    private func handleWatchUpdate(_ update: RexWatcher.Update) {
        lastEventAt = Date()
        debugLog("event \(update.state.rawValue) block=\(update.blockID ?? "-")")
        if update.state != .idle {
            manualStateUntil = nil
        }
        machine.apply(update)
        // A fresh state file outranks the stream, here too: applying the stream
        // directly is what made the pet flip between two states every event.
        guard !applyFileOverride() else { return }
        guard manualStateUntil == nil else { return }
        syncFromMachine()
    }

    private func syncFromMachine() {
        let snapshot = machine.snapshot()
        let wasBlocked = context.state == .blocked
        context.blockID = snapshot.blockID
        context.title = snapshot.title
        blockedPanes = snapshot.blockedPanes
        updateActionMenuItems()
        updateStatusChrome()
        guard snapshot.state != context.state else { return }
        apply(snapshot.state)
        if snapshot.state == .blocked && !wasBlocked && notifyOnBlocked {
            showBlockedAlertBubble()
        }
    }

    // MARK: - Window

    private func buildPanel() {
        panel = PetPanel(frame: NSRect(origin: restoreOrigin(), size: panelSize))
        petView = PetView(frame: NSRect(origin: .zero, size: panelSize))
        petView.petSize = petSize
        petView.selectedTheme = selectedTheme
        petView.onLog = { [weak self] message in self?.debugLog(message) }
        petView.onClick = { [weak self] in self?.handlePetClick() }
        petView.onReveal = { [weak self] in self?.revealPane() }
        petView.onRightClick = { [weak self] in self?.showMenu() }
        petView.onDragEnd = { [weak self] origin in
            guard let self else { return }
            let fixed = clampOrigin(origin)
            panel.setFrameOrigin(fixed)
            UserDefaults.standard.set("\(fixed.x),\(fixed.y)", forKey: "petOrigin")
        }
        panel.contentView = petView
        panel.orderFrontRegardless()
    }

    /// Keeps the cat reachable: a display that was unplugged, or a window dragged
    /// past the edge, must not strand it where nobody can see or click it.
    private func clampOrigin(_ origin: NSPoint) -> NSPoint {
        var rect = NSRect(origin: origin, size: panelSize)
        let reachable = NSScreen.screens.map { $0.visibleFrame.insetBy(dx: -40, dy: -40) }
        guard !reachable.contains(where: { $0.intersects(rect) }) else { return origin }
        // Off every screen: put it back on the primary one, bottom right.
        let home = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        rect.origin = NSPoint(x: home.maxX - panelSize.width - 40, y: home.minY + 60)
        return rect.origin
    }

    /// Displays come and go; without this the cat can end up on a screen that no
    /// longer exists and looks like a crash to the user.
    @objc private func screensChanged() {
        guard panel.frame.size != .zero else { return }
        let fixed = clampOrigin(panel.frame.origin)
        if fixed != panel.frame.origin {
            panel.setFrameOrigin(fixed)
            UserDefaults.standard.set("\(fixed.x),\(fixed.y)", forKey: "petOrigin")
            debugLog("screen change: pet moved to \(fixed)")
        }
    }

    private func restoreOrigin() -> NSPoint {
        if let raw = UserDefaults.standard.string(forKey: "petOrigin") {
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                let point = NSPoint(x: parts[0], y: parts[1])
                if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) }) {
                    return point
                }
            }
        }
        // `NSScreen.main` follows keyboard focus, so a first run on a multi-display
        // setup can land on whichever screen happens to be focused. `screens.first`
        // is the primary display and is stable.
        let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - panelSize.width - 40, y: screen.minY + 60)
    }

    // MARK: - Click-through

    /// A transparent window still swallows clicks over its empty area, so the
    /// pass-through is driven by polling the cursor: `NSEvent.mouseLocation` needs
    /// no Accessibility grant, unlike a CGEventTap or key-event monitor.
    private func installClickThroughMonitor() {
        syncClickThroughMonitor()
    }

    private func syncClickThroughMonitor() {
        if clickThrough {
            if cursorTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                    self?.updateClickThrough()
                }
                timer.tolerance = 0.01
                RunLoop.main.add(timer, forMode: .common)
                cursorTimer = timer
            }
            if mouseMonitor == nil {
                // Immediate reaction while the pointer is already over the pet.
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                    self?.updateClickThrough()
                }
            }
            updateClickThrough()
        } else {
            cursorTimer?.invalidate()
            cursorTimer = nil
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            panel.ignoresMouseEvents = false
        }
    }

    private func updateClickThrough(forceInteractive: Bool = false) {
        guard clickThrough || forceInteractive else {
            panel.ignoresMouseEvents = false
            return
        }
        if forceInteractive || petView.isDragging || replyPanel?.isVisible == true {
            panel.ignoresMouseEvents = false
            return
        }
        let inside = petView.isInteractive(screenPoint: NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != !inside {
            panel.ignoresMouseEvents = !inside
            if debug {
                let line = "[pet] click-through=\(!inside) inside=\(inside) at \(NSEvent.mouseLocation)\n"
                FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
            }
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A template image follows the menu bar's light/dark tint, unlike an emoji.
        statusItem.button?.image = statusIconNormal
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()

        let stateRoot = NSMenuItem(title: L10n.t("State", "状态"), action: nil, keyEquivalent: "")
        let stateMenu = NSMenu(title: L10n.t("State", "状态"))
        for state in PetState.allCases {
            let item = NSMenuItem(title: state.label, action: #selector(pickState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = state.rawValue
            stateMenu.addItem(item)
        }
        stateRoot.submenu = stateMenu
        stateMenuItem = stateRoot
        menu.addItem(stateRoot)

        let themeRoot = NSMenuItem(title: L10n.t("Theme", "主题"), action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: L10n.t("Theme", "主题"))
        let defaultItem = NSMenuItem(title: L10n.t("Default (Built-in Cat)", "默认（内置小猫）"), action: #selector(pickTheme(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = PetView.defaultThemeID
        themeMenu.addItem(defaultItem)

        let extraThemes = PetView.availableThemes()
        if !extraThemes.isEmpty {
            themeMenu.addItem(.separator())
            for id in extraThemes {
                let item = NSMenuItem(title: themeDisplayName(id), action: #selector(pickTheme(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                themeMenu.addItem(item)
            }
        }
        themeRoot.submenu = themeMenu
        themeMenuItem = themeRoot
        menu.addItem(themeRoot)
        updateThemeMenuState()

        let sizeRoot = NSMenuItem(title: L10n.t("Size", "大小"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: L10n.t("Size", "大小"))
        for size in PetView.PetSize.allCases {
            let item = NSMenuItem(title: size.label, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            sizeMenu.addItem(item)
        }
        sizeRoot.submenu = sizeMenu
        sizeMenuItem = sizeRoot
        menu.addItem(sizeRoot)
        updateSizeMenuState()

        let watchItem = NSMenuItem(title: L10n.t("rex events: not running", "rex events：未运行"), action: nil, keyEquivalent: "")
        watchItem.isEnabled = false
        watchStatusItem = watchItem
        menu.addItem(watchItem)

        let reconnectItem = NSMenuItem(title: L10n.t("Reconnect rex events", "重连 rex events"), action: #selector(reconnectWatch), keyEquivalent: "")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        let pickRexItem = NSMenuItem(title: L10n.t("Choose the rex binary…", "选择 rex 可执行文件…"), action: #selector(pickRexBinary), keyEquivalent: "")
        pickRexItem.target = self
        menu.addItem(pickRexItem)

        let loginItem = NSMenuItem(title: L10n.t("Launch at login", "登录时启动"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchAtLoginItem = loginItem
        menu.addItem(loginItem)

        let demoItem = NSMenuItem(title: L10n.t("Demo mode (auto-cycle)", "演示模式（自动轮换）"), action: #selector(toggleDemo), keyEquivalent: "")
        demoItem.target = self
        self.demoItem = demoItem
        demoItem.state = demoMode ? .on : .off
        menu.addItem(demoItem)

        let notifyItem = NSMenuItem(title: L10n.t("Notify bubble when blocked", "等待确认时气泡提醒"), action: #selector(toggleNotifyBlocked), keyEquivalent: "")
        notifyItem.target = self
        notifyBlockedItem = notifyItem
        notifyItem.state = notifyOnBlocked ? .on : .off
        menu.addItem(notifyItem)

        let clickItem = NSMenuItem(title: L10n.t("Click through transparent areas", "透明区域点击穿透"), action: #selector(toggleClickThrough), keyEquivalent: "")
        clickItem.target = self
        clickThroughItem = clickItem
        clickItem.state = clickThrough ? .on : .off
        menu.addItem(clickItem)

        let soundItem = NSMenuItem(title: L10n.t("Chime when a pane finishes", "运行完成时响一声"), action: #selector(toggleSoundOnDone), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = soundOnDone ? .on : .off
        soundOnDoneItem = soundItem
        menu.addItem(soundItem)

        let resetItem = NSMenuItem(title: L10n.t("Reset position", "复位位置"), action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let revealItem = NSMenuItem(title: L10n.t("Show the pane in Rex", "在 Rex 中定位当前分屏"), action: #selector(revealPane), keyEquivalent: "")
        revealItem.target = self
        revealMenuItem = revealItem
        menu.addItem(revealItem)

        let replyItem = NSMenuItem(title: L10n.t("Reply to the blocked pane…", "回复阻塞分屏…"), action: #selector(replyBlocked), keyEquivalent: "")
        replyItem.target = self
        replyMenuItem = replyItem
        menu.addItem(replyItem)

        menu.addItem(.separator())

        let reloadAssetsItem = NSMenuItem(title: L10n.t("Reload pet assets", "重新加载宠物资源"), action: #selector(reloadAssets), keyEquivalent: "")
        reloadAssetsItem.target = self
        menu.addItem(reloadAssetsItem)

        let openAssetsItem = NSMenuItem(title: L10n.t("Open Assets folder…", "打开资源文件夹…"), action: #selector(openAssetsFolder), keyEquivalent: "")
        openAssetsItem.target = self
        menu.addItem(openAssetsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("Quit", "退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        updateActionMenuItems()
        updateStatusChrome()
    }

    private func updateActionMenuItems() {
        revealMenuItem?.isEnabled = context.blockID != nil
        let isBlocked = context.state == .blocked && context.blockID != nil
        replyMenuItem?.isEnabled = isBlocked

        if blockedPanes.count > 1 {
            replyMenuItem?.title = L10n.t("Reply to blocked panes (\(blockedPanes.count))…", "回复阻塞分屏 (\(blockedPanes.count))…")
            let sub = NSMenu(title: replyMenuItem?.title ?? "")
            for pane in blockedPanes {
                let short = pane.blockID.count > 14 ? String(pane.blockID.suffix(10)) : pane.blockID
                let title = (pane.title.flatMap { $0.isEmpty ? nil : $0 } ?? "pane") + " · \(short)"
                let item = NSMenuItem(title: title, action: #selector(replySpecificPane(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pane.blockID
                sub.addItem(item)
            }
            replyMenuItem?.submenu = sub
        } else {
            replyMenuItem?.title = L10n.t("Reply to the blocked pane…", "回复阻塞分屏…")
            replyMenuItem?.submenu = nil
        }
    }

    private func updateStatusChrome() {
        let blocked = context.state == .blocked
        statusItem?.button?.image = blocked ? statusIconBlocked : statusIconNormal
        let titleSuffix = context.title.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        let countSuffix = blocked && blockedPanes.count > 1 ? " (\(blockedPanes.count))" : ""
        statusItem?.button?.toolTip = "Rex Pet — \(context.state.label)\(titleSuffix)\(countSuffix)"
    }

    private func showMenu() {
        guard let menu = statusItem.menu else { return }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func themeDisplayName(_ id: String) -> String {
        switch id {
        case "red-panda": return L10n.t("Red Panda", "小熊猫 (red-panda)")
        case "shiba": return L10n.t("Shiba Inu", "柴犬 (shiba)")
        case "capybara": return L10n.t("Capybara", "卡皮巴拉 (capybara)")
        case "penguin": return L10n.t("Penguin", "小企鹅 (penguin)")
        case "retro-robot": return L10n.t("Retro Robot", "复古小机器人 (retro-robot)")
        case PetView.whaleThemeID: return L10n.t("Whale Girl", "鲸鱼娘 (whale-girl)")
        default: return id
        }
    }

    private func updateThemeMenuState() {
        guard let themeMenu = themeMenuItem?.submenu else { return }
        for item in themeMenu.items {
            item.state = (item.representedObject as? String) == selectedTheme ? .on : .off
        }
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let themeID = sender.representedObject as? String else { return }
        selectedTheme = themeID
        UserDefaults.standard.set(themeID, forKey: "selectedTheme")
        petView.selectedTheme = themeID
        updateThemeMenuState()
    }

    private func updateSizeMenuState() {
        guard let sizeMenu = sizeMenuItem?.submenu else { return }
        for item in sizeMenu.items {
            item.state = (item.representedObject as? String) == petSize.rawValue ? .on : .off
        }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let next = PetView.PetSize(rawValue: raw),
              next != petSize else { return }
        let oldFrame = panel.frame
        petSize = next
        UserDefaults.standard.set(next.rawValue, forKey: "petSize")
        petView.petSize = next
        updateSizeMenuState()

        let newSize = next.panelSize
        // Anchor bottom-center so growing/shrinking keeps the pet's feet in place.
        let anchoredOrigin = NSPoint(
            x: round(oldFrame.midX - newSize.width / 2),
            y: oldFrame.minY
        )
        let fixed = clampOrigin(anchoredOrigin)
        panel.setFrame(NSRect(origin: fixed, size: newSize), display: true)
        petView.frame = NSRect(origin: .zero, size: newSize)
        UserDefaults.standard.set("\(fixed.x),\(fixed.y)", forKey: "petOrigin")
    }

    @objc private func toggleNotifyBlocked() {
        notifyOnBlocked.toggle()
        UserDefaults.standard.set(notifyOnBlocked, forKey: "notifyOnBlocked")
        notifyBlockedItem?.state = notifyOnBlocked ? .on : .off
    }

    @objc private func toggleSoundOnDone() {
        soundOnDone.toggle()
        UserDefaults.standard.set(soundOnDone, forKey: "soundOnDone")
        soundOnDoneItem?.state = soundOnDone ? .on : .off
    }

    @objc private func pickState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let state = PetState(rawValue: raw) else { return }
        demoMode = false
        UserDefaults.standard.set(false, forKey: "demoMode")
        demoItem?.state = .off
        if state == .idle {
            manualStateUntil = nil
            machine.reset()
            context.blockID = nil
            context.title = nil
        } else {
            manualStateUntil = Date().addingTimeInterval(Self.manualPickTTL)
        }
        apply(state)
    }

    @objc private func toggleDemo() {
        demoMode.toggle()
        UserDefaults.standard.set(demoMode, forKey: "demoMode")
        demoItem?.state = demoMode ? .on : .off
        manualStateUntil = nil
        lastDemoSwap = 0
        if !demoMode {
            if !applyFileOverride() {
                syncFromMachine()
                if context.state != .idle && machine.snapshot().state == .idle {
                    apply(.idle)
                }
            }
        }
    }

    @objc private func reloadAssets() {
        petView.reloadAssets()
        showBubble(L10n.t("Assets reloaded", "已重新加载资源"), seconds: 1.5)
    }

    @objc private func openAssetsFolder() {
        let dir = URL(fileURLWithPath: ("~/Library/Application Support/rex-pet/Assets" as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func reconnectWatch() {
        watcher?.restart()
    }

    /// Lets the user point the pet at a rex binary the app cannot find on its own
    /// (GUI apps do not inherit the shell PATH).
    /// `SMAppService` needs a real bundle, so this fails when the app still runs
    /// from `build/`; the bubble says so instead of pretending it worked.
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                launchAtLoginItem?.state = .off
                showBubble(L10n.t("Launch at login off", "已关闭开机启动"), seconds: 2)
            } else {
                try service.register()
                launchAtLoginItem?.state = .on
                showBubble(L10n.t("Will start at login", "已设为登录时启动"), seconds: 2)
            }
        } catch {
            debugLog("launch at login failed: \(error.localizedDescription)")
            showBubble(L10n.t("Could not set it — move the app to /Applications first", "设置失败，先把 app 移到「应用程序」"), seconds: 5)
        }
    }

    @objc private func pickRexBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.t("Choose the rex command line binary", "选择 rex 命令行可执行文件")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/com.superlogical.rex")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: RexBridge.binPathDefaultsKey)
        debugLog("rex path set to \(url.path)")
        warnedAboutRex = true
        watcher?.restart()
        showBubble(L10n.t("rex path saved", "已设置 rex 路径"), seconds: 2)
    }

    @objc private func toggleClickThrough() {
        clickThrough.toggle()
        UserDefaults.standard.set(clickThrough, forKey: "clickThrough")
        clickThroughItem?.state = clickThrough ? .on : .off
        syncClickThroughMonitor()
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "petOrigin")
        panel.setFrameOrigin(restoreOrigin())
    }

    /// Focus the pane the cat is reporting, so "the agent needs me" leads somewhere.
    @objc private func revealPane() {
        guard let block = context.blockID else {
            showBubble(L10n.t("No pane is active right now", "当前没有活动分屏"))
            return
        }
        RexBridge.focus(blockID: block) { [weak self] ok, error in
            guard let self else { return }
            if ok {
                activateRex()
            } else {
                showBubble(L10n.t("Could not focus the pane: \(error ?? "")", "无法定位分屏：\(error ?? "")"))
            }
        }
    }

    private func activateRex() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.superlogical.rex" }) else { return }
        app.activate()
    }

    @objc private func replyBlocked() {
        if context.state == .blocked, let block = context.blockID {
            showReply(block: block, title: context.title)
        } else {
            showBubble(L10n.t("No pane is blocked right now", "当前没有阻塞分屏"))
        }
    }

    @objc private func replySpecificPane(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? String else { return }
        let title = blockedPanes.first(where: { $0.blockID == block })?.title
        showReply(block: block, title: title)
    }

    // MARK: - State

    private func startPolling() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    private func poll() {
        if demoMode {
            let now = CACurrentMediaTime()
            if now - lastDemoSwap > 6 {
                lastDemoSwap = now
                let states = PetState.allCases
                apply(states[demoIndex % states.count])
                demoIndex += 1
            }
            return
        }
        // A fresh file override owns the pet for its whole TTL: letting events
        // through between polls makes state flip-flop and rebuild the player.
        guard !applyFileOverride() else { return }
        expireStaleStates()
    }

    /// A state file written in the last `overrideTTL` wins over the event stream:
    /// that keeps the demo/hand-test path usable while a busy pane keeps emitting
    /// events every few hundred milliseconds.
    @discardableResult
    private func applyFileOverride() -> Bool {
        guard let mtime = stateFileMTime(), Date().timeIntervalSince(mtime) < Self.overrideTTL else { return false }
        let loaded = PetContext.load()
        if loaded.state != context.state || loaded.blockID != context.blockID || loaded.title != context.title {
            let wasBlocked = context.state == .blocked
            context.blockID = loaded.blockID
            context.title = loaded.title
            blockedPanes = []
            machine.reset()
            debugLog("file state=\(loaded.state.rawValue)")
            apply(loaded.state)
            if loaded.state == .blocked && !wasBlocked && notifyOnBlocked {
                showBlockedAlertBubble()
            }
        }
        return true
    }

    private func stateFileMTime() -> Date? {
        let paths = [PetContext.contextPath, PetContext.statePath]
        let dates = paths.compactMap { path -> Date? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            return attributes[.modificationDate] as? Date
        }
        return dates.max()
    }

    /// TTL expiry runs on the poll tick: `done`/`error`/`working` all fall back
    /// to idle here once nothing refreshed them.
    private func expireStaleStates() {
        if let until = manualStateUntil {
            if Date() < until { return }
            manualStateUntil = nil
        }
        syncFromMachine()
    }

    private func apply(_ state: PetState) {
        let previous = context.state
        context.state = state
        if PetChime.shouldPlay(from: previous, to: state, enabled: soundOnDone) {
            PetChime.play()
            debugLog("chime done")
        }
        petView.petState = state
        updateActionMenuItems()
        updateStatusChrome()
        if let stateMenu = stateMenuItem?.submenu {
            for item in stateMenu.items {
                item.state = (item.representedObject as? String) == state.rawValue ? .on : .off
            }
        }
    }

    private func showBlockedAlertBubble() {
        let title = context.title.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        let extra = blockedPanes.count > 1 ? " (+\(blockedPanes.count - 1))" : ""
        showBubble(PetState.blocked.label + title + extra, seconds: 3.5)
    }

    // MARK: - Interaction

    private func handlePetClick() {
        if context.state == .blocked, let block = context.blockID {
            showReply(block: block, title: context.title)
            return
        }
        let title = context.title.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        showBubble(context.state.label + title)
    }

    private func showReply(block: String, title: String?) {
        let reply = replyPanel ?? ReplyPanel()
        replyPanel = reply
        reply.onSend = { [weak self] payload in self?.sendReply(block: block, payload: payload) }
        reply.onClose = { [weak self] in
            self?.replyPanel = nil
            self?.updateClickThrough()
            self?.debugLog("reply closed")
        }
        let extra = max(0, blockedPanes.filter { $0.blockID != block }.count)
        reply.present(blockID: block, title: title, extraBlockedCount: extra, near: petView.screenAnchor)
        updateClickThrough(forceInteractive: true)
        debugLog("reply presented block=\(block)")
    }

    private func sendReply(block: String, payload: String) {
        debugLog("send block=\(block) payload=\(payload.debugDescription)")
        RexBridge.write(blockID: block, text: payload) { [weak self] ok, errorText in
            guard let self else { return }
            self.debugLog("send result ok=\(ok) err=\(errorText ?? "-")")
            if ok {
                self.showBubble(L10n.t("Sent", "已发送"), seconds: 1.5)
                self.machine.apply(RexWatcher.Update(state: .working, blockID: block, title: self.context.title))
                self.syncFromMachine()
            } else {
                self.showBubble(L10n.t("Send failed: ", "发送失败：") + (errorText ?? L10n.t("unknown error", "未知错误")), seconds: 4)
            }
        }
    }

    private func debugLog(_ message: String) {
        guard debug else { return }
        FileHandle.standardError.write("[pet] \(message)\n".data(using: .utf8) ?? Data())
    }

    private func showBubble(_ text: String, seconds: TimeInterval = 3) {
        bubbleGeneration &+= 1
        let gen = bubbleGeneration
        petView.bubbleText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.bubbleGeneration == gen else { return }
            self.petView.bubbleText = nil
        }
    }
}
