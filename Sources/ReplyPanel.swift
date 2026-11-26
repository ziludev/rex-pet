import AppKit

/// Small HUD that types a reply into the blocked pane through `rex block call write`.
/// It becomes key so text input works; the previously frontmost app is restored on close.
final class ReplyPanel: NSPanel, NSTextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onClose: (() -> Void)?

    private(set) var targetBlock = ""
    private let promptLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private var previousApp: NSRunningApplication?

    private static let panelSize = NSSize(width: 340, height: 132)

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

        let allow = makeButton("允许 (y)", tag: 0)
        let pickOne = makeButton("选 1", tag: 1)
        let deny = makeButton("拒绝 (n)", tag: 2)
        let interrupt = makeButton("Ctrl+C", tag: 3)

        let buttons = NSStackView(views: [allow, pickOne, deny, interrupt])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        field.placeholderString = "输入回复，回车发送 · Esc 关闭"
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

    func present(blockID: String, title: String?, near anchor: NSRect) {
        targetBlock = blockID
        let short = blockID.count > 14 ? String(blockID.suffix(10)) : blockID
        promptLabel.stringValue = "发送到 \(title.flatMap { $0.isEmpty ? nil : $0 } ?? "pane") · \(short)"
        field.stringValue = ""

        previousApp = NSWorkspace.shared.frontmostApplication
        var origin = NSPoint(x: anchor.midX - ReplyPanel.panelSize.width / 2, y: anchor.maxY + 8)
        if let screen = NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - ReplyPanel.panelSize.width - 8)
            origin.y = min(origin.y, screen.maxY - ReplyPanel.panelSize.height - 8)
        }
        setFrameOrigin(origin)

        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func dismiss() {
        orderOut(nil)
        // Hand focus back to whatever the user was working in.
        previousApp?.activate()
        previousApp = nil
        onClose?()
    }

    // MARK: - Actions

    @objc private func quickReply(_ sender: NSButton) {
        switch sender.tag {
        case 0: send("y\r")
        case 1: send("1\r")
        case 2: send("n\r")
        case 3: send("\u{03}")
        default: break
        }
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
