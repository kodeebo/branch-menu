import Foundation

enum SessionStatus: Int, Sendable {
    // Raw value doubles as sort rank: waiting sessions float to the top.
    case waiting = 0
    case running = 1
    case idle = 2
}

/// The GUI app a session's process lives under (Claude, Wave, iTerm, VS Code …).
/// `pid` is nil for Claude app sessions with no running process.
struct HostApp: Hashable, Sendable {
    let pid: pid_t?
    let name: String
    let bundleURL: URL?
}

/// A Claude Code session: one from the Claude app's own list, a running CLI process, or both
/// merged (an app session whose process is alive).
struct LiveSession: Identifiable, Hashable, Sendable {
    /// The app's `local_<uuid>` when known, else the CLI session id.
    let id: String
    /// Names the transcript in `~/.claude/projects`.
    let cliSessionId: String?
    let cwd: String
    var name: String
    let entrypoint: String
    /// `local_<uuid>`: the Claude app's own id for the session; used for deep links.
    let hostSessionId: String?
    var status: SessionStatus
    var waitingFor: String?
    /// Answer buttons on the question card the session waits on ("Yes, go ahead").
    var replyOptions: [String] = []
    var updatedAt: Date
    var host: HostApp?
    var isLive: Bool
    /// The `claude` process, while there is one.
    var processID: pid_t?
    /// Set for sessions the Claude app runs on another machine over SSH ("me@devbox").
    var sshHost: String?
    var isStarred = false
    /// PRs the Claude app itself linked to the session.
    var appPRNumbers: [Int] = []
    /// "owner/name" of those PRs.
    var appPRRepo: String?
    /// The branch the Claude app recorded for the session (worktree sessions).
    var appBranch: String?
    /// Branches the session committed to, oldest first (Claude app sessions).
    var writtenBranches: [String] = []
    /// The Claude app's one-line status after the last turn ("CI running, review pending").
    var summary: String?
    /// The prompt the Claude app suggests sending next.
    var suggestion: String?
    /// True when the session is in the Claude app's own list, whose PR links are then trusted
    /// over whatever branch happened to be checked out.
    var isInAppList = false
    /// Branch recorded on the session's last transcript message; nil until read.
    var recordedBranch: String?
    /// When the Claude app last saw a turn end (Claude app sessions).
    var lastTurnEnd: Date?
    /// A few sentences on what the last turn did and where things stand.
    var recap: String?

    var isClaudeApp: Bool { entrypoint == "claude-desktop" }
}

/// A machine the Claude app runs sessions on over SSH, from its own SSH settings.
struct SSHTarget: Hashable, Sendable {
    let name: String
    /// "user@host", as the Claude app stores it.
    let host: String
}

/// A local repo, keyed by its git common dir so every worktree maps to the same repo.
struct RepoRef: Hashable, Sendable {
    let key: String
    let name: String
    let root: String
}

/// What a repo's main checkout is on right now: where localhost points.
struct LocalState: Hashable, Sendable {
    let branch: String
    /// Changed and untracked files.
    let changes: Int
}

struct GitInfo: Hashable, Sendable {
    let repoKey: String
    let repoName: String
    let repoRoot: String
    let branch: String
    let isWorktree: Bool

    var repo: RepoRef { RepoRef(key: repoKey, name: repoName, root: repoRoot) }
}

/// The minimum needed to label a branch with its PR.
struct PullRequest: Hashable, Sendable {
    enum State: Sendable { case open, draft, merged, closed }
    let number: Int
    let state: State
    let url: URL

    var isActive: Bool { state == .open || state == .draft }
}

struct ChecksSummary: Hashable, Sendable {
    enum State: Sendable { case passing, failing, pending, none }
    let state: State
    let failing: Int
}

/// A deployed preview of a PR, as a bot posts it in a PR comment ("My App").
struct PreviewLink: Hashable, Sendable {
    let name: String
    let url: URL
}

enum ReviewDecision: String, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// Whether GitHub would let the PR merge now, apart from reviews and checks.
enum MergeState: Sendable {
    case ready, behind, conflicts, blocked, unknown
}

/// What reviewers said that still waits on your reply. Bots count only in review threads.
struct PRFeedback: Hashable, Sendable {
    /// Unresolved review threads where someone else wrote last.
    var openThreads = 0
    /// Unresolved threads where an automated reviewer wrote last.
    var botThreads = 0
    /// Comments and reviews with text since your last comment on the PR.
    var newComments = 0
    /// Logins of the people waiting, in the order they appear.
    var from: [String] = []

    /// Nothing from people; bot threads may still wait.
    var isEmpty: Bool { openThreads == 0 && newComments == 0 }
}

/// An open PR you authored.
struct MyPR: Identifiable, Hashable, Sendable {
    let repo: RepoRef
    let number: Int
    let title: String
    let branch: String
    let isDraft: Bool
    let review: ReviewDecision?
    /// Approved by the review decision, or by a reviewer where no review is required.
    let isApproved: Bool
    let checks: ChecksSummary
    let url: URL
    /// Issues GitHub will close when this PR merges.
    let closes: [Int]
    let updatedAt: Date
    /// The branch it merges into.
    let base: String
    let merge: MergeState
    let feedback: PRFeedback
    let preview: PreviewLink?

    var id: String { "pr:\(repo.key)#\(number)" }
}

/// An open PR someone asked you to review.
struct ReviewRequest: Identifiable, Hashable, Sendable {
    let repo: RepoRef
    let number: Int
    let title: String
    let branch: String
    let authorLogin: String
    let authorName: String?
    let url: URL
    let createdAt: Date
    let preview: PreviewLink?

    var id: String { "pr:\(repo.key)#\(number)" }
}

/// An open issue assigned to you.
struct Issue: Identifiable, Hashable, Sendable {
    let repo: RepoRef
    let number: Int
    let title: String
    let labels: [String]
    let url: URL
    let updatedAt: Date
    /// The issue's status on its GitHub project board ("Ready", "Blocked", "In dev review").
    let boardStatus: String?

    var id: String { "issue:\(repo.key)#\(number)" }

    enum Stage { case notStarted, blocked, underway }

    /// Where the board says work stands. No board status counts as not started.
    var stage: Stage {
        guard let status = boardStatus?.lowercased() else { return .notStarted }
        if status.contains("block") || status.contains("wait") || status.contains("hold") { return .blocked }
        let fresh = ["ready", "todo", "to do", "backlog", "new", "triage", "next", "planned", "icebox", "inbox"]
        return fresh.contains { status.contains($0) } ? .notStarted : .underway
    }
}

struct RepoGitHubData: Sendable {
    /// "owner/name" on GitHub.
    var ownerRepo: String?
    var prsByBranch: [String: PullRequest] = [:]
    var mine: [MyPR] = []
    var reviews: [ReviewRequest] = []
    var issues: [Issue] = []
    var error: String?
}
