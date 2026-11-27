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

    /// Connection state, shown in the menu bar.
    enum Status {
        case starting
        case running
        case stopped
        case missingBinary

        var label: String {
            switch self {
            case .starting: return L10n.t("connecting", "连接中")
            case .running: return L10n.t("listening", "监听中")
            case .stopped: return L10n.t("not running", "未运行")
            case .missingBinary: return L10n.t("no rex found", "找不到 rex")
            }
        }
    }

    var onUpdate: ((Update) -> Void)?
    var onStatus: ((Status) -> Void)?
    var onLog: ((String) -> Void)?

    private var process: Process?
    private var outHandle: FileHandle?
    private var errHandle: FileHandle?
    private let parseQueue = DispatchQueue(label: "dev.zilu.rexpet.watcher.parse")
    private var buffer = Data()
    private let maxBufferedBytes = 1_048_576
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
        outHandle?.readabilityHandler = nil
        errHandle?.readabilityHandler = nil
        outHandle = nil
        errHandle = nil
        process?.terminate()
        process = nil
        parseQueue.async { [weak self] in self?.buffer.removeAll() }
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
            // Keep retrying: installing Rex after the pet started should just work,
            // and the status is what the menu and the one-off bubble read.
            setStatus(.missingBinary)
            onLog?("no rex binary found, retrying in 30s")
            scheduleRetry(after: 30)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = ["events", "--all", "--json"]

        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        outHandle = out.fileHandleForReading
        errHandle = err.fileHandleForReading

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.parseQueue.async { [weak self] in self?.ingest(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onLog?("stderr: \(trimmed)") }
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                // Ignore stale terminations from an earlier process replaced by restart().
                guard self.process === finished else { return }
                self.outHandle = nil
                self.errHandle = nil
                self.process = nil
                guard !self.stopped else { return }
                self.onLog?("rex events exited, status=\(finished.terminationStatus), reconnecting in \(Int(self.retryDelay))s")
                self.setStatus(.starting)
                self.scheduleRetry(after: self.retryDelay)
                // Back off so a broken rex install does not spin the CPU.
                self.retryDelay = min(self.retryDelay * 2, 30)
            }
        }

        do {
            try task.run()
            process = task
            setStatus(.running)
            retryDelay = 2
            parseQueue.async { [weak self] in self?.buffer.removeAll() }
        } catch {
            outHandle?.readabilityHandler = nil
            errHandle?.readabilityHandler = nil
            outHandle = nil
            errHandle = nil
            setStatus(.stopped)
            onLog?("could not start rex events: \(error.localizedDescription)")
            scheduleRetry(after: 10)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.launch() }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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
            if let update = Self.parse(line: Data(line)) {
                DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
            }
        }
        // Guard against unbounded memory growth on malformed streams with no newlines.
        if buffer.count > maxBufferedBytes {
            buffer.removeAll(keepingCapacity: false)
        }
    }

    static func parse(line: Data) -> Update? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        guard object["type"] as? String == "session_event",
              let payload = object["payload"] as? [String: Any],
              let inner = payload["event"] as? [String: Any] else { return nil }

        let innerType = inner["type"] as? String

        if innerType == "block_closed",
           let blockPayload = inner["payload"] as? [String: Any],
           let closed = blockPayload["block_id"] as? String {
            return Update(state: .idle, blockID: closed, title: nil)
        }

        guard innerType == "block_event",
              let blockPayload = inner["payload"] as? [String: Any] else { return nil }

        // Only the terminal's own blocks speak the vocabulary we care about.
        if let creator = blockPayload["creator_name"] as? String, creator != "com.superlogical.terminal" {
            return nil
        }

        let blockID = blockPayload["block_id"] as? String
        let name = blockPayload["name"] as? String ?? ""
        let detail = blockPayload["payload"] as? [String: Any] ?? [:]

        switch name {
        case "progress_report":
            guard let raw = detail["state"] as? String,
                  let state = progressState(raw) else { return nil }
            let title = (detail["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Update(state: state, blockID: blockID, title: title)

        case "program_status_changed":
            guard let record = detail["record"] as? [String: Any],
                  let raw = record["state"] as? String,
                  let state = PetState(rawValue: raw.lowercased()) else { return nil }
            let title = (record["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (record["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Update(state: state, blockID: blockID, title: title)

        case "bell":
            // A bell means the terminal wants the human: treat it as blocked.
            return Update(state: .blocked, blockID: blockID, title: L10n.t("a terminal is waiting", "终端在等你"))

        case "child_exited":
            let code = detail["exit_code"] as? Int ?? 0
            return Update(state: code == 0 ? .done : .error, blockID: blockID, title: nil)

        default:
            return nil
        }
    }

    /// Shells mostly report progress instead of program status: the vocabulary is
    /// spinner-oriented, so it needs its own mapping.
    private static func progressState(_ raw: String) -> PetState? {
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
}
