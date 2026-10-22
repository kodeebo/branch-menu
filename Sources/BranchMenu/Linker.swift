import Foundation

enum Column: Int, CaseIterable, Sendable {
    case sessions, prs, issues

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .prs: "Pull requests"
        case .issues: "Issues"
        }
    }
}

/// One row in the overview. `linked` holds the ids of every row related to it, so selecting an
/// issue can highlight its PR and the sessions working on either.
struct OverviewItem: Identifiable {
    enum Kind {
        case session(LiveSession)
        case myPR(MyPR)
        case review(ReviewRequest)
        case issue(Issue)
    }

    let id: String
    let kind: Kind
    let column: Column
    let section: String
    let repo: RepoRef?
    /// Sessions: the branch worked on, and that branch's PR when it has one.
    var branch: String?
    var branchPR: PullRequest?
    var linked: Set<String> = []
    /// Newest first.
    var linkedSessions: [LiveSession] = []
    var linkedPRNumbers: [Int] = []
    let searchText: String

    var number: Int? {
        switch kind {
        case .session: nil
        case .myPR(let pr): pr.number
        case .review(let pr): pr.number
        case .issue(let issue): issue.number
        }
    }

    var url: URL? {
        switch kind {
        case .session: branchPR?.url
        case .myPR(let pr): pr.url
        case .review(let pr): pr.url
        case .issue(let issue): issue.url
        }
    }
}

struct Overview {
    var sessions: [OverviewItem] = []
    var prs: [OverviewItem] = []
    var issues: [OverviewItem] = []
    var errors: [String] = []
    var githubLoaded = false

    func items(_ column: Column) -> [OverviewItem] {
        switch column {
        case .sessions: sessions
        case .prs: prs
        case .issues: issues
        }
    }

    var waitingCount: Int {
        sessions.filter { if case .session(let s) = $0.kind { s.status == .waiting } else { false } }.count
    }
}

enum Linker {
    static let waitingSection = "Waiting for you"

    /// The recorded branch when there is one; the folder's current branch otherwise
    /// ("HEAD" is what Claude Code records for a detached or unborn HEAD).
    static func branch(for session: LiveSession, git: GitInfo?) -> String? {
        // The branch it last committed to says more than the one that happened to be checked out.
        if let written = session.writtenBranches.last { return written }
        if let branch = session.appBranch { return branch }
        if let recorded = session.recordedBranch, recorded != "HEAD" { return recorded }
        return session.sshHost == nil ? git?.branch : nil
    }

    /// The local repo a session belongs to. SSH sessions run elsewhere, so they are matched by the
    /// GitHub repo of their PRs, or by folder name.
    private static func repo(
        for session: LiveSession, git: GitInfo?, github: [String: RepoGitHubData], repos: [RepoRef]
    ) -> RepoRef? {
        if let git { return git.repo }
        if let ownerRepo = session.appPRRepo,
           let key = github.first(where: { $0.value.ownerRepo == ownerRepo })?.key,
           let repo = repos.first(where: { $0.key == key }) {
            return repo
        }
        guard session.sshHost != nil else { return nil }
        let folder = URL(fileURLWithPath: session.cwd).lastPathComponent
        return repos.first { $0.name == folder }
    }

    static func build(
        sessions: [LiveSession], git: [String: GitInfo], github: [String: RepoGitHubData], repos: [RepoRef]
    ) -> Overview {
        var overview = Overview()
        overview.githubLoaded = !github.isEmpty
        overview.errors = Array(Set(github.values.compactMap(\.error))).sorted()

        // Every PR in each repo by number, open or not, to recognise "Cross-review 1234".
        var anyPRByNumber: [String: [Int: PullRequest]] = [:]
        for (repoKey, data) in github {
            for pr in data.prsByBranch.values { anyPRByNumber[repoKey, default: [:]][pr.number] = pr }
        }

        overview.sessions = sessions.sorted(by: sessionOrder).map { session in
            let info = session.sshHost == nil ? git[session.cwd] : nil
            let repo = repo(for: session, git: info, github: github, repos: repos)
            let branch = branch(for: session, git: info)
            // The PR this session is about: one its name mentions, else one the Claude app linked
            // or the session committed to. Only terminal sessions fall back to the branch's PR.
            let pr = repo.flatMap { repo -> PullRequest? in
                let prs = github[repo.key]?.prsByBranch ?? [:]
                let named = numbers(in: session.name) + session.appPRNumbers
                    + session.writtenBranches.reversed().compactMap { prs[$0]?.number }
                if let pr = named.lazy.compactMap({ anyPRByNumber[repo.key]?[$0] }).first { return pr }
                return session.isInAppList ? nil : branch.flatMap { prs[$0] }
            }
            let section = switch session.status {
            case .waiting: waitingSection
            case .running: "Running"
            case .idle: "Recent"
            }
            let search = [session.name, branch ?? "", repo?.name ?? "", session.sshHost ?? "", pr.map { "#\($0.number)" } ?? ""]
            return OverviewItem(
                id: "session:\(session.id)", kind: .session(session), column: .sessions, section: section,
                repo: repo, branch: branch, branchPR: pr, searchText: search.joined(separator: " ").lowercased()
            )
        }

        let mine = github.values.flatMap(\.mine).sorted { $0.updatedAt > $1.updatedAt }
        let reviews = github.values.flatMap(\.reviews).sorted { $0.createdAt > $1.createdAt }
        let issues = github.values.flatMap(\.issues).sorted { $0.updatedAt > $1.updatedAt }

        overview.prs = mine.map { pr in
            OverviewItem(
                id: pr.id, kind: .myPR(pr), column: .prs, section: "Mine", repo: pr.repo, branch: pr.branch,
                searchText: "#\(pr.number) \(pr.title) \(pr.branch) \(pr.repo.name)".lowercased()
            )
        } + reviews.map { pr in
            OverviewItem(
                id: pr.id, kind: .review(pr), column: .prs, section: "Review requested", repo: pr.repo, branch: pr.branch,
                searchText: "#\(pr.number) \(pr.title) \(pr.branch) \(pr.authorLogin) \(pr.authorName ?? "") \(pr.repo.name)".lowercased()
            )
        }
        overview.issues = issues.map { issue in
            OverviewItem(
                id: issue.id, kind: .issue(issue), column: .issues, section: "Assigned to me", repo: issue.repo,
                searchText: "#\(issue.number) \(issue.title) \(issue.labels.joined(separator: " ")) \(issue.boardStatus ?? "") \(issue.repo.name)".lowercased()
            )
        }

        link(&overview, mine: mine, reviews: reviews, issues: issues, anyPRByNumber: anyPRByNumber)
        return overview
    }

