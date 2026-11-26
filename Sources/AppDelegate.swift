import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panelSize = NSSize(width: 220, height: 232)

    private var panel: PetPanel!
    private var petView: PetView!
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var replyPanel: ReplyPanel?
    private var mouseMonitor: Any?
    private var cursorTimer: Timer?

    private var context = PetContext()
    private var watcher: RexWatcher?
    private var watchStatusItem: NSMenuItem?
    private var lastEventAt = Date.distantPast
    private let machine = PetStateMachine()
    private var warnedAboutRex = false
    private var launchAtLoginItem: NSMenuItem?
    /// How long a manually written state file outranks the event stream.
    private static let overrideTTL: TimeInterval = 60
    private var clickThrough = (UserDefaults.standard.object(forKey: "clickThrough") as? Bool) ?? true
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
            self.watchStatusItem?.title = "rex events：" + status.rawValue
            // A stranger's first run usually fails here (GUI apps get launchd's PATH),
            // so say it out loud once instead of sitting there looking broken.
            if status == .missingBinary, !self.warnedAboutRex {
                self.warnedAboutRex = true
                self.showBubble("找不到 rex：菜单里选一下路径", seconds: 8)
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
        machine.apply(update)
        syncFromMachine()
    }

    private func syncFromMachine() {
        let snapshot = machine.snapshot()
        if let block = snapshot.blockID { context.blockID = block }
        if let title = snapshot.title { context.title = title }
        guard snapshot.state != context.state else { return }
        apply(snapshot.state)
    }

    // MARK: - Window

    private func buildPanel() {
        panel = PetPanel(frame: NSRect(origin: restoreOrigin(), size: panelSize))
        petView = PetView(frame: NSRect(origin: .zero, size: panelSize))
        petView.onClick = { [weak self] in self?.handlePetClick() }
        petView.onRightClick = { [weak self] in self?.showMenu() }
        petView.onDragEnd = { origin in
            UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: "petOrigin")
        }
        panel.contentView = petView
        panel.orderFrontRegardless()
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
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.updateClickThrough()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer

        // Immediate reaction while the pointer is already over the pet.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateClickThrough()
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
        let icon = CatSprite.menuBarImage(height: 16)
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()

        let stateRoot = NSMenuItem(title: "状态", action: nil, keyEquivalent: "")
        let stateMenu = NSMenu(title: "状态")
        for state in PetState.allCases {
            let item = NSMenuItem(title: state.label, action: #selector(pickState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = state.rawValue
            stateMenu.addItem(item)
        }
        stateRoot.submenu = stateMenu
        menu.addItem(stateRoot)

        let watchItem = NSMenuItem(title: "rex events：未运行", action: nil, keyEquivalent: "")
        watchItem.isEnabled = false
        watchStatusItem = watchItem
        menu.addItem(watchItem)

        let reconnectItem = NSMenuItem(title: "重连 rex events", action: #selector(reconnectWatch), keyEquivalent: "")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        let pickRexItem = NSMenuItem(title: "选择 rex 可执行文件…", action: #selector(pickRexBinary), keyEquivalent: "")
        pickRexItem.target = self
        menu.addItem(pickRexItem)

        let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchAtLoginItem = loginItem
        menu.addItem(loginItem)

        let demoItem = NSMenuItem(title: "演示模式（自动轮换）", action: #selector(toggleDemo), keyEquivalent: "")
        demoItem.target = self
        demoItem.state = demoMode ? .on : .off
        menu.addItem(demoItem)

        let clickItem = NSMenuItem(title: "透明区域点击穿透", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickItem.target = self
        clickItem.state = clickThrough ? .on : .off
        menu.addItem(clickItem)

        let resetItem = NSMenuItem(title: "复位位置", action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let replyItem = NSMenuItem(title: "回复阻塞分屏…", action: #selector(replyBlocked), keyEquivalent: "")
        replyItem.target = self
        menu.addItem(replyItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func showMenu() {
        guard let menu = statusItem.menu else { return }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pickState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let state = PetState(rawValue: raw) else { return }
        demoMode = false
        UserDefaults.standard.set(false, forKey: "demoMode")
        statusItem.menu?.item(withTitle: "演示模式（自动轮换）")?.state = .off
        apply(state)
    }

    @objc private func toggleDemo() {
        demoMode.toggle()
        UserDefaults.standard.set(demoMode, forKey: "demoMode")
        statusItem.menu?.item(withTitle: "演示模式（自动轮换）")?.state = demoMode ? .on : .off
        lastDemoSwap = 0
        if !demoMode { apply(PetContext.load().state) }
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
                showBubble("已关闭开机启动", seconds: 2)
            } else {
                try service.register()
                launchAtLoginItem?.state = .on
                showBubble("已设为登录时启动", seconds: 2)
            }
        } catch {
            debugLog("launch at login failed: \(error.localizedDescription)")
            showBubble("设置失败，先把 app 移到「应用程序」", seconds: 5)
        }
    }

    @objc private func pickRexBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 rex 命令行可执行文件"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/com.superlogical.rex")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: RexBridge.binPathDefaultsKey)
        debugLog("rex path set to \(url.path)")
        warnedAboutRex = true
        watcher?.restart()
        showBubble("已设置 rex 路径", seconds: 2)
    }

    @objc private func toggleClickThrough() {
        clickThrough.toggle()
        UserDefaults.standard.set(clickThrough, forKey: "clickThrough")
        statusItem.menu?.item(withTitle: "透明区域点击穿透")?.state = clickThrough ? .on : .off
        updateClickThrough(forceInteractive: true)
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "petOrigin")
        panel.setFrameOrigin(restoreOrigin())
    }

    @objc private func replyBlocked() {
        if context.state == .blocked, let block = context.blockID {
            showReply(block: block)
        } else {
            showBubble("当前没有阻塞分屏")
        }
    }

    // MARK: - State

    private func startPolling() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
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
        applyFileOverride()
        expireStaleStates()
    }

    /// A state file written in the last `overrideTTL` wins over the event stream:
    /// that keeps the demo/hand-test path usable while a busy pane keeps emitting
    /// events every few hundred milliseconds.
    private func applyFileOverride() {
        guard let mtime = stateFileMTime(), Date().timeIntervalSince(mtime) < Self.overrideTTL else { return }
        let loaded = PetContext.load()
        guard loaded.state != context.state || loaded.blockID != context.blockID else { return }
        context.blockID = loaded.blockID
        context.title = loaded.title
        machine.reset()
        debugLog("file state=\(loaded.state.rawValue)")
        apply(loaded.state)
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
        syncFromMachine()
    }

    private func apply(_ state: PetState) {
        context.state = state
        petView.petState = state
        if let stateMenu = statusItem.menu?.item(withTitle: "状态")?.submenu {
            for item in stateMenu.items {
                item.state = (item.representedObject as? String) == state.rawValue ? .on : .off
            }
        }
    }

    // MARK: - Interaction

    private func handlePetClick() {
        if context.state == .blocked, let block = context.blockID {
            showReply(block: block)
            return
        }
        let title = context.title.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        showBubble(context.state.label + title)
    }

    private func showReply(block: String) {
        let reply = replyPanel ?? ReplyPanel()
        replyPanel = reply
        reply.onSend = { [weak self] payload in self?.sendReply(block: block, payload: payload) }
        reply.onClose = { [weak self] in
            self?.replyPanel = nil
            self?.updateClickThrough()
            self?.debugLog("reply closed")
        }
        reply.present(blockID: block, title: context.title, near: petView.screenAnchor)
        updateClickThrough(forceInteractive: true)
        debugLog("reply presented block=\(block)")
    }

    private func sendReply(block: String, payload: String) {
        debugLog("send block=\(block) payload=\(payload.debugDescription)")
        RexBridge.write(blockID: block, text: payload) { [weak self] ok, errorText in
            guard let self else { return }
            self.debugLog("send result ok=\(ok) err=\(errorText ?? "-")")
            if ok {
                self.showBubble("已发送", seconds: 1.5)
                self.apply(.working)
            } else {
                self.showBubble("发送失败：\(errorText ?? "未知错误")", seconds: 4)
            }
        }
    }

    private func debugLog(_ message: String) {
        guard debug else { return }
        FileHandle.standardError.write("[pet] \(message)\n".data(using: .utf8) ?? Data())
    }

    private func showBubble(_ text: String, seconds: TimeInterval = 3) {
        petView.bubbleText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.petView.bubbleText == text else { return }
            self.petView.bubbleText = nil
        }
    }
}
