import AppKit

/// Streams `rex events --all --json` and turns terminal activity into pet states.
///
/// This is the native replacement for the old `tools/rex-feed.sh` bridge: same
/// event shape as rex-beacon's `internal/daemon/watcher.go`, no jq, no temp files.
///
/// Event nesting: `session_event` → `payload.event` (inner envelope) →
/// `block_event` → `payload.name` (`program_status_changed`, `bell`, …).
final class RexWatcher {
    struct Update {
        let state: PetState
        let blockID: String?
        let title: String?
    }

    /// Human readable connection state, for the menu bar.
    enum Status: String {
        case starting = "连接中"
        case running = "监听中"
        case stopped = "未运行"
    }

    var onUpdate: ((Update) -> Void)?
    var onStatus: ((Status) -> Void)?
    var onLog: ((String) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var retryDelay: TimeInterval = 2
    private var restartWorkItem: DispatchWorkItem?
    private var stopped = false
    private(set) var status: Status = .stopped

    // MARK: - Lifecycle

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        process?.terminate()
        process = nil
        setStatus(.stopped)
    }

    func restart() {
        stop()
        retryDelay = 2
        start()
    }

    private func launch() {
        guard !stopped else { return }
        guard let bin = RexBridge.binary() else {
            setStatus(.stopped)
            onLog?("找不到 rex 可执行文件，跳过事件监听")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = ["events", "--all", "--json"]

        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            self?.onLog?("stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                guard !self.stopped else { return }
                self.onLog?("rex events 退出，status=\(finished.terminationStatus)，\(Int(self.retryDelay))s 后重连")
                self.setStatus(.starting)
                let item = DispatchWorkItem { [weak self] in self?.launch() }
                self.restartWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay, execute: item)
                // Back off so a broken rex install does not spin the CPU.
                self.retryDelay = min(self.retryDelay * 2, 30)
            }
        }

        do {
            try task.run()
            process = task
            setStatus(.running)
            retryDelay = 2
            buffer.removeAll()
        } catch {
            setStatus(.stopped)
            onLog?("启动 rex events 失败：\(error.localizedDescription)")
        }
    }

    private func setStatus(_ next: Status) {
        status = next
        if Thread.isMainThread {
            onStatus?(next)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onStatus?(next) }
        }
    }

    // MARK: - Parsing

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard object["type"] as? String == "session_event",
              let payload = object["payload"] as? [String: Any],
              let inner = payload["event"] as? [String: Any] else { return }

        let innerType = inner["type"] as? String

        if innerType == "block_closed",
           let blockPayload = inner["payload"] as? [String: Any],
           let closed = blockPayload["block_id"] as? String {
            emit(.idle, blockID: closed, title: nil)
            return
        }

        guard innerType == "block_event",
              let blockPayload = inner["payload"] as? [String: Any] else { return }

        // Only the terminal's own blocks speak the vocabulary we care about.
        if let creator = blockPayload["creator_name"] as? String, creator != "com.superlogical.terminal" {
            return
        }

        let blockID = blockPayload["block_id"] as? String
        let name = blockPayload["name"] as? String ?? ""
        let detail = blockPayload["payload"] as? [String: Any] ?? [:]

        switch name {
        case "progress_report":
            guard let raw = detail["state"] as? String,
                  let state = progressState(raw) else { return }
            emit(state, blockID: blockID, title: detail["title"] as? String)

        case "program_status_changed":
            guard let record = detail["record"] as? [String: Any],
                  let raw = record["state"] as? String,
                  let state = PetState(rawValue: raw.lowercased()) else { return }
            let title = (record["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (record["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            emit(state, blockID: blockID, title: title)

        case "bell":
            // A bell means the terminal wants the human: treat it as blocked.
            emit(.blocked, blockID: blockID, title: "终端在等你")

        case "child_exited":
            let code = detail["exit_code"] as? Int ?? 0
            emit(code == 0 ? .done : .error, blockID: blockID, title: nil)

        default:
            break
        }
    }

    /// Shells mostly report progress instead of program status: the vocabulary is
    /// spinner-oriented, so it needs its own mapping.
    private func progressState(_ raw: String) -> PetState? {
        let value = raw.lowercased()
        if value.contains("block") || value.contains("need") || value.contains("wait") || value.contains("prompt") {
            return .blocked
        }
        if value.contains("error") || value.contains("fail") {
            return .error
        }
        if value.contains("done") || value.contains("success") || value.contains("complete") {
            return .done
        }
        if value.contains("idle") || value.contains("ready") {
            return .idle
        }
        return .working
    }

    private func emit(_ state: PetState, blockID: String?, title: String?) {
        let update = Update(state: state, blockID: blockID, title: title)
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
    }
}
