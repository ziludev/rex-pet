import AppKit

// `--selftest` runs the headless checks and exits, so CI needs no display.
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
