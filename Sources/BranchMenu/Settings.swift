import Foundation

enum FolderMode: String, CaseIterable, Identifiable, Sendable {
    case mainCheckout
    case newWorktree

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mainCheckout: "Main checkout"
        case .newWorktree: "New worktree"
        }
    }
}

/// User preferences in UserDefaults. SettingsView binds the same keys with @AppStorage.
enum Settings {
    enum Key {
        static let issueTemplate = "issueTemplate"
        static let prTemplate = "prTemplate"
        static let reviewTemplate = "reviewTemplate"
        static let askBeforeStarting = "askBeforeStarting"
        static let folderMode = "folderMode"
        static let worktreeBranchPattern = "worktreeBranchPattern"
        static let extraRepoPaths = "extraRepoPaths"
        static let sessionDays = "sessionDays"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
        static let projectKey = "projectKey"
        static let projectName = "projectName"
        static let prFilter = "prFilter"
        static let showsToday = "showsToday"
        static let summaryEnabled = "summaryEnabled"
        static let windowMode = "windowMode"
        /// "local", or the SSH host new sessions last started on.
        static let startTarget = "startTarget"
    }

    /// ⌥⌘Space (kVK_Space, cmdKey | optionKey). macOS gives it to "Show Finder search window"
    /// until that is turned off under Keyboard Shortcuts › Spotlight.
    static let defaultHotKey = (code: 49, modifiers: 2304, label: "⌥⌘Space")

    static let defaultIssueTemplate = """
        Work on {repo}#{number}: {title}
        {url}

        Read it first with `gh issue view {number}`.
        Propose a plan before you change any code.
        """

    static let defaultPRTemplate = """
        Pick up my PR #{number}: {title}
        {url}

        Check out the branch with `gh pr checkout {number}` and read the review comments with `gh pr view {number} --comments`.
        """

    static let defaultReviewTemplate = """
        Review PR #{number}: {title}
        {url}

        Check it out with `gh pr checkout {number}`, then review the diff for bugs and design problems.
        """

    static let defaultBranchPattern = "issue/{number}-{slug}"

    private static var defaults: UserDefaults { .standard }

    static var issueTemplate: String { defaults.string(forKey: Key.issueTemplate) ?? defaultIssueTemplate }
    static var prTemplate: String { defaults.string(forKey: Key.prTemplate) ?? defaultPRTemplate }
    static var reviewTemplate: String { defaults.string(forKey: Key.reviewTemplate) ?? defaultReviewTemplate }
    static var askBeforeStarting: Bool { defaults.object(forKey: Key.askBeforeStarting) as? Bool ?? true }
    static var folderMode: FolderMode {
        defaults.string(forKey: Key.folderMode).flatMap(FolderMode.init(rawValue:)) ?? .mainCheckout
    }
    static var worktreeBranchPattern: String {
        defaults.string(forKey: Key.worktreeBranchPattern).flatMap { $0.isEmpty ? nil : $0 } ?? defaultBranchPattern
    }
    static var summaryEnabled: Bool { defaults.object(forKey: Key.summaryEnabled) as? Bool ?? true }

    /// Claude app sessions active within this many days are listed (starred ones always).
    static var sessionDays: Int {
        let days = defaults.integer(forKey: Key.sessionDays)
        return days > 0 ? days : 7
    }

    static var hotKey: (code: Int, modifiers: Int, label: String) {
        guard let label = defaults.string(forKey: Key.hotKeyLabel) else { return defaultHotKey }
        return (defaults.integer(forKey: Key.hotKeyCode), defaults.integer(forKey: Key.hotKeyModifiers), label)
    }

    static func setHotKey(code: Int, modifiers: Int, label: String) {
        defaults.set(code, forKey: Key.hotKeyCode)
        defaults.set(modifiers, forKey: Key.hotKeyModifiers)
        defaults.set(label, forKey: Key.hotKeyLabel)
    }

    /// Stored as one path per line so @AppStorage can bind it.
    static var extraRepoPaths: [String] {
        (defaults.string(forKey: Key.extraRepoPaths) ?? "").split(separator: "\n").map(String.init)
    }
}

enum Template {
    static func render(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { text, pair in text.replacingOccurrences(of: "{\(pair.key)}", with: pair.value) }
    }

    /// "Add a dark mode toggle to settings" → "add-a-dark-mode-toggle-to-settings", cut at a word.
    static func slug(_ text: String, maxLength: Int = 40) -> String {
        let words = text.lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : "\(slug)-\(word)"
            if next.count > maxLength { break }
            slug = next
        }
        return slug.isEmpty ? String(words.first?.prefix(maxLength) ?? "work") : slug
    }

    /// "octocat/hello-world" from a github.com issue or PR URL.
    static func ownerAndRepo(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }
}
