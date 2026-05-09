import AppKit
import SwiftUI

struct FloatingWindowAccessor: NSViewRepresentable {
    let isExpanded: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .managed
        ]
        window.title = "PTT Voice"
        window.isMovableByWindowBackground = true
        window.minSize = isExpanded ? NSSize(width: 860, height: 560) : NSSize(width: 340, height: 160)
        window.maxSize = isExpanded ? NSSize(width: 10_000, height: 10_000) : NSSize(width: 340, height: 160)
        window.setContentSize(isExpanded ? NSSize(width: 860, height: 560) : NSSize(width: 340, height: 160))
    }
}
