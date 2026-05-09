import AppKit
import Combine
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()

    private var compactPanel: NSPanel?
    private var debugWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory hides the Dock icon and keeps the app out of Cmd+Tab.
        // The user reaches every control through the menu-bar status item;
        // the floating panel (level=.floating) stays visible regardless.
        NSApp.setActivationPolicy(.accessory)
        model.onToggleDebugWindow = { [weak self] in
            self?.toggleDebugWindow()
        }
        // Floating panel taps the "需要下载" hint → ensure Settings is open
        // and frontmost. Use the always-open path, NOT the toggle, so a
        // second tap doesn't accidentally close the window the user just
        // wanted to act on.
        model.onRequestOpenSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        setupStatusBarItem()
        showCompactPanel()
        observeStateForStatusIcon()
        model.startScan()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === debugWindow {
            model.setDebugWindowVisible(false)
        }
    }

    // MARK: - Status bar

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildStatusMenu()
        statusItem = item
        updateStatusIcon()
    }

    private func observeStateForStatusIcon() {
        // streamState mutates on every audio packet; pluck out the bit that
        // actually drives the icon so we don't re-render the menu-bar 100x/sec.
        model.$streamState
            .map(\.remoteState)
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        model.$connectionState
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        // isCapturingAudio + inputSource cover the mic-mode lifecycle that
        // streamState/connectionState don't see. Without this, mic-mode
        // sessions wouldn't refresh the menu-bar tooltip.
        model.$isCapturingAudio
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
        model.$inputSource
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        // Use the app icon (colored) instead of an SF Symbol — the user
        // wanted the brand mark visible in the menu bar. State distinction
        // is conveyed via tooltip only; we don't try to encode it in the
        // icon shape because the colored icon doesn't compose well with
        // overlays at menu-bar size.
        let icon = NSImage(named: "AppIcon")
        // Standard menu-bar icon size on macOS is 18 pt. Asset catalog
        // ships 16/32/128/256/512 — system picks the right scale based
        // on the requested size and screen DPI.
        icon?.size = NSSize(width: 18, height: 18)
        // Keep colors. isTemplate=true would strip the green and only
        // render the silhouette, which loses brand identity.
        icon?.isTemplate = false
        button.image = icon
        button.toolTip = statusBarTooltip
    }

    private var statusBarTooltip: String {
        if model.isCapturingAudio {
            return "PTT Voice — Recording"
        }
        switch model.inputSource {
        case .systemMicrophone:
            return "PTT Voice — Ready (system microphone)"
        case .bleDevice:
            if model.connectionState == .subscribed {
                return "PTT Voice — Ready (BLE)"
            }
            return "PTT Voice — \(model.connectionState.displayName)"
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let settings = NSMenuItem(
            title: "Settings & Details…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let panelToggle = NSMenuItem(
            title: "Floating Panel",
            action: #selector(toggleCompactPanel),
            keyEquivalent: ""
        )
        panelToggle.target = self
        menu.addItem(panelToggle)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit PTT Voice",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openSettings() {
        // Toggle: open if hidden, hide if already showing. The status-menu
        // checkmark beside this item reflects the same state.
        toggleDebugWindow()
    }

    @objc private func toggleCompactPanel() {
        if let panel = compactPanel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            showCompactPanel()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Windows

    private func showCompactPanel() {
        if let compactPanel {
            compactPanel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
            // .borderless drops the title-bar safe area that wasted 22px at
            // the top. .nonactivatingPanel means clicking the floater does
            // not steal focus from whatever the user is typing into.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Transparent NSPanel + SwiftUI .regularMaterial inside gives the
        // proper macOS vibrancy with rounded corners and a soft drop shadow.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 340, height: 110)
        panel.maxSize = NSSize(width: 340, height: 110)
        let hostingView = NSHostingView(
            rootView: CompactPanelView()
                .environmentObject(model)
        )
        // Match the window background to the SwiftUI rounded clipShape so
        // there's no opaque rectangle bleeding through the corners.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        compactPanel = panel
    }

    private func toggleDebugWindow() {
        if model.isExpanded {
            debugWindow?.orderOut(nil)
            model.setDebugWindowVisible(false)
            return
        }

        showDebugWindow()
        model.setDebugWindowVisible(true)
    }

    // One-way "show and front" — used by the floating-panel "open Settings"
    // hint where toggling would surprise the user.
    private func showSettingsWindow() {
        if model.isExpanded, let debugWindow {
            debugWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showDebugWindow()
        model.setDebugWindowVisible(true)
    }

    private func showDebugWindow() {
        if let debugWindow {
            debugWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // NSHostingController (not raw NSHostingView) owns the SwiftUI layout
        // pass for the window. With a bare NSHostingView, NavigationSplitView's
        // resizable columns and the window's own layout pass fight over
        // -layoutSubtreeIfNeeded and SwiftUI logs a recursion warning + fails
        // to render on the first open. Routing through a controller resolves it.
        let hosting = NSHostingController(
            rootView: ContentView()
                .environmentObject(model)
        )
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 560))
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.title = "PTT Voice Details"
        // NSWindow defaults isReleasedWhenClosed to true, which dealloc's the
        // window when the user clicks the red close button. Our debugWindow
        // strong ref then dangles and the next showDebugWindow() crashes in
        // objc_retain. Keep the window alive so the same instance is reused.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }
}

extension AppDelegate: NSMenuDelegate {
    // Refresh the toggleable items' state right before the menu shows, so
    // checkmarks always reflect actual window visibility.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(openSettings):
                item.state = model.isExpanded ? .on : .off
            case #selector(toggleCompactPanel):
                item.state = (compactPanel?.isVisible ?? false) ? .on : .off
            default:
                break
            }
        }
    }
}
