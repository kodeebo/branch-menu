import Foundation
import Observation

/// Collects sessions, repos and GitHub data, and publishes the linked `overview`.
@MainActor
@Observable
final class AppStore {
    private(set) var overview = Overview()
    private(set) var repos: [RepoRef] = []
    private(set) var isFetchingGitHub = false
    /// Each repo's main checkout, keyed by repo key: where localhost points right now.
    private(set) var localStates: [String: LocalState] = [:]
    private(set) var sshTargets: [SSHTarget] = []

    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var sessions: [LiveSession] = []
    @ObservationIgnored private var gitCache: [String: (info: GitInfo?, at: Date)] = [:]
    @ObservationIgnored private var transcriptCache: [String: TranscriptReader.Entry] = [:]
    @ObservationIgnored private var appSessionCache: [String: AppSessionReader.Entry] = [:]
    @ObservationIgnored private var discoveredFolders: [String] = []
    @ObservationIgnored private var lastDiscovery: Date?
    @ObservationIgnored private var localCheckedAt: Date?
    @ObservationIgnored private var waitingIDs: Set<String> = []
    @ObservationIgnored private var github: [String: (data: RepoGitHubData, at: Date)] = [:]
    @ObservationIgnored private var githubInFlight: [String: Task<Void, Never>] = [:]

    private let gitTTL: TimeInterval = 30
    private let discoveryTTL: TimeInterval = 300
    private let githubTTL: TimeInterval = 120

    func startPolling() {
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Re-reads sessions and git state, then starts any due GitHub fetches without waiting for them.
    func refresh() async {
        let live = SessionReader.liveSessions()
        let now = Date()
        let appCache = appSessionCache
        appSessionCache = await Background.run { AppSessionReader.read(cache: appCache) }
        let merged = mergeSessions(live: live, now: now)
        sshTargets = await Background.run { SSHConfigReader.targets() }

        if lastDiscovery.map({ now.timeIntervalSince($0) > discoveryTTL }) ?? true {
            lastDiscovery = now
            discoveredFolders = await Background.run { RepoDiscovery.recentFolders() }
        }

        // SSH sessions' folders live on the other machine.
        let localFolders = merged.filter { $0.sshHost == nil }.map(\.cwd)
        let folders = Set(localFolders).union(discoveredFolders).union(Settings.extraRepoPaths)
        let staleFolders = folders.filter { gitCache[$0].map { now.timeIntervalSince($0.at) > gitTTL } ?? true }
        let transcriptJobs = merged.compactMap { session in
            session.cliSessionId.map { (session.id, $0, session.cwd, transcriptCache[session.id]) }
        }

        async let gitResults = Self.concurrently(Array(staleFolders)) { folder in
            await Background.run { GitProbe.info(for: folder) }
        }
        async let transcriptResults = Self.concurrently(transcriptJobs) { job in
            await Background.run { TranscriptReader.resolve(sessionId: job.1, cwd: job.2, cached: job.3) }
        }
        for (folder, info) in await gitResults { gitCache[folder] = (info, now) }
        var resolved: [String: TranscriptReader.Entry] = [:]
        for (job, entry) in await transcriptResults { resolved[job.0] = entry }
        transcriptCache = resolved.compactMapValues { $0 }

        sessions = merged.map { session in
            var session = session
            session.recordedBranch = transcriptCache[session.id]?.branch
            if session.status != .waiting, let reason = Self.waitingReason(session, transcriptCache[session.id]?.pendingTool, now: now) {
                session.status = .waiting
                session.waitingFor = reason
            }
            // The question card at the end of the latest turn; a running turn has moved past it.
            // Cards from earlier turns (or from before the app recorded turn ends) are history.
            if session.status == .idle || session.status == .waiting,
               let ask = transcriptCache[session.id]?.openAsk,
               let turnEnd = session.lastTurnEnd, ask.at >= turnEnd.addingTimeInterval(-600) {
                session.status = .waiting
                session.waitingFor = ask.question
                session.replyOptions = ask.options
            }
            return session
        }
        let waitingNow = Dictionary(uniqueKeysWithValues: sessions.filter { $0.status == .waiting }.map { ($0.id, $0) })
        for (id, session) in waitingNow where !waitingIDs.contains(id) {
            Log.info("waiting", "\"\(session.name)\" waits: \(session.waitingFor ?? "?")")
        }
        for id in waitingIDs where waitingNow[id] == nil {
            Log.info("waiting", "\(sessions.first { $0.id == id }.map { "\"\($0.name)\"" } ?? id) no longer waits")
        }
        waitingIDs = Set(waitingNow.keys)

        var byKey: [String: RepoRef] = [:]
        for folder in folders {
            if let repo = gitCache[folder]?.info?.repo { byKey[repo.key] = repo }
        }
        repos = byKey.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if localCheckedAt.map({ now.timeIntervalSince($0) > 20 }) ?? true {
            localCheckedAt = now
            let roots = repos.map { [$0.key, $0.root] }
            let states = await Self.concurrently(roots) { pair in
                await Background.run { GitProbe.localState(root: pair[1]) }
            }
            localStates = Dictionary(uniqueKeysWithValues: states.compactMap { pair, state in state.map { (pair[0], $0) } })
        }

        rebuild()
        fetchGitHub(maxAge: githubTTL)
    }

