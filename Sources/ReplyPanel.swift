import AppKit

/// Small HUD that types a reply into the blocked pane through `rex block call write`.
/// It becomes key so text input works; the previously frontmost app is restored on close.
final class ReplyPanel: NSPanel, NSTextFieldDelegate, NSWindowDelegate {
    var onSend: ((String) -> Void)?
    var onClose: (() -> Void)?

    private(set) var targetBlock = ""
    private let promptLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private var previousApp: NSRunningApplication?
    private var isDismissing = false

    static let panelSize = NSSize(width: 340, height: 132)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: ReplyPanel.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        delegate = self
        buildContent()
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss(); return }
        super.keyDown(with: event)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, !isDismissing else { return }
        // User clicked another window/app: close cleanly without stealing focus back.
        isDismissing = true
        orderOut(nil)
        previousApp = nil
        isDismissing = false
        onClose?()
    }

    // MARK: - Content

    private func buildContent() {
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: ReplyPanel.panelSize))
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true

        promptLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.lineBreakMode = .byTruncatingMiddle

        let allow = makeButton(L10n.t("Allow (y)", "允许 (y)"), tag: 0)
        let pickOne = makeButton(L10n.t("Pick 1", "选 1"), tag: 1)
        let deny = makeButton(L10n.t("Deny (n)", "拒绝 (n)"), tag: 2)
        let interrupt = makeButton("Ctrl+C", tag: 3)

        let buttons = NSStackView(views: [allow, pickOne, deny, interrupt])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        field.placeholderString = L10n.t("Type a reply · ↩ sends · Esc closes", "输入回复，回车发送 · Esc 关闭")
        field.font = NSFont.systemFont(ofSize: 12)
        field.delegate = self
        field.target = self
        field.action = #selector(submitField)
        field.bezelStyle = .roundedBezel

        let stack = NSStackView(views: [promptLabel, buttons, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        backdrop.addSubview(stack)
        contentView = backdrop

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -12),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func makeButton(_ title: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(quickReply(_:)))
        button.tag = tag
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        return button
    }

    // MARK: - Presentation

    /// Places the reply HUD above `anchor` when space permits, flipping below it if near the top edge.
    static func placementOrigin(near anchor: NSRect, in visibleFrame: NSRect) -> NSPoint {
        let size = panelSize
        let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX + 8),
                    visibleFrame.maxX - size.width - 8)
        let aboveY = anchor.maxY + 8
        let y: CGFloat
        if aboveY + size.height <= visibleFrame.maxY - 8 {
            y = aboveY
        } else {
            let belowY = anchor.minY - size.height - 8
            y = belowY >= visibleFrame.minY + 8 ? belowY : min(aboveY, visibleFrame.maxY - size.height - 8)
        }
        return NSPoint(x: x, y: max(visibleFrame.minY + 8, y))
    }

    func present(blockID: String, title: String?, near anchor: NSRect) {
        targetBlock = blockID
        let short = blockID.count > 14 ? String(blockID.suffix(10)) : blockID
        promptLabel.stringValue = L10n.t("Send to", "发送到") + " " + "\(title.flatMap { $0.isEmpty ? nil : $0 } ?? "pane") · \(short)"
        field.stringValue = ""

        previousApp = NSWorkspace.shared.frontmostApplication
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        let origin = screen.map { Self.placementOrigin(near: anchor, in: $0.visibleFrame) }
            ?? NSPoint(x: anchor.midX - Self.panelSize.width / 2, y: anchor.maxY + 8)
        setFrameOrigin(origin)

        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        orderOut(nil)
        // Hand focus back to whatever the user was working in.
        previousApp?.activate()
        previousApp = nil
        isDismissing = false
        onClose?()
    }

    // MARK: - Actions

    /// Raw bytes a button sends to the pane. Kept separate from the button
    /// wiring so `--selftest` can assert them: a wrong \r means a pane that
    /// silently ignores the answer.
    static func payload(forTag tag: Int) -> String? {
        switch tag {
        case 0: return "y\r"
        case 1: return "1\r"
        case 2: return "n\r"
        case 3: return "\u{03}"
        default: return nil
        }
    }

    @objc private func quickReply(_ sender: NSButton) {
        guard let payload = ReplyPanel.payload(forTag: sender.tag) else { return }
        send(payload)
    }

    @objc private func submitField() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { dismiss(); return }
        send(text + "\r")
    }

    private func send(_ payload: String) {
        onSend?(payload)
        dismiss()
    }
}
