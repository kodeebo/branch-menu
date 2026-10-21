import AppKit
import Carbon.HIToolbox
import Observation

/// UI state for the overview panel: search, selection, keyboard navigation and the start composer.
@MainActor
@Observable
final class OverviewModel {
    let store: AppStore
    var query = ""
    private(set) var column: Column = .sessions
    var composer: ComposerModel?
    /// Bumped each time the panel opens, so the view refocuses the search field.
    private(set) var focusToken = 0

    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    private var selection: [Column: String] = [:]

    init(store: AppStore) {
        self.store = store
    }

    // MARK: Items and selection

    func items(_ column: Column) -> [OverviewItem] {
        let all = store.overview.items(column)
        let tokens = query.lowercased().split(separator: " ")
        guard !tokens.isEmpty else { return all }
        return all.filter { item in tokens.allSatisfy { item.searchText.contains($0) } }
    }

    func selectedID(in column: Column) -> String? {
        let items = items(column)
        if let id = selection[column], items.contains(where: { $0.id == id }) { return id }
        return items.first?.id
    }

    var selectedItem: OverviewItem? {
        guard let id = selectedID(in: column) else { return nil }
        return items(column).first { $0.id == id }
    }

    var linkedIDs: Set<String> { selectedItem?.linked ?? [] }

    /// Rows name their repo only when the column mixes several.
    func showsRepo(in column: Column) -> Bool {
        Set(store.overview.items(column).compactMap { $0.repo?.key }).count > 1
    }

    func select(_ item: OverviewItem) {
        column = item.column
        selection[item.column] = item.id
    }

    func focus(_ column: Column) {
        self.column = column
    }

    private func move(_ delta: Int) {
        let items = items(column)
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID(in: column) } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        selection[column] = items[next].id
    }

    private func switchColumn(_ delta: Int) {
        let all = Column.allCases
        column = all[(column.rawValue + delta + all.count) % all.count]
    }

    // MARK: Actions

    func prepareForShow() {
        composer = nil
        query = ""
        focusToken += 1
        store.fetchGitHub(maxAge: 60)
    }

    /// The row's main action: a session opens in the Claude app (or its terminal); a PR or
    /// issue opens on GitHub. Their sessions are listed under them and open on their own.
    func activate(_ item: OverviewItem?) {
        guard let item else { return }
        if case .session(let session) = item.kind {
            open(session)
        } else {
            openOnGitHub(item)
        }
    }

    func open(_ session: LiveSession) {
        Focus.session(session)
        onClose?()
    }

    /// Always a new session: for a session row, another one in the same folder.
    func startNew(_ item: OverviewItem?) {
        guard let item else { return }
        if case .session(let session) = item.kind {
            Focus.newSession(folder: session.cwd, text: "")
            onClose?()
            return
        }
        guard let draft = ComposerModel(item: item) else { return }
        if Settings.askBeforeStarting {
            composer = draft
        } else {
            composer = draft
            Task { await startComposer() }
        }
    }

    func closeComposer() {
        composer = nil
        focusToken += 1
    }

    func startComposer() async {
        guard let composer, !composer.isStarting else { return }
        composer.isStarting = true
        composer.error = nil
        do {
            try await Starter.start(
                repoRoot: composer.repo.root,
                worktreeBranch: composer.folderMode == .newWorktree ? composer.branch : nil,
                text: composer.text
            )
            self.composer = nil
            onClose?()
        } catch {
            composer.error = error.localizedDescription
            composer.isStarting = false
        }
    }

    /// Sessions refresh every 2 seconds on their own; this also refetches GitHub right away.
    func refreshAll() {
        Task { await store.refresh() }
        store.fetchGitHub(maxAge: 0)
    }

    func openOnGitHub(_ item: OverviewItem?) {
        guard let url = item?.url else { return }
        NSWorkspace.shared.open(url)
        onClose?()
    }

    // MARK: Keyboard

    /// Returns true when the key was handled. Text keys fall through to the search field.
    func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let code = Int(event.keyCode)
        let isReturn = code == kVK_Return || code == kVK_ANSI_KeypadEnter

        if composer != nil {
            switch true {
            case code == kVK_Escape:
                closeComposer()
                return true
            case isReturn && command:
                Task { await startComposer() }
                return true
            default:
                return false
            }
        }

        switch code {
        case kVK_Escape:
            if query.isEmpty { onClose?() } else { query = "" }
            return true
        case kVK_DownArrow:
            move(1)
            return true
        case kVK_UpArrow:
            move(-1)
            return true
        case kVK_Tab:
            switchColumn(shift ? -1 : 1)
            return true
        case _ where isReturn:
            if command { startNew(selectedItem) } else { activate(selectedItem) }
            return true
        default:
            break
        }

        guard command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "1": column = .sessions
        case "2": column = .prs
        case "3": column = .issues
        case "o": openOnGitHub(selectedItem)
        case "r": refreshAll()
        case ",": onOpenSettings?()
        default: return false
        }
        return true
    }
}

/// The "Start a session" sheet: where it runs and the starter text, both editable.
@MainActor
@Observable
final class ComposerModel {
    let repo: RepoRef
    let heading: String
    var text: String
    var folderMode: FolderMode
    var branch: String
    var error: String?
    var isStarting = false

    init?(item: OverviewItem) {
        guard let repo = item.repo, let number = item.number, let url = item.url else { return nil }
        let title: String
        let template: String
        let branch: String
        var labels = ""
        switch item.kind {
        case .session:
            return nil
        case .myPR(let pr):
            (title, template, branch) = (pr.title, Settings.prTemplate, pr.branch)
        case .review(let pr):
            (title, template, branch) = (pr.title, Settings.reviewTemplate, pr.branch)
        case .issue(let issue):
            title = issue.title
            template = Settings.issueTemplate
            labels = issue.labels.joined(separator: ", ")
            branch = Template.render(Settings.worktreeBranchPattern, [
                "number": String(number), "slug": Template.slug(issue.title),
            ])
        }

        self.repo = repo
        self.heading = "#\(number) \(title)"
        self.branch = branch
        self.folderMode = Settings.folderMode
        self.text = Template.render(template, [
            "repo": Template.ownerAndRepo(from: url) ?? repo.name,
            "number": String(number),
            "title": title,
            "url": url.absoluteString,
            "branch": branch,
            "labels": labels,
        ])
    }
}
