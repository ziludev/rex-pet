import AppKit

/// The one bit of the pet you can hear. Everything else is silent on purpose:
/// a clipped desktop pet that beeps on every state change is worse than none.
///
/// `done` is the only state that chimes — `blocked` and `error` keep their
/// notification, because those are the ones that have to reach you when you
/// are looking elsewhere.
enum PetChime {
    /// Kept pure so `--selftest` can check the rule without an audio device.
    static func shouldPlay(from previous: PetState, to next: PetState, enabled: Bool) -> Bool {
        enabled && next == .done && previous != .done
    }

    static func play() {
        // Glass is the system sound most people already associate with a task
        // finishing; fall back to something if the user's system lacks it.
        let sound = NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Tink"))
        if sound == nil {
            NSSound.beep()
        } else {
            sound?.play()
        }
    }
}
