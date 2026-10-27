import Foundation

/// Reads PRs and issues through the GitHub CLI, which already holds the user's login.
enum GitHub {
    static let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Everything the overview needs from one repo; the four `gh` calls run in parallel.
    static func fetch(_ repo: RepoRef) async -> RepoGitHubData {
        guard let gh = ghPath else { return RepoGitHubData(error: "GitHub CLI (gh) is not installed") }
        let root = repo.root
        // Local-only and non-GitHub repos simply have nothing to show.
        let remotes = await Background.run { Shell.run(GitProbe.git, ["-C", root, "remote", "-v"], probe: true) }
        guard String(decoding: remotes.out, as: UTF8.self).contains("github.com") else { return RepoGitHubData() }
        func gh_(_ args: [String]) async -> Shell.Result {
            await Background.run { Shell.run(gh, args, in: root) }
        }

        async let all = gh_(["pr", "list", "--state", "all", "--limit", "200",
                             "--json", "number,headRefName,state,isDraft,url"])
        async let mine = gh_(["pr", "list", "--author", "@me", "--state", "open", "--limit", "50",
                              "--json", "number,title,headRefName,isDraft,reviewDecision,url,closingIssuesReferences,statusCheckRollup,updatedAt"])
        // Review threads, comments and merge state are heavy: GitHub refuses them for 50 PRs at
        // once (over 500,000 nodes), so they come in a smaller call that may fail on its own.
        let ownerRepo = Self.ownerRepo(fromRemotes: String(decoding: remotes.out, as: UTF8.self))
        async let feedback = gh_(["api", "graphql", "-f", "query=\(feedbackQuery)",
                                  "-f", "q=repo:\(ownerRepo ?? "-") is:pr is:open author:@me"])
        async let reviews = gh_(["pr", "list", "--search", "review-requested:@me", "--state", "open", "--limit", "50",
                                 "--json", "number,title,headRefName,author,url,createdAt"])
        async let viewer = gh_(["api", "user", "--jq", ".login"])
        async let issues = gh_(["issue", "list", "--assignee", "@me", "--state", "open", "--limit", "50",
                                "--json", "number,title,labels,url,updatedAt,projectItems"])

        let allResult = await all
        guard allResult.status == 0 else {
            let reason = allResult.err.split(separator: "\n").first.map(String.init) ?? "gh failed"
            return RepoGitHubData(error: "\(repo.name): \(reason)")
        }

        var data = RepoGitHubData()
        let allPRs = decode([GHPR].self, allResult.out) ?? []
        data.prsByBranch = prsByBranch(allPRs)
        data.ownerRepo = allPRs.first?.url.flatMap(URL.init(string:)).flatMap(Template.ownerAndRepo) ?? ownerRepo
        let me = Shell.lines(await viewer.out).first ?? ""
        let details = ownerRepo == nil ? [:] : Self.details(decode(GHSearch.self, await feedback.out), me: me)
        data.mine = (decode([GHPR].self, await mine.out) ?? []).compactMap { pr in
            guard let url = pr.url.flatMap(URL.init(string:)) else { return nil }
            let detail = details[pr.number]
            let review = pr.reviewDecision.flatMap(ReviewDecision.init(rawValue:))
            return MyPR(
                repo: repo,
                number: pr.number,
                title: pr.title ?? "",
                branch: pr.headRefName ?? "",
                isDraft: pr.isDraft ?? false,
                review: review,
                // Without required reviews GitHub reports no decision, but an approval still counts.
                isApproved: review == .approved || (review == nil && detail?.approvedByPeople == true),
                checks: summarize(pr.statusCheckRollup ?? []),
                url: url,
                closes: (pr.closingIssuesReferences ?? []).map(\.number),
                updatedAt: pr.updatedAt ?? .distantPast,
                base: detail?.base ?? "",
                merge: detail?.merge ?? .unknown,
                feedback: detail?.feedback ?? PRFeedback()
            )
        }
        data.reviews = (decode([GHPR].self, await reviews.out) ?? []).compactMap { pr in
            guard let url = pr.url.flatMap(URL.init(string:)) else { return nil }
            return ReviewRequest(
                repo: repo,
                number: pr.number,
                title: pr.title ?? "",
                branch: pr.headRefName ?? "",
                authorLogin: pr.author?.login ?? "",
                authorName: pr.author?.name.flatMap { $0.isEmpty ? nil : $0 },
                url: url,
                createdAt: pr.createdAt ?? .distantPast
            )
        }
        data.issues = (decode([GHIssue].self, await issues.out) ?? []).compactMap { issue in
            guard let url = URL(string: issue.url) else { return nil }
            return Issue(
                repo: repo,
                number: issue.number,
                title: issue.title,
                labels: issue.labels.map(\.name),
                url: url,
                updatedAt: issue.updatedAt ?? .distantPast,
                boardStatus: (issue.projectItems ?? []).lazy.compactMap { $0.status?.name }.first
            )
        }
        return data
    }

