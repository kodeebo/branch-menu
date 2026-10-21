import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    let store: AppStore
    let registerHotKey: (Int, Int) -> Bool
    let suspendHotKey: () -> Void

    @AppStorage(Settings.Key.sessionDays) private var sessionDays = 7
    @AppStorage(Settings.Key.summaryEnabled) private var summaryEnabled = true
    @AppStorage(Settings.Key.issueTemplate) private var issueTemplate = Settings.defaultIssueTemplate
    @AppStorage(Settings.Key.prTemplate) private var prTemplate = Settings.defaultPRTemplate
    @AppStorage(Settings.Key.reviewTemplate) private var reviewTemplate = Settings.defaultReviewTemplate
    @AppStorage(Settings.Key.askBeforeStarting) private var askBeforeStarting = true
    @AppStorage(Settings.Key.folderMode) private var folderMode = FolderMode.mainCheckout
    @AppStorage(Settings.Key.worktreeBranchPattern) private var branchPattern = Settings.defaultBranchPattern
    @AppStorage(Settings.Key.extraRepoPaths) private var extraRepoPaths = ""

    var body: some View {
        Form {
            Section("Start now") {
                Toggle("Show the starter text before starting", isOn: $askBeforeStarting)
                Picker("Folder", selection: $folderMode) {
                    ForEach(FolderMode.allCases) { Text($0.label).tag($0) }
                }
                TextField("Worktree branch", text: $branchPattern)
                    .font(.system(size: 12, design: .monospaced))
                Text("For issues. Use {number} and {slug}. Worktrees go in <repo>/.claude/worktrees/. PRs use their own branch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Starter text") {
                templateEditor("Issues", $issueTemplate)
                templateEditor("Your PRs", $prTemplate)
                templateEditor("PR reviews", $reviewTemplate)
                HStack {
                    Text("Placeholders: {repo} {number} {title} {url} {branch} {labels}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to defaults") {
                        issueTemplate = Settings.defaultIssueTemplate
                        prTemplate = Settings.defaultPRTemplate
                        reviewTemplate = Settings.defaultReviewTemplate
                    }
                }
            }

            Section("Repositories") {
                ForEach(store.repos, id: \.key) { repo in
                    LabeledContent(repo.name) {
                        Text((repo.root as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Found from the folders you used Claude Code in during the last three weeks, plus any folders added below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(extraPaths, id: \.self) { path in
                    HStack {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button {
                            extraRepoPaths = extraPaths.filter { $0 != path }.joined(separator: "\n")
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                Button("Add folder…", action: addFolders)
            }

            Section("Sessions") {
                Stepper(value: $sessionDays, in: 1...60) {
                    Text("Show Claude app sessions active in the last \(sessionDays) day\(sessionDays == 1 ? "" : "s")")
                }
                Text("Starred sessions always show; archived ones never do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Next up") {
                Toggle("Write a short summary with Claude (Sonnet)", isOn: $summaryEnabled)
                Text(Assistant.cliPath == nil
                     ? "Needs the Claude Code CLI (claude) installed."
                     : "Runs `claude -p` on your Claude login when the panel opens, at most every 10 minutes, and on ↻. No tools, no saved session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                LabeledContent("Open the overview") {
                    ShortcutRecorder(register: registerHotKey, suspend: suspendHotKey)
                }
                Text("A global shortcut wins over the app in front, but not over macOS's own shortcuts. For ⌥⌘Space, turn off \u{201C}Show Finder search window\u{201D} in System Settings › Keyboard › Keyboard Shortcuts › Spotlight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 600)
    }

    private var extraPaths: [String] {
        extraRepoPaths.split(separator: "\n").map(String.init)
    }

    private func templateEditor(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var paths = extraPaths
        for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
        extraRepoPaths = paths.joined(separator: "\n")
    }
}

/// Click, then press the new shortcut. Esc cancels.
private struct ShortcutRecorder: View {
    let register: (Int, Int) -> Bool
    let suspend: () -> Void

    @AppStorage(Settings.Key.hotKeyLabel) private var label = Settings.defaultHotKey.label
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(monitor == nil ? label : "Press a shortcut…") {
                if monitor == nil { start() } else { stop(restore: true) }
            }
            .pointerStyle(.link)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { if monitor != nil { stop(restore: true) } }
    }

    private func start() {
        error = nil
        // Free the current shortcut so pressing it again can be recorded.
        suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop(restore: true)
                return nil
            }
            guard let shortcut = HotKey.shortcut(from: event) else {
                error = "Use ⌘, ⌥ or ⌃ together with a key."
                return nil
            }
            if register(shortcut.code, shortcut.modifiers) {
                Settings.setHotKey(code: shortcut.code, modifiers: shortcut.modifiers, label: shortcut.label)
                label = shortcut.label
                stop(restore: false)
            } else {
                error = "\(shortcut.label) is already used by another app."
                stop(restore: true)
            }
            return nil
        }
    }

    private func stop(restore: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if restore {
            let current = Settings.hotKey
            _ = register(current.code, current.modifiers)
        }
    }
}
