import AppKit
import ApplicationServices
import Foundation

@MainActor
final class TextInjector {
    var restoreClipboard = true
    var restoreDelay: TimeInterval = 0.6

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func pasteIntoCurrentFocus(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard isTrusted else {
            throw TextInjectionError.accessibilityPermissionMissing
        }
        guard !isOwnAppFrontmost else {
            copyToClipboard(text)
            throw TextInjectionError.focusedAppIsPTTVoice
        }

        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendPasteKeystroke()
        restoreClipboardIfNeeded(restoreClipboard, restoreDelay, oldString)
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var isOwnAppFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func restoreClipboardIfNeeded(_ shouldRestore: Bool, _ delay: TimeInterval, _ oldString: String?) {
        guard shouldRestore else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let oldString {
                pasteboard.setString(oldString, forType: .string)
            }
        }
    }

    private func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

enum TextInjectionError: LocalizedError {
    case accessibilityPermissionMissing
    case focusedAppIsPTTVoice

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required to paste into the focused app"
        case .focusedAppIsPTTVoice:
            return "PTT Voice is focused; transcript was copied to clipboard instead of pasted"
        }
    }
}