    private static let feedbackQuery = """
        query($q: String!) { search(query: $q, type: ISSUE, first: 25) { nodes { ... on PullRequest {
          number baseRefName mergeable mergeStateStatus
          latestReviews(first: 20) { nodes { author { login __typename } state submittedAt body } }
          comments(last: 30) { nodes { author { login __typename } createdAt } }
          reviewThreads(first: 100) { nodes { isResolved comments(last: 1) { nodes { author { login __typename } createdAt } } } }
        } } } }
        """

    private struct Detail {
        let base: String
        let merge: MergeState
        let approvedByPeople: Bool
        let feedback: PRFeedback
    }

    /// What people (not bots) said on each PR that still waits on you. A push doesn't answer
    /// anyone, and a rebase moves every commit date, so only your own replies count.
    private static func details(_ search: GHSearch?, me: String) -> [Int: Detail] {
        func person(_ author: GHAuthor?) -> String? {
            guard let author, author.login != me, author.__typename != "Bot", !isBot(author.login) else { return nil }
            return author.login
        }
        var result: [Int: Detail] = [:]
        for pr in search?.data?.search.nodes ?? [] {
            guard let number = pr.number else { continue }
            let reviews = pr.latestReviews?.nodes ?? []
            let comments = pr.comments?.nodes ?? []
            let myLastWord = (comments.filter { $0.author?.login == me }.compactMap(\.createdAt)
                + reviews.filter { $0.author?.login == me }.compactMap(\.submittedAt)).max() ?? .distantPast

            // An unresolved thread waits on you when someone else wrote last in it.
            let unresolved = (pr.reviewThreads?.nodes ?? []).filter { !$0.isResolved }
            let threads = unresolved.compactMap { person($0.comments.nodes.last?.author) }
            // Automated reviewers (Codex, Claude) leave real findings in threads too; their other
            // comments are deploy previews and CI noise.
            let botThreads = unresolved.filter {
                guard let author = $0.comments.nodes.last?.author, author.login != me else { return false }
                return person(author) == nil
            }.count
            // An empty review body only wraps inline comments, which the threads already count.
            let said = comments.filter { ($0.createdAt ?? .distantPast) > myLastWord }.compactMap { person($0.author) }
                + reviews.filter {
                    ["COMMENTED", "CHANGES_REQUESTED"].contains($0.state) && !($0.body ?? "").isEmpty
                        && ($0.submittedAt ?? .distantPast) > myLastWord
                }.compactMap { person($0.author) }

            let people = reviews.filter { person($0.author) != nil }
            let merge: MergeState = switch pr.mergeStateStatus {
            case _ where pr.mergeable == "CONFLICTING": .conflicts
            case "DIRTY": .conflicts
            case "BEHIND": .behind
            case "BLOCKED": .blocked
            case "CLEAN", "HAS_HOOKS", "UNSTABLE": .ready
            default: .unknown
            }
            var from: [String] = []
            for login in threads + said where !from.contains(login) { from.append(login) }
            result[number] = Detail(
                base: pr.baseRefName ?? "",
                merge: merge,
                approvedByPeople: people.contains { $0.state == "APPROVED" }
                    && !people.contains { $0.state == "CHANGES_REQUESTED" },
                feedback: PRFeedback(openThreads: threads.count, botThreads: botThreads, newComments: said.count, from: from)
            )
        }
        return result
    }

