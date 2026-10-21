import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AppStore()
    private lazy var model = OverviewModel(store: store)
    private var panel: PanelController?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump") {
            Task {
                await store.refreshAndWait()
                Dump.print(store.overview)
                exit(0)
            }
            return
        }

        installMainMenu()
        let panel = PanelController(model: model)
        self.panel = panel
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        installStatusItem()
        hotKey = HotKey { [weak self] in self?.panel?.toggle() }
        let shortcut = Settings.hotKey
        hotKey?.register(keyCode: shortcut.code, modifiers: shortcut.modifiers)
        store.onChange = { [weak self] in self?.updateStatusItem() }
        store.startPolling()

        // `--show` opens the overview at launch; `--snapshot <file.png>` also renders it to a file
        // and quits. Both are for checking the UI without clicking.
        let args = CommandLine.arguments
        if args.contains("--show") || args.contains("--snapshot") {
            Task {
                await store.refreshAndWait()
                panel.show()
                if args.contains("--compose") {
                    let issue = model.items(.issues).first { $0.linkedSessions.isEmpty }
                    model.startNew(issue)
                }
                if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
                    try? await Task.sleep(for: .seconds(1))
                    panel.snapshot(to: URL(fileURLWithPath: args[index + 1]))
                    exit(0)
                }
            }
        }
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch Menu")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Overview  \(Settings.hotKey.label)", action: #selector(togglePanel), keyEquivalent: "")
            menu.addItem(withTitle: "Refresh", action: #selector(refreshAll), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "Quit Branch Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            panel?.toggle()
        }
    }

    private func updateStatusItem() {
        let waiting = store.overview.waitingCount
        statusItem?.button?.title = waiting > 0 ? " \(waiting)" : ""
        statusItem?.button?.toolTip = waiting > 0
            ? "\(waiting) session\(waiting == 1 ? "" : "s") waiting for you · \(Settings.hotKey.label)"
            : "Branch Menu · \(Settings.hotKey.label)"
    }

    @objc private func togglePanel() { panel?.toggle() }

    @objc private func refreshAll() { model.refreshAll() }

    // MARK: Settings

    @objc private func openSettings() {
        panel?.hide()
        if settingsWindow == nil {
            let view = SettingsView(
                store: store,
                registerHotKey: { [weak self] code, modifiers in
                    self?.hotKey?.register(keyCode: code, modifiers: modifiers) ?? false
                },
                suspendHotKey: { [weak self] in self?.hotKey?.unregister() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Branch Menu Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 600, height: 720))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A menu-bar-only app has no visible menu, but text fields still need an Edit menu
    /// for ⌘C, ⌘V, ⌘A and ⌘Z to work.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Branch Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

/// `BranchMenu --dump` prints the three columns, for checking the data without the UI.
enum Dump {
    @MainActor
    static func print(_ overview: Overview) {
        for error in overview.errors { Swift.print("! \(error)") }
        for column in Column.allCases {
            Swift.print("\n== \(column.title)")
            var section = ""
            for item in overview.items(column) {
                if item.section != section {
                    section = item.section
                    Swift.print("  -- \(section)")
                }
                Swift.print("  \(describe(item))")
                let sessions = item.linkedSessions.map(\.name)
                if case .session = item.kind {} else if !sessions.isEmpty {
                    Swift.print("       sessions: \(sessions.joined(separator: " | "))")
                }
            }
        }
    }

    private static func describe(_ item: OverviewItem) -> String {
        switch item.kind {
        case .session(let s):
            let pr = item.branchPR.map { " #\($0.number)" } ?? ""
            return "\(s.name)  [\(item.repo?.name ?? "?") · \(item.branch ?? "?")\(pr)]  \(s.host?.name ?? "?")"
        case .myPR(let pr):
            let closes = pr.closes.isEmpty ? "" : "  closes \(pr.closes.map { "#\($0)" }.joined(separator: ","))"
            return "#\(pr.number) \(pr.title)  [\(pr.review?.rawValue ?? "-") · checks \(pr.checks.state)]\(closes)"
        case .review(let pr):
            return "#\(pr.number) \(pr.title)  [@\(pr.authorLogin)]"
        case .issue(let issue):
            let prs = item.linkedPRNumbers.map { "#\($0)" }.joined(separator: ",")
            return "#\(issue.number) \(issue.title)\(prs.isEmpty ? "" : "  PR \(prs)")"
        }
    }
}
