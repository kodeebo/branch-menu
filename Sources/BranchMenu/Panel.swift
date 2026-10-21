import AppKit
import SwiftUI

/// A borderless panel that can still take keyboard focus, like Spotlight.
final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the overview centered on the screen with the mouse, and hides it when it loses focus.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: OverviewPanel
    private let model: OverviewModel
    private var keyMonitor: Any?
    private var lastHidden = Date.distantPast

    private static let preferredSize = NSSize(width: 1200, height: 720)
    private static let cornerRadius: CGFloat = 16

    init(model: OverviewModel) {
        self.model = model
        panel = OverviewPanel(
            contentRect: NSRect(origin: .zero, size: Self.preferredSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let hosting = NSHostingView(rootView: OverviewView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        panel.contentView = background
        hosting.frame = background.bounds

        model.onClose = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            hide()
        } else if Date().timeIntervalSince(lastHidden) > 0.3 {
            // Clicking the menu bar icon while the panel is open first hides it (it loses focus);
            // without this guard the same click would open it again.
            show()
        }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = NSSize(
                width: min(Self.preferredSize.width, visible.width - 80),
                height: min(Self.preferredSize.height, visible.height - 80)
            )
            // A little above center, where the eye lands first.
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2 + visible.height * 0.04
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        model.prepareForShow()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastHidden = Date()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Draws the panel's own views to a PNG (no screen recording permission needed).
    func snapshot(to url: URL) {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.model.handleKey(event) ? nil : event
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