    /// Waiting sessions oldest first (they have waited longest); the rest newest first.
    private static func sessionOrder(_ a: LiveSession, _ b: LiveSession) -> Bool {
        if a.status != b.status { return a.status.rawValue < b.status.rawValue }
        return a.status == .waiting ? a.updatedAt < b.updatedAt : a.updatedAt > b.updatedAt
    }

    private static func link(
        _ overview: inout Overview, mine: [MyPR], reviews: [ReviewRequest], issues: [Issue],
        anyPRByNumber: [String: [Int: PullRequest]]
    ) {
        var edges: [String: Set<String>] = [:]
        func connect(_ a: String, _ b: String) {
            edges[a, default: []].insert(b)
            edges[b, default: []].insert(a)
        }

        var prByNumber: [String: [Int: String]] = [:]
        var prByBranch: [String: [String: String]] = [:]
        var issueByNumber: [String: [Int: String]] = [:]
        var prNumberByID: [String: Int] = [:]
        for (repo, number, branch, id) in mine.map({ ($0.repo, $0.number, $0.branch, $0.id) })
            + reviews.map({ ($0.repo, $0.number, $0.branch, $0.id) }) {
            prByNumber[repo.key, default: [:]][number] = id
            prByBranch[repo.key, default: [:]][branch] = id
            prNumberByID[id] = number
        }
        for issue in issues {
            issueByNumber[issue.repo.key, default: [:]][issue.number] = issue.id
        }

        for pr in mine {
            for number in pr.closes {
                if let issue = issueByNumber[pr.repo.key]?[number] { connect(pr.id, issue) }
            }
        }

        for item in overview.sessions {
            guard case .session(let session) = item.kind, let repoKey = item.repo?.key else { continue }
            func linkNumber(_ number: Int) {
                if let id = prByNumber[repoKey]?[number] ?? issueByNumber[repoKey]?[number] { connect(item.id, id) }
            }
            func linkBranch(_ branch: String) {
                if let pr = prByBranch[repoKey]?[branch] { connect(item.id, pr) }
                for number in numbers(in: branch) {
                    if let issue = issueByNumber[repoKey]?[number] { connect(item.id, issue) }
                }
            }

            // 1. A session that names a PR or issue ("Cross-review 1234") is about that one, even
            //    if it ran while some other branch was checked out and that PR is not listed.
            let mentions = numbers(in: session.name).filter {
                anyPRByNumber[repoKey]?[$0] != nil || issueByNumber[repoKey]?[$0] != nil
            }
            if !mentions.isEmpty {
                mentions.forEach(linkNumber)
                continue
            }
            // 2. The Claude app records the PRs a session worked on and the branches it committed
            //    to. A session with neither only read code, whatever branch was checked out.
            if session.isInAppList {
                session.appPRNumbers.forEach(linkNumber)
                (session.writtenBranches + [session.appBranch].compactMap { $0 }).forEach(linkBranch)
                continue
            }
            // 3. Terminal sessions: the branch they ran on.
            if let branch = item.branch { linkBranch(branch) }
        }

        var sessionsByID: [String: LiveSession] = [:]
        for item in overview.sessions {
            if case .session(let session) = item.kind { sessionsByID[item.id] = session }
        }

        // Two hops reach issue → PR → session and session → PR → issue.
        func decorate(_ items: inout [OverviewItem]) {
            for index in items.indices {
                let id = items[index].id
                let direct = edges[id] ?? []
                let linked = direct.union(direct.flatMap { edges[$0] ?? [] }).subtracting([id])
                items[index].linked = linked
                items[index].linkedSessions = linked.compactMap { sessionsByID[$0] }.sorted { $0.updatedAt > $1.updatedAt }
                items[index].linkedPRNumbers = direct.compactMap { prNumberByID[$0] }.sorted()
            }
        }
        decorate(&overview.sessions)
        decorate(&overview.prs)
        decorate(&overview.issues)
    }

    /// Numbers of three or more digits, e.g. 1234 in "Cross-review 1234" or 567 in "fix/567-login".
    static func numbers(in text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { $0.count >= 3 ? Int($0) : nil }
    }
}
