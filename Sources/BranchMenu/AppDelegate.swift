import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AppStore()
    private lazy var model = OverviewModel(store: store)
    private var panel: PanelController?
    private var window: OverviewWindowController?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?
    private var logWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump") {
            Task {
                await store.refreshAndWait()
                // `--query <text>` prints what a search shows in each column instead.
                if let index = CommandLine.arguments.firstIndex(of: "--query"), index + 1 < CommandLine.arguments.count {
                    model.query = CommandLine.arguments[index + 1]
                    for column in Column.allCases {
                        print("== \(column)")
                        for item in model.items(column) { print("  \(item.searchText.prefix(100))") }
                    }
                } else {
                    Dump.print(store.overview)
                }
                exit(0)
            }
            return
        }

        Log.info("app", "Branch Menu started (\(ProcessInfo.processInfo.operatingSystemVersionString))")
        installMainMenu()
        let panel = PanelController(model: model)
        self.panel = panel
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.onOpenWindow = { [weak self] in self?.openWindow() }
        model.onOpenLog = { [weak self] in self?.openLog() }
        // After opening a session or a link: the panel gets out of the way, the window stays.
        model.onClose = { [weak self] in
            if self?.window?.isVisible != true { self?.panel?.hide() }
        }
        installStatusItem()
        hotKey = HotKey { [weak self] in self?.toggleOverview() }
        let shortcut = Settings.hotKey
        hotKey?.register(keyCode: shortcut.code, modifiers: shortcut.modifiers)
        store.onChange = { [weak self] in self?.updateStatusItem() }
        store.startPolling()
        if UserDefaults.standard.bool(forKey: Settings.Key.windowMode) { openWindow() }

        // `--show` opens the overview at launch; `--snapshot <file.png>` also renders it to a file
        // and quits. Both are for checking the UI without clicking.
        let args = CommandLine.arguments
        if args.contains("--show") || args.contains("--snapshot") {
            Task {
                await store.refreshAndWait()
                panel.show()
                if args.contains("--hover"), let item = model.items(.sessions).first(where: {
                    if case .session(let s) = $0.kind { s.recap != nil } else { false }
                }), case .session(let session) = item.kind {
                    // Roughly where the first rows of the Sessions column sit.
                    model.hover = HoverTarget(session: session, frame: CGRect(x: 16, y: 420, width: 380, height: 54))
                }
                if args.contains("--compose") {
                    let issue = model.items(.issues).first { $0.linkedSessions.isEmpty }
                    model.startNew(issue)
                }
                if let index = args.firstIndex(of: "--query"), index + 1 < args.count {
                    model.query = args[index + 1]
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
            button.image = BranchMark.statusImage(waiting: 0)
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
            menu.addItem(withTitle: "Open as Window", action: #selector(openWindow), keyEquivalent: "")
            menu.addItem(withTitle: "Refresh", action: #selector(refreshAll), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "Show Log", action: #selector(openLog), keyEquivalent: "l")
            menu.addItem(withTitle: "Quit Branch Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            toggleOverview()
        }
    }

    /// The hotkey and the menu bar icon: the window when it is open, else the panel.
    private func toggleOverview() {
        guard let window, window.isVisible else {
            panel?.toggle()
            return
        }
        if window.isFrontmost { NSApp.hide(nil) } else { window.show() }
    }

    @objc private func openWindow() {
        panel?.hide()
        if window == nil {
            let controller = OverviewWindowController(model: model)
            controller.onClose = { [weak self] in
                UserDefaults.standard.set(false, forKey: Settings.Key.windowMode)
                self?.model.isInWindow = false
            }
            window = controller
        }
        UserDefaults.standard.set(true, forKey: Settings.Key.windowMode)
        model.isInWindow = true
        window?.show()
    }

    private func updateStatusItem() {
        let waiting = store.overview.waitingCount
        statusItem?.button?.image = BranchMark.statusImage(waiting: waiting)
        statusItem?.button?.toolTip = waiting > 0
            ? "\(waiting) session\(waiting == 1 ? "" : "s") waiting for you · \(Settings.hotKey.label)"
            : "Branch Menu · \(Settings.hotKey.label)"
    }

    @objc private func togglePanel() { toggleOverview() }

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

    @objc private func openLog() {
        panel?.hide()
        if logWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LogView()))
            window.title = "Branch Menu Log"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 900, height: 520))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("BranchMenuLog")
            logWindow = window
        }
        NSApp.activate()
        logWindow?.makeKeyAndOrderFront(nil)
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
        Swift.print("== Next up")
        for next in NextUp.items(prs: overview.prs, issues: overview.issues) {
            Swift.print("  \(next.action) \(next.title.prefix(50))  [\(next.reason)]")
        }
        for column in Column.allCases {
            Swift.print("\n== \(column.title)")
            var section = ""
            for item in overview.items(column) {
                if item.section != section {
                    section = item.section
                    Swift.print("  -- \(section)")
                }
                Swift.print("  \(describe(item))")
                if case .session(let s) = item.kind, let recap = s.recap {
                    Swift.print("       recap: \(recap.prefix(140).replacingOccurrences(of: "\n", with: " "))…")
                }
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