    /// Starts a GitHub fetch for every repo whose data is older than `maxAge`.
    @discardableResult
    func fetchGitHub(maxAge: TimeInterval) -> [Task<Void, Never>] {
        let now = Date()
        var tasks: [Task<Void, Never>] = []
        for repo in repos {
            if let running = githubInFlight[repo.key] {
                tasks.append(running)
                continue
            }
            if let cached = github[repo.key], now.timeIntervalSince(cached.at) < maxAge { continue }
            let task = Task {
                let data = await GitHub.fetch(repo)
                self.github[repo.key] = (data, Date())
                self.githubInFlight[repo.key] = nil
                self.isFetchingGitHub = !self.githubInFlight.isEmpty
                self.rebuild()
            }
            githubInFlight[repo.key] = task
            tasks.append(task)
        }
        isFetchingGitHub = !githubInFlight.isEmpty
        return tasks
    }

    /// Checks out a PR's branch in the repo's main checkout with `gh pr checkout`, which also
    /// handles branches from forks. Returns git's or gh's complaint when it refuses.
    func checkOut(_ number: Int, branch: String, in repo: RepoRef) async -> Result<String, Starter.Failure> {
        guard let gh = GitHub.ghPath else { return .failure(Starter.Failure(message: "GitHub CLI (gh) is not installed")) }
        let root = repo.root
        Log.info("checkout", "PR #\(number) (\(branch)) in \((root as NSString).abbreviatingWithTildeInPath)")

        // Git keeps a branch in one worktree at a time; say where it is instead of failing.
        if let elsewhere = await Background.run({ Worktree.path(of: branch, repoRoot: root) }), elsewhere != root {
            let place = (elsewhere as NSString).abbreviatingWithTildeInPath
            Log.error("checkout", "\(branch) is already checked out in \(place)")
            return .failure(Starter.Failure(message: "\(branch) is already checked out in \(place)"))
        }

        let result = await Background.run { Shell.run(gh, ["pr", "checkout", String(number)], in: root, timeout: 120) }
        localCheckedAt = nil
        await refresh()
        let now = localStates[repo.key]?.branch
        guard result.status == 0 else {
            let reason = result.err.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "gh pr checkout failed"
            Log.error("checkout", "failed: \(reason)")
            return .failure(Starter.Failure(message: reason))
        }
        Log.info("checkout", "done; \(repo.name) is on \(now ?? "?")")
        return .success(now ?? branch)
    }

    /// For `--dump`: one full refresh, including GitHub.
    func refreshAndWait() async {
        await refresh()
        for task in fetchGitHub(maxAge: 0) { await task.value }
    }

