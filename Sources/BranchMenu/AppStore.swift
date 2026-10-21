import Foundation
import Observation

/// Collects sessions, repos and GitHub data, and publishes the linked `overview`.
@MainActor
@Observable
final class AppStore {
    private(set) var overview = Overview()
    private(set) var repos: [RepoRef] = []
    private(set) var isFetchingGitHub = false

    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var sessions: [LiveSession] = []
    @ObservationIgnored private var gitCache: [String: (info: GitInfo?, at: Date)] = [:]
    @ObservationIgnored private var transcriptCache: [String: TranscriptReader.Entry] = [:]
    @ObservationIgnored private var appSessionCache: [String: AppSessionReader.Entry] = [:]
    @ObservationIgnored private var discoveredFolders: [String] = []
    @ObservationIgnored private var lastDiscovery: Date?
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
            return session
        }
        var byKey: [String: RepoRef] = [:]
        for folder in folders {
            if let repo = gitCache[folder]?.info?.repo { byKey[repo.key] = repo }
        }
        repos = byKey.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

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

    /// For `--dump`: one full refresh, including GitHub.
    func refreshAndWait() async {
        await refresh()
        for task in fetchGitHub(maxAge: 0) { await task.value }
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
                entrypoint: "claude-desktop", hostSessionId: app.id, status: .idle, waitingFor: nil,
                updatedAt: app.lastActivity, host: claude, isLive: false, sshHost: app.sshHost,
                isStarred: app.isStarred, appPRNumbers: app.prNumbers, appPRRepo: app.prRepo, appBranch: app.branch,
                writtenBranches: app.writtenBranches, isInAppList: true
            )
        }
        for process in live {
            guard var session = byID[process.id] else {
                byID[process.id] = process
                continue
            }
            session.status = process.status
            session.waitingFor = process.waitingFor
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
