import Foundation

/// Reads PRs and issues through the GitHub CLI, which already holds the user's login.
enum GitHub {
    static let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Everything the overview needs from one repo; the `gh` calls run in parallel.
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
        // Reviews, comments and commits are heavy: GitHub refuses them for 50 PRs at once (over
        // 500,000 nodes), so they come in a smaller call that may fail on its own.
        async let feedback = gh_(["pr", "list", "--author", "@me", "--state", "open", "--limit", "25",
                                  "--json", "number,latestReviews,comments,commits"])
        async let reviews = gh_(["pr", "list", "--search", "review-requested:@me", "--state", "open", "--limit", "50",
                                 "--json", "number,title,headRefName,author,url,createdAt"])
        // Only for the preview link, so it may fail without losing the review requests.
        async let reviewComments = gh_(["pr", "list", "--search", "review-requested:@me", "--state", "open", "--limit", "25",
                                        "--json", "number,comments"])
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
        data.ownerRepo = allPRs.first?.url.flatMap(URL.init(string:)).flatMap(Template.ownerAndRepo)
        let me = Shell.lines(await viewer.out).first ?? ""
        // Reviews and comments from other people since your last push, per PR. Bots (preview
        // deploys, CI, automated reviewers) post plenty that needs no answer.
        var newFeedback: [Int: Int] = [:]
        var previews: [Int: PreviewLink] = [:]
        func byPerson(_ author: GHPR.Author?) -> Bool {
            guard let author, author.login != me else { return false }
            return !(author.isBot ?? false) && !Self.isBot(author.login)
        }
        for pr in decode([GHPR].self, await feedback.out) ?? [] {
            let lastPush = pr.commits?.compactMap(\.committedDate).max() ?? .distantPast
            // Approvals need no answer; comments and change requests do.
            let reviews = (pr.latestReviews ?? []).filter {
                byPerson($0.author) && $0.state != "APPROVED" && ($0.submittedAt ?? .distantPast) > lastPush
            }
            let comments = (pr.comments ?? []).filter { byPerson($0.author) && ($0.createdAt ?? .distantPast) > lastPush }
            newFeedback[pr.number] = reviews.count + comments.count
            previews[pr.number] = preview(in: pr.comments ?? [])
        }
        for pr in decode([GHPR].self, await reviewComments.out) ?? [] {
            previews[pr.number] = preview(in: pr.comments ?? [])
        }
        data.mine = (decode([GHPR].self, await mine.out) ?? []).compactMap { pr in
            guard let url = pr.url.flatMap(URL.init(string:)) else { return nil }
            return MyPR(
                repo: repo,
                number: pr.number,
                title: pr.title ?? "",
                branch: pr.headRefName ?? "",
                isDraft: pr.isDraft ?? false,
                review: pr.reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
                checks: summarize(pr.statusCheckRollup ?? []),
                url: url,
                closes: (pr.closingIssuesReferences ?? []).map(\.number),
                updatedAt: pr.updatedAt ?? .distantPast,
                newFeedback: newFeedback[pr.number] ?? 0,
                preview: previews[pr.number]
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
                createdAt: pr.createdAt ?? .distantPast,
                preview: previews[pr.number]
            )
        }
        // The board status needs the token's read:project scope, which `gh auth login` leaves out.
        var issuesResult = await issues
        if issuesResult.status != 0, issuesResult.err.contains("read:project") {
            issuesResult = await gh_(["issue", "list", "--assignee", "@me", "--state", "open", "--limit", "50",
                                      "--json", "number,title,labels,url,updatedAt"])
            data.error = "No board status for issues: run gh auth refresh -s read:project"
        }
        data.issues = (decode([GHIssue].self, issuesResult.out) ?? []).compactMap { issue in
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

    /// GitHub marks app accounts with "[bot]", but gh often reports them without it.
    private static func isBot(_ login: String) -> Bool {
        let name = login.lowercased()
        return name.hasSuffix("[bot]") || name.hasSuffix("-bot") || name.hasSuffix("-connector")
            || ["github-actions", "dependabot", "renovate", "vercel", "netlify", "codecov", "sonarcloud", "copilot"].contains(name)
    }

    /// The first app in the newest preview comment, which a deploy bot posts as a table:
    /// `| My App | https://myapp-pr-123-….run.app | ✅ Deployed |`.
    private static func preview(in comments: [GHPR.Comment]) -> PreviewLink? {
        for comment in comments.reversed() {
            guard let body = comment.body, body.localizedCaseInsensitiveContains("preview") else { continue }
            for line in body.split(separator: "\n") where line.hasPrefix("|") {
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard cells.count >= 2, let url = URL(string: cells[1]), url.scheme == "https" else { continue }
                return PreviewLink(name: cells[0], url: url)
            }
        }
        return nil
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
    struct Review: Decodable {
        let author: Author?
        let state: String?
        let submittedAt: Date?
    }
    struct Comment: Decodable {
        let author: Author?
        let createdAt: Date?
        let body: String?
    }
    struct Commit: Decodable { let committedDate: Date? }

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
    let latestReviews: [Review]?
    let comments: [Comment]?
    let commits: [Commit]?
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