    /// The folder earlier sessions on `host` used for `repo`, newest first: a folder named like
    /// the repo, or one inside it (a worktree).
    func remoteFolder(for repo: RepoRef, on host: String) -> String? {
        appSessionCache.values.compactMap(\.session)
            .filter { $0.sshHost == host }
            .sorted { $0.lastActivity > $1.lastActivity }
            .lazy
            .compactMap { session -> String? in
                let parts = session.cwd.split(separator: "/").map(String.init)
                guard let index = parts.lastIndex(of: repo.name) else { return nil }
                return "/" + parts[...index].joined(separator: "/")
            }
            .first
    }

    /// What a running session waits on, read from the tool call at the end of its transcript.
    /// The Claude app keeps pending permission prompts in memory only, so this is the outside view:
    /// questions always wait on you; instant tools still unanswered after a few seconds are
    /// waiting for permission; a Bash call is waiting only while no command runs under it.
    private static func waitingReason(_ session: LiveSession, _ pending: TranscriptReader.PendingTool?, now: Date) -> String? {
        guard session.isLive, let pending, let pid = session.processID else { return nil }
        let waited = now.timeIntervalSince(pending.since)
        switch pending.name {
        case "AskUserQuestion":
            return "has a question for you"
        case "ExitPlanMode":
            return "has a plan for you to approve"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "Read", "Glob", "Grep":
            return waited > 4 ? "wants permission: \(pending.name)" : nil
        case "Bash":
            return waited > 4 && !Proc.hasChildren(pid) ? "wants permission: Bash" : nil
        default:
            // Agents, MCP tools and web calls can legitimately take long; don't guess.
            return nil
        }
    }

    /// The Claude app's recent sessions, with live status laid over the ones that have a running
    /// process, plus CLI sessions running in terminals.
    private func mergeSessions(live: [LiveSession], now: Date) -> [LiveSession] {
        let cutoff = now.addingTimeInterval(-Double(Settings.sessionDays) * 86_400)
        let claude = HostApp(pid: nil, name: "Claude", bundleURL: Focus.claudeAppURL)
        var byID: [String: LiveSession] = [:]
        for app in appSessionCache.values.compactMap(\.session)
        where !app.isArchived && (app.lastActivity > cutoff || app.isStarred) {
            byID[app.id] = LiveSession(
                id: app.id, cliSessionId: app.cliSessionId, cwd: app.cwd, name: app.title,
                entrypoint: "claude-desktop", hostSessionId: app.id,
                status: app.openQuestion == nil ? .idle : .waiting, waitingFor: app.openQuestion,
                updatedAt: app.lastActivity, host: claude, isLive: false, sshHost: app.sshHost,
                isStarred: app.isStarred, appPRNumbers: app.prNumbers, appPRRepo: app.prRepo, appBranch: app.branch,
                writtenBranches: app.writtenBranches, summary: app.summary?.detail, suggestion: app.suggestion,
                isInAppList: true, lastTurnEnd: app.lastTurnEnd
            )
        }
        for process in live {
            guard var session = byID[process.id] else {
                byID[process.id] = process
                continue
            }
            // A running turn or a live prompt wins; an idle process keeps the app's open question.
            if process.status != .idle || session.status != .waiting {
                session.status = process.status
                session.waitingFor = process.waitingFor
            }
            session.processID = process.processID
            session.updatedAt = max(session.updatedAt, process.updatedAt)
            session.host = process.host ?? session.host
            session.isLive = true
            byID[process.id] = session
        }
        return Array(byID.values)
    }

    private func rebuild() {
        let git = gitCache.compactMapValues(\.info)
        overview = Linker.build(sessions: sessions, git: git, github: github.mapValues(\.data), repos: repos)
        onChange?()
    }

    private nonisolated static func concurrently<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], _ work: @escaping @Sendable (Input) async -> Output
    ) async -> [(Input, Output)] {
        await withTaskGroup(of: (Input, Output).self) { group in
            for input in inputs {
                group.addTask { (input, await work(input)) }
            }
            var results: [(Input, Output)] = []
            for await result in group { results.append(result) }
            return results
        }
    }
}
