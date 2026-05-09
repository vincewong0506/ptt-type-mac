import AppKit
import OSLog

// Watches for "hold Ctrl alone" as the system-microphone PTT trigger.
//
// Pure Ctrl is also used as a modifier (Ctrl+C, Ctrl+space, Ctrl+arrow).
// The discrimination is:
//   1. Ctrl-down: enter `.tentative` and emit `.tentative` event. The
//      receiver may pre-warm capture but should not commit user-visible
//      "Listening" state yet — there'd be a flicker on every Ctrl shortcut.
//   2. Within `pttGraceWindow` (200 ms):
//        - any non-modifier keyDown → `.abort` (Ctrl was a shortcut prefix)
//        - Ctrl up → `.abort` (was a quick tap)
//        - any other modifier joining (Cmd, Shift, Option…) → `.abort`
//        - none of the above → grace expires → `.commit` (real PTT)
//   3. After commit, only Ctrl-up matters → `.release`.
//
// Both global and local NSEvent monitors are installed so the hotkey works
// whether the app is focused or in the background. Global monitors require
// Accessibility permission, which the app already requests for paste
// injection.
@MainActor
final class PTTHotkeyMonitor {
    enum Event: Equatable {
        /// Speculative start. Capture may begin but UI should stay calm.
        case tentative
        /// Confirmed PTT. Lift UI to "Listening".
        case commit
        /// Ctrl released after commit — finalize and transcribe.
        case release
        /// Cancel: discard any speculative capture, restore UI to idle.
        case abort
    }

    static let pttGraceWindow: TimeInterval = 0.20

    var onEvent: ((Event) -> Void)?

    /// Setting this to true installs the NSEvent monitors. Setting it to
    /// false uninstalls them and emits `.abort` if a session was in flight.
    var isEnabled: Bool = false {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled { install() } else { uninstall() }
        }
    }

    private enum State {
        case idle
        case tentative
        case committed
    }

    private var state: State = .idle
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var graceTimer: Timer?
    private let logger = Logger(subsystem: "com.pttcoding.PTTVoice", category: "Hotkey")

    init() {}

    private func install() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // Global monitor closure runs on main thread already, but hop
            // through a Task to satisfy MainActor isolation.
            Task { @MainActor in self?.handle(event: event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
            return event
        }
        logger.debug("PTT hotkey monitor installed")
    }

    private func uninstall() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        cancelGraceTimer()
        if state != .idle {
            state = .idle
            onEvent?(.abort)
        }
        logger.debug("PTT hotkey monitor uninstalled")
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .flagsChanged: handleFlagsChanged(event.modifierFlags)
        case .keyDown:      handleKeyDown()
        default: break
        }
    }

    private func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        // Strict "Ctrl alone" — no Cmd / Shift / Option / CapsLock / Fn.
        let foreign: NSEvent.ModifierFlags = [.command, .shift, .option, .capsLock, .function]
        let ctrlAlone = flags.contains(.control) && flags.intersection(foreign).isEmpty
        let ctrlReleased = !flags.contains(.control)

        switch state {
        case .idle:
            if ctrlAlone {
                state = .tentative
                onEvent?(.tentative)
                scheduleGraceTimer()
            }
        case .tentative:
            if ctrlReleased {
                cancelGraceTimer()
                state = .idle
                onEvent?(.abort)
            } else if !ctrlAlone {
                // Another modifier joined while we were waiting — Ctrl was
                // part of a shortcut after all.
                cancelGraceTimer()
                state = .idle
                onEvent?(.abort)
            }
        case .committed:
            if ctrlReleased {
                state = .idle
                onEvent?(.release)
            }
            // If a different modifier joins post-commit, ignore — the user
            // is intentionally holding PTT and may also use modifiers
            // unintentionally; safer to keep the session running.
        }
    }

    private func handleKeyDown() {
        // Only matters during the tentative window. After commit the user
        // is recording on purpose; let them type if they want.
        guard state == .tentative else { return }
        cancelGraceTimer()
        state = .idle
        onEvent?(.abort)
    }

    private func scheduleGraceTimer() {
        cancelGraceTimer()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.pttGraceWindow,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .tentative else { return }
                self.state = .committed
                self.onEvent?(.commit)
            }
        }
        graceTimer = timer
    }

    private func cancelGraceTimer() {
        graceTimer?.invalidate()
        graceTimer = nil
    }
}
