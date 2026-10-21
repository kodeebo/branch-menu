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
        let remotes = await Background.run { Shell.run(GitProbe.git, ["-C", root, "remote", "-v"]) }
        guard String(decoding: remotes.out, as: UTF8.self).contains("github.com") else { return RepoGitHubData() }
        func gh_(_ args: [String]) async -> Shell.Result {
            await Background.run { Shell.run(gh, args, in: root) }
        }

        async let all = gh_(["pr", "list", "--state", "all", "--limit", "200",
                             "--json", "number,headRefName,state,isDraft,url"])
        async let mine = gh_(["pr", "list", "--author", "@me", "--state", "open", "--limit", "50",
                              "--json", "number,title,headRefName,isDraft,reviewDecision,url,closingIssuesReferences,statusCheckRollup,updatedAt"])
        async let reviews = gh_(["pr", "list", "--search", "review-requested:@me", "--state", "open", "--limit", "50",
                                 "--json", "number,title,headRefName,author,url,createdAt"])
        async let issues = gh_(["issue", "list", "--assignee", "@me", "--state", "open", "--limit", "50",
                                "--json", "number,title,labels,url,updatedAt"])

        let allResult = await all
        guard allResult.status == 0 else {
            let reason = allResult.err.split(separator: "\n").first.map(String.init) ?? "gh failed"
            return RepoGitHubData(error: "\(repo.name): \(reason)")
        }

        var data = RepoGitHubData()
        let allPRs = decode([GHPR].self, allResult.out) ?? []
        data.prsByBranch = prsByBranch(allPRs)
        data.ownerRepo = allPRs.first.flatMap { URL(string: $0.url) }.flatMap(Template.ownerAndRepo)
        data.mine = (decode([GHPR].self, await mine.out) ?? []).compactMap { pr in
            guard let url = URL(string: pr.url) else { return nil }
            return MyPR(
                repo: repo,
                number: pr.number,
                title: pr.title ?? "",
                branch: pr.headRefName,
                isDraft: pr.isDraft ?? false,
                review: pr.reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
                checks: summarize(pr.statusCheckRollup ?? []),
                url: url,
                closes: (pr.closingIssuesReferences ?? []).map(\.number),
                updatedAt: pr.updatedAt ?? .distantPast
            )
        }
        data.reviews = (decode([GHPR].self, await reviews.out) ?? []).compactMap { pr in
            guard let url = URL(string: pr.url) else { return nil }
            return ReviewRequest(
                repo: repo,
                number: pr.number,
                title: pr.title ?? "",
                branch: pr.headRefName,
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
                updatedAt: issue.updatedAt ?? .distantPast
            )
        }
        return data
    }

    /// Newest PR per head branch, except that an open one beats a newer merged or closed one.
    private static func prsByBranch(_ prs: [GHPR]) -> [String: PullRequest] {
        var result: [String: PullRequest] = [:]
        for pr in prs {
            guard let url = URL(string: pr.url) else { continue }
            let state: PullRequest.State = switch pr.state {
            case "OPEN": (pr.isDraft ?? false) ? .draft : .open
            case "MERGED": .merged
            default: .closed
            }
            let candidate = PullRequest(number: pr.number, state: state, url: url)
            if let existing = result[pr.headRefName], existing.isActive || !candidate.isActive { continue }
            result[pr.headRefName] = candidate
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
    }

    let number: Int
    let title: String?
    let headRefName: String
    let state: String?
    let isDraft: Bool?
    let reviewDecision: String?
    let url: String
    let closingIssuesReferences: [Ref]?
    let statusCheckRollup: [Check]?
    let updatedAt: Date?
    let createdAt: Date?
    let author: Author?
}

private struct GHIssue: Decodable {
    struct Label: Decodable { let name: String }

    let number: Int
    let title: String
    let labels: [Label]
    let url: String
    let updatedAt: Date?
}
