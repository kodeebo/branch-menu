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

    /// Only this repo's sessions, PRs and issues; nil shows every project.
    private(set) var projectKey: String?
    private(set) var projectName: String?
    private(set) var prFilter: PRFilter = .all
    /// PR and issue rows whose session list is open.
    private(set) var expanded: Set<String> = []
    /// The Today strip above the columns (⌘T).
    private(set) var showsToday: Bool
    let notes = NotesStore()
    let assistant = Assistant()

    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onOpenWindow: (() -> Void)?
    /// Shown in the normal window rather than the floating panel.
    var isInWindow = false
    private var selection: [Column: String] = [:]

    enum PRFilter: String {
        case all, mine, review
    }

    init(store: AppStore) {
        self.store = store
        projectKey = UserDefaults.standard.string(forKey: Settings.Key.projectKey)
        projectName = UserDefaults.standard.string(forKey: Settings.Key.projectName)
        prFilter = UserDefaults.standard.string(forKey: Settings.Key.prFilter).flatMap(PRFilter.init) ?? .all
        showsToday = UserDefaults.standard.object(forKey: Settings.Key.showsToday) as? Bool ?? true
    }

    // MARK: Today

    func toggleToday() {
        showsToday.toggle()
        UserDefaults.standard.set(showsToday, forKey: Settings.Key.showsToday)
    }

    var waitingItems: [OverviewItem] {
        projectItems(.sessions).filter { if case .session(let s) = $0.kind { s.status == .waiting } else { false } }
    }

    var nextUp: [NextUpItem] {
        NextUp.items(prs: projectItems(.prs), issues: projectItems(.issues))
    }

    /// The chosen project's main checkout, or every repo that has something to show.
    var localCheckouts: [(RepoRef, LocalState)] {
        let keys: Set<String> = projectKey.map { [$0] }
            ?? Set(Column.allCases.flatMap { store.overview.items($0) }.compactMap { $0.repo?.key })
        return store.repos.filter { keys.contains($0.key) }.compactMap { repo in
            store.localStates[repo.key].map { (repo, $0) }
        }
    }

    func refreshSummary(force: Bool) {
        // A summary of half-loaded data would say there is nothing to do, and stick.
        guard Settings.summaryEnabled, store.overview.githubLoaded, !store.isFetchingGitHub else { return }
        let sessions = waitingItems.compactMap { item -> LiveSession? in
            if case .session(let s) = item.kind { s } else { nil }
        }
        let prs = projectItems(.prs)
        let mine = prs.filter { if case .myPR = $0.kind { true } else { false } }.count
        let state = NextUp.describe(
            project: projectName, local: localCheckouts, waiting: sessions, next: nextUp,
            counts: (mine, prs.count - mine, projectItems(.issues).count)
        )
        let local = localCheckouts.map { "\($0.0.key)@\($0.1.branch)" }
        let fingerprint = (nextUp.map(\.id) + sessions.map(\.id) + local).joined(separator: ",")
        assistant.refresh(state: state, fingerprint: fingerprint, force: force)
    }

    // MARK: Items and selection

    /// The column's rows in the chosen project, before search and the PR pills.
    func projectItems(_ column: Column) -> [OverviewItem] {
        let all = store.overview.items(column)
        guard let projectKey else { return all }
        return all.filter { $0.repo?.key == projectKey }
    }

    func items(_ column: Column) -> [OverviewItem] {
        var items = projectItems(column)
        if column == .prs, prFilter != .all {
            items = items.filter { item in
                switch item.kind {
                case .myPR: prFilter == .mine
                case .review: prFilter == .review
                default: true
                }
            }
        }
        let tokens = query.lowercased().split(separator: " ")
        guard !tokens.isEmpty else { return items }
        return items.filter { item in tokens.allSatisfy { item.searchText.contains($0) } }
    }

    func setProject(_ repo: RepoRef?) {
        projectKey = repo?.key
        projectName = repo?.name
        UserDefaults.standard.set(projectKey, forKey: Settings.Key.projectKey)
        UserDefaults.standard.set(projectName, forKey: Settings.Key.projectName)
        refreshSummary(force: true)
    }

    func isExpanded(_ item: OverviewItem) -> Bool { expanded.contains(item.id) }

    func setExpanded(_ item: OverviewItem, _ open: Bool) {
        if open { expanded.insert(item.id) } else { expanded.remove(item.id) }
    }

    /// Tapping a pill shows only that list; tapping it again shows both.
    func togglePRFilter(_ filter: PRFilter) {
        prFilter = prFilter == filter ? .all : filter
        UserDefaults.standard.set(prFilter.rawValue, forKey: Settings.Key.prFilter)
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
        Set(projectItems(column).compactMap { $0.repo?.key }).count > 1
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
        notes.isEditing = false
        query = ""
        focusToken += 1
        let fetches = store.fetchGitHub(maxAge: 60)
        Task {
            for fetch in fetches { await fetch.value }
            refreshSummary(force: false)
        }
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
        guard let draft = ComposerModel(item: item, sshTargets: store.sshTargets, remoteFolder: { [store] repo, host in
            store.remoteFolder(for: repo, on: host)
        }) else { return }
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
        UserDefaults.standard.set(composer.target, forKey: Settings.Key.startTarget)
        if composer.target != ComposerModel.local {
            Starter.startOverSSH(host: composer.target, folder: composer.remoteFolder, text: composer.text)
            self.composer = nil
            onClose?()
            return
        }
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
        let fetches = store.fetchGitHub(maxAge: 0)
        Task {
            await store.refresh()
            for fetch in fetches { await fetch.value }
            refreshSummary(force: true)
        }
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

        if notes.isEditing {
            guard code == kVK_Escape else { return false }
            notes.isEditing = false
            focusToken += 1
            return true
        }

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
        // With an empty search the arrows open and close a row's sessions; otherwise they move the cursor.
        case kVK_RightArrow where query.isEmpty, kVK_LeftArrow where query.isEmpty:
            if let item = selectedItem, !item.linkedSessions.isEmpty {
                setExpanded(item, code == kVK_RightArrow)
            }
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
        case "t": toggleToday()
        case "n":
            if !showsToday { toggleToday() }
            notes.addTodo()
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
    /// `local`, or the SSH host to start on.
    var target: String {
        didSet { if oldValue != target { remoteFolder = suggestFolder(target) } }
    }
    var remoteFolder: String
    let sshTargets: [SSHTarget]
    @ObservationIgnored private let suggestFolder: (String) -> String

    static let local = "local"

    init?(item: OverviewItem, sshTargets: [SSHTarget], remoteFolder: @escaping (RepoRef, String) -> String?) {
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
        self.sshTargets = sshTargets
        // Without an earlier session on that machine, guess the same layout as here.
        let fallback = "~/" + ((repo.root as NSString).abbreviatingWithTildeInPath.hasPrefix("~/")
            ? String((repo.root as NSString).abbreviatingWithTildeInPath.dropFirst(2)) : repo.name)
        suggestFolder = { host in host == ComposerModel.local ? "" : remoteFolder(repo, host) ?? fallback }
        let saved = UserDefaults.standard.string(forKey: Settings.Key.startTarget) ?? Self.local
        let target = sshTargets.contains { $0.host == saved } ? saved : Self.local
        self.target = target
        self.remoteFolder = target == Self.local ? "" : remoteFolder(repo, target) ?? fallback
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