    /// "owner/name" of the GitHub remote, origin first: from git@github.com:owner/name.git or
    /// https://github.com/owner/name.
    static func ownerRepo(fromRemotes text: String) -> String? {
        let lines = text.split(separator: "\n").filter { $0.contains("github.com") }
        let line = lines.first { $0.hasPrefix("origin") } ?? lines.first
        guard let line, let match = line.firstMatch(of: /github\.com[:\/]([^\/\s]+)\/([^\s]+?)(?:\.git)?(?:\s|$)/) else { return nil }
        return "\(match.1)/\(match.2)"
    }

    /// GitHub marks app accounts with "[bot]", but gh often reports them without it.
    private static func isBot(_ login: String) -> Bool {
        let name = login.lowercased()
        return name.hasSuffix("[bot]") || name.hasSuffix("-bot") || name.hasSuffix("-connector")
            || ["github-actions", "dependabot", "renovate", "vercel", "netlify", "codecov", "sonarcloud", "copilot"].contains(name)
    }

    /// Newest PR per head branch, except that an open one beats a newer merged or closed one.
    private static func prsByBranch(_ prs: [GHPR]) -> [String: PullRequest] {
        var result: [String: PullRequest] = [:]
        for pr in prs {
            guard let url = pr.url.flatMap(URL.init(string:)), let head = pr.headRefName else { continue }
            let state: PullRequest.State = switch pr.state {
            case "OPEN": (pr.isDraft ?? false) ? .draft : .open
            case "MERGED": .merged
            default: .closed
            }
            let candidate = PullRequest(number: pr.number, state: state, url: url)
            if let existing = result[head], existing.isActive || !candidate.isActive { continue }
            result[head] = candidate
        }
        return result
    }

    private static func summarize(_ checks: [GHPR.Check]) -> ChecksSummary {
        var total = 0, failing = 0, pending = 0
        for check in checks {
            // CheckRuns report status + conclusion; legacy commit statuses report only state.
            let result = (check.conclusion?.isEmpty == false ? check.conclusion : check.state)?.uppercased() ?? ""
            if result == "SKIPPED" || result == "NEUTRAL" { continue }
            total += 1
            if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"].contains(result) {
                failing += 1
            } else if let status = check.status?.uppercased(), status != "COMPLETED" {
                pending += 1
            } else if result == "PENDING" || result == "EXPECTED" {
                pending += 1
            }
        }
        let state: ChecksSummary.State =
            failing > 0 ? .failing : pending > 0 ? .pending : total > 0 ? .passing : .none
        return ChecksSummary(state: state, failing: failing)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

private struct GHPR: Decodable {
    struct Ref: Decodable { let number: Int }
    struct Check: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }
    struct Author: Decodable {
        let login: String
        let name: String?
        let isBot: Bool?

        enum CodingKeys: String, CodingKey {
            case login, name
            case isBot = "is_bot"
        }
    }

    let number: Int
    let title: String?
    let headRefName: String?
    let state: String?
    let isDraft: Bool?
    let reviewDecision: String?
    let url: String?
    let closingIssuesReferences: [Ref]?
    let statusCheckRollup: [Check]?
    let updatedAt: Date?
    let createdAt: Date?
    let author: Author?
}

private struct GHAuthor: Decodable {
    let login: String
    let __typename: String?
}

/// The GraphQL search for review threads, comments and merge state.
private struct GHSearch: Decodable {
    struct Nodes<T: Decodable>: Decodable { let nodes: [T] }
    struct Review: Decodable {
        let author: GHAuthor?
        let state: String?
        let submittedAt: Date?
        let body: String?
    }
    struct Comment: Decodable {
        let author: GHAuthor?
        let createdAt: Date?
    }
    struct Thread: Decodable {
        let isResolved: Bool
        let comments: Nodes<Comment>
    }
    struct PR: Decodable {
        let number: Int?
        let baseRefName: String?
        let mergeable: String?
        let mergeStateStatus: String?
        let latestReviews: Nodes<Review>?
        let comments: Nodes<Comment>?
        let reviewThreads: Nodes<Thread>?
    }
    struct Search: Decodable { let search: Nodes<PR> }

    let data: Search?
}

private struct GHIssue: Decodable {
    struct Label: Decodable { let name: String }
    struct ProjectItem: Decodable {
        struct Status: Decodable { let name: String? }
        let status: Status?
    }

    let number: Int
    let title: String
    let labels: [Label]
    let url: String
    let updatedAt: Date?
    let projectItems: [ProjectItem]?
}
