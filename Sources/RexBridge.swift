import Foundation

/// Thin wrapper over the `rex` CLI. Mirrors rex-beacon's `rexcli.BlockWrite`:
/// `rex block call -b <block> write '{"data":"..."}'`.
enum RexBridge {
    /// UserDefaults key holding a `rex` path picked from the menu.
    static let binPathDefaultsKey = "rexBinPath"

    static func binary() -> String? {
        var candidates: [String] = []

        // A GUI-launched app inherits launchd's minimal PATH, so a rex installed by
        // a package manager is usually invisible here. A picked path or the common
        // install locations cover that case.
        if let picked = UserDefaults.standard.string(forKey: binPathDefaultsKey), !picked.isEmpty {
            candidates.append(picked)
        }
        if let explicit = ProcessInfo.processInfo.environment["REX_PET_REX_BIN"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let binDir = ProcessInfo.processInfo.environment["REX_BIN_DIR"], !binDir.isEmpty {
            candidates.append(binDir + "/rex")
        }
        if let path = searchPath("rex") { candidates.append(path) }
        let home = NSHomeDirectory()
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", home + "/.local/bin", home + "/bin"] {
            candidates.append(dir + "/rex")
        }
        candidates.append(home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex")
        candidates.append(contentsOf: versionedRexBinaries(home: home))
        candidates.append("/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex")

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Newest `Versions/<build>/Rex Server.app/Contents/MacOS/rex` when `Current`
    /// is a real directory rather than the symlink we expect.
    private static func versionedRexBinaries(home: String) -> [String] {
        let root = home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries
            .sorted(by: >)
            .map { root + "/" + $0 + "/Rex Server.app/Contents/MacOS/rex" }
    }

    private static func searchPath(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let full = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    /// Writes raw bytes to a terminal block. Call completion on the main queue.
    static func write(blockID: String, text: String, completion: @escaping (Bool, String?) -> Void) {
        guard let payload = jsonPayload(data: text) else {
            completion(false, L10n.t("could not encode the payload", "参数编码失败"))
            return
        }
        run(["block", "call", "-b", blockID, "write", payload], completion: completion)
    }

    /// Brings a pane to the front in Rex, so a click on the cat can lead to the
    /// agent that is actually waiting.
    static func focus(blockID: String, completion: @escaping (Bool, String?) -> Void) {
        run(["focus", blockID], completion: completion)
    }

    /// Runs `rex` with arguments and reports success plus stderr on the main queue.
    static func run(_ arguments: [String], completion: @escaping (Bool, String?) -> Void) {
        guard let bin = binary() else {
            completion(false, L10n.t("no rex binary found; set REX_PET_REX_BIN", "找不到 rex 可执行文件，可设 REX_PET_REX_BIN"))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bin)
            process.arguments = arguments

            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
                return
            }
            process.waitUntilExit()

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async {
                completion(ok, ok ? nil : (errText.isEmpty ? L10n.t("rex exited with \(process.terminationStatus)", "rex 退出码 \(process.terminationStatus)") : errText))
            }
        }
    }

    private static func jsonPayload(data: String) -> String? {
        guard let encoded = try? JSONSerialization.data(withJSONObject: ["data": data]) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
}
