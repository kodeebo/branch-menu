import Foundation
import Observation

/// One suggested action in "Next up", built from GitHub and session state by fixed rules.
struct NextUpItem: Identifiable {
    enum Kind: String {
        case merge, answer, update, fixChecks, review, start
    }

    let kind: Kind
    let item: OverviewItem
    let action: String
    let title: String
    let reason: String
    /// Why now, in Claude's words, after "Ask Claude".
    var note: String?
    /// Higher comes first.
    let priority: Double

    var id: String { "\(kind.rawValue)|\(item.id)" }
}

enum NextUp {
    /// The rules' list: the highest priorities, with at most three reviews and two new issues so
    /// they don't crowd out your own work.
    static func top(_ candidates: [NextUpItem], limit: Int = 7) -> [NextUpItem] {
        let caps: [NextUpItem.Kind: Int] = [.review: 3, .start: 2]
        var counts: [NextUpItem.Kind: Int] = [:]
        let capped = candidates.filter { next in
            counts[next.kind, default: 0] += 1
            return counts[next.kind]! <= caps[next.kind, default: .max]
        }
        return Array(capped.prefix(limit))
    }

    static func items(prs: [OverviewItem], issues: [OverviewItem], limit: Int = 7) -> [NextUpItem] {
        top(candidates(prs: prs, issues: issues), limit: limit)
    }

    /// Everything worth doing, highest priority first: finish what is done, answer the people
    /// waiting on you, unblock your PRs, review for others (sooner the longer they wait), then
    /// start new work.
    static func candidates(prs: [OverviewItem], issues: [OverviewItem]) -> [NextUpItem] {
        var result: [NextUpItem] = []
        for item in prs {
            guard case .myPR(let pr) = item.kind, !pr.isDraft else { continue }
            let checksOK = pr.checks.state == .passing || pr.checks.state == .none
            if pr.isApproved && checksOK && (pr.merge == .ready || pr.merge == .unknown) {
                result.append(NextUpItem(kind: .merge, item: item, action: "Merge #\(pr.number)", title: pr.title,
                                         reason: "approved · checks pass", priority: 100))
            }
            if pr.merge == .conflicts {
                result.append(NextUpItem(kind: .update, item: item, action: "Resolve #\(pr.number)", title: pr.title,
                                         reason: "conflicts with \(pr.base)" + (pr.isApproved ? " · approved" : ""),
                                         priority: pr.isApproved ? 85 : 65))
            } else if pr.merge == .behind && pr.isApproved && checksOK {
                result.append(NextUpItem(kind: .update, item: item, action: "Update #\(pr.number)", title: pr.title,
                                         reason: "approved · behind \(pr.base)", priority: 85))
            }
            // People first; threads from automated reviewers alone rank below fixing checks.
            if pr.review == .changesRequested || !pr.feedback.isEmpty || pr.feedback.botThreads > 0 {
                let priority: Double = pr.review == .changesRequested ? 95 : !pr.feedback.isEmpty ? 90 : 62
                result.append(NextUpItem(kind: .answer, item: item, action: "Answer #\(pr.number)", title: pr.title,
                                         reason: answerReason(pr), priority: priority))
            }
            if pr.checks.state == .failing {
                result.append(NextUpItem(kind: .fixChecks, item: item, action: "Fix #\(pr.number)", title: pr.title,
                                         reason: "\(plural(pr.checks.failing, "check")) failing", priority: 70))
            }
        }

        let reviews = prs
            .compactMap { item -> (OverviewItem, ReviewRequest)? in
                if case .review(let pr) = item.kind { (item, pr) } else { nil }
            }
            .sorted { $0.1.createdAt < $1.1.createdAt }
        for (item, pr) in reviews {
            // A week-old review outranks fixing your own checks; a fresh one doesn't.
            let days = min(Date().timeIntervalSince(pr.createdAt) / 86_400, 7)
            result.append(NextUpItem(kind: .review, item: item, action: "Review #\(pr.number)", title: pr.title,
                                     reason: "@\(pr.authorLogin) · waiting \(age(pr.createdAt))", priority: 55 + 4 * days))
        }

        // Only issues nothing has started on: no PR, no session, and Ready (or no status) on the board.
        for item in issues where item.linkedSessions.isEmpty && item.linkedPRNumbers.isEmpty {
            guard case .issue(let issue) = item.kind, issue.stage == .notStarted else { continue }
            let reason = issue.boardStatus.map { "\($0) on the board, no session yet" } ?? "assigned, no session yet"
            result.append(NextUpItem(kind: .start, item: item, action: "Start #\(issue.number)", title: issue.title,
                                     reason: reason, priority: 40))
        }

        // Ties keep the order above.
        return result.enumerated()
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .map(\.element)
    }

    /// "changes requested · 3 open threads · @reviewer"
    private static func answerReason(_ pr: MyPR) -> String {
        var parts: [String] = []
        if pr.review == .changesRequested { parts.append("changes requested") }
        if pr.feedback.openThreads > 0 { parts.append("\(plural(pr.feedback.openThreads, "open thread"))") }
        if pr.feedback.newComments > 0 { parts.append("\(plural(pr.feedback.newComments, "new comment"))") }
        if let first = pr.feedback.from.first {
            parts.append("@\(first)" + (pr.feedback.from.count > 1 ? " +\(pr.feedback.from.count - 1)" : ""))
        }
        if pr.feedback.botThreads > 0 { parts.append("\(plural(pr.feedback.botThreads, "bot thread"))") }
        return parts.joined(separator: " · ")
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// What Claude sees: the candidates it may pick from, and everything else as background.
    static func prompt(
        candidates: [NextUpItem], prs: [OverviewItem], issues: [OverviewItem], sessions: [OverviewItem],
        checkouts: [(RepoRef, LocalState)]
    ) -> String {
        var lines = ["Now: \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))", ""]
        lines.append("<candidates>")
        for (index, next) in candidates.enumerated() {
            let sessions = next.item.linkedSessions.prefix(3).map { "\"\($0.name)\" (\(describe($0.status)), \(age($0.updatedAt)) ago)" }
            lines.append("c\(index + 1): \(next.action) \"\(next.title)\" in \(next.item.repo?.name ?? "?") — \(next.reason)"
                + (sessions.isEmpty ? "" : ". Sessions: \(sessions.joined(separator: ", "))"))
        }
        lines += ["</candidates>", "", "<my_open_prs>"]
        for item in prs {
            guard case .myPR(let pr) = item.kind else { continue }
            var facts = [pr.isDraft ? "draft" : nil, pr.isApproved ? "approved" : pr.review.map { "\($0)".lowercased() },
                         "checks \(pr.checks.state)", "merge \(pr.merge)", "into \(pr.base)",
                         pr.closes.isEmpty ? nil : "closes \(pr.closes.map { "#\($0)" }.joined(separator: ","))",
                         "updated \(age(pr.updatedAt)) ago"].compactMap { $0 }
            if !pr.feedback.isEmpty || pr.feedback.botThreads > 0 { facts.append(answerReason(pr)) }
            lines.append("#\(pr.number) \"\(pr.title)\" — \(facts.joined(separator: ", "))")
        }
        lines += ["</my_open_prs>", "", "<review_requests>"]
        for item in prs {
            guard case .review(let pr) = item.kind else { continue }
            lines.append("#\(pr.number) \"\(pr.title)\" by @\(pr.authorLogin), requested \(age(pr.createdAt)) ago")
        }
        lines += ["</review_requests>", "", "<assigned_issues>"]
        for item in issues {
            guard case .issue(let issue) = item.kind else { continue }
            let prs = item.linkedPRNumbers.map { "#\($0)" }.joined(separator: ",")
            lines.append("#\(issue.number) \"\(issue.title)\" — board: \(issue.boardStatus ?? "none")"
                + (prs.isEmpty ? "" : ", PR \(prs)") + (item.linkedSessions.isEmpty ? "" : ", has sessions"))
        }
        lines += ["</assigned_issues>", "", "<sessions>"]
        for item in sessions.prefix(12) {
            guard case .session(let session) = item.kind else { continue }
            var line = "\"\(session.name)\" — \(describe(session.status)), \(age(session.updatedAt)) ago"
            if let pr = item.branchPR { line += ", PR #\(pr.number)" }
            if let waiting = session.waitingFor { line += ", waiting for: \(waiting.prefix(160))" }
            if let recap = session.recap { line += "\n  recap: \(recap.prefix(400).replacingOccurrences(of: "\n", with: " "))" }
            lines.append(line)
        }
        lines += ["</sessions>", "", "<local_checkouts>"]
        for (repo, state) in checkouts {
            lines.append("\(repo.name) on \(state.branch)" + (state.changes > 0 ? ", \(state.changes) changed files" : ""))
        }
        lines.append("</local_checkouts>")
        return lines.joined(separator: "\n")
    }

    private static func describe(_ status: SessionStatus) -> String {
        switch status {
        case .waiting: "waiting for the user"
        case .running: "running"
        case .idle: "idle"
        }
    }
}

/// "Ask Claude": Claude picks and orders Next up from the rules' candidates and says why. It can
/// only name candidates, so every row keeps the rules' action and buttons.
@MainActor
@Observable
final class NextUpCurator {
    struct Pick: Decodable {
        let id: String
        let reason: String
    }

    private(set) var picks: [Pick] = []
    private(set) var curatedAt: Date?
    private(set) var isRunning = false
    /// The project and candidates it sorted, to tell when the list has changed since.
    @ObservationIgnored private var projectKey: String?
    private(set) var fingerprint: String?

    static let cliPath = [
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude").path,
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    var isAvailable: Bool { Self.cliPath != nil }

    private static let instructions = """
        You curate the "Next up" list in a developer's dashboard. From the candidates below, pick \
        at most 7 things they should do next, most important first. Prefer finishing and unblocking \
        (merging, answering reviewers, reviews others wait on) over starting new work, but use \
        judgment: the sessions and their recaps show what is already handled, underway or blocked, \
        and a candidate may already be done. Leave out what doesn't need them now. For each pick, \
        write a reason of at most 10 words saying why it matters now; don't repeat the title or \
        the facts already given. Use only the candidate ids (c1, c2 …).
        """

    private static let schema = """
        {"type":"object","additionalProperties":false,"required":["picks"],"properties":{"picks":{"type":"array","maxItems":7,\
        "items":{"type":"object","additionalProperties":false,"required":["id","reason"],\
        "properties":{"id":{"type":"string"},"reason":{"type":"string"}}}}}}
        """

    static func fingerprint(_ candidates: [NextUpItem]) -> String {
        candidates.map(\.id).joined(separator: ",")
    }

    func clear() {
        picks = []
        curatedAt = nil
        fingerprint = nil
    }

    /// Asks Claude to order `candidates`; returns an error message when it couldn't.
    func curate(candidates: [NextUpItem], state: String, projectKey: String?) async -> String? {
        guard let cli = Self.cliPath else { return "Claude Code is not installed" }
        guard !isRunning, !candidates.isEmpty else { return nil }
        isRunning = true
        defer { isRunning = false }
        let prompt = "\(Self.instructions)\n\n\(state)"
        let schema = Self.schema
        let result = await Background.run {
            Shell.run(cli, [
                "-p", "--model", "sonnet", "--no-session-persistence", "--tools", "", "--disable-slash-commands",
                "--strict-mcp-config", "--output-format", "json", "--json-schema", schema, prompt,
            ], in: NSTemporaryDirectory(), timeout: 90)
        }
        struct Output: Decodable {
            struct Picks: Decodable { let picks: [Pick] }
            let is_error: Bool?
            let result: String?
            let structured_output: Picks?
        }
        guard result.status == 0, let output = try? JSONDecoder().decode(Output.self, from: result.out),
              output.is_error != true, let answer = output.structured_output else {
            Log.error("next-up", "claude -p failed: \(result.err.prefix(300))")
            return "Claude didn't answer" + (result.err.isEmpty ? "" : ": \(result.err.split(separator: "\n").first ?? "")")
        }
        // "c3" → the third candidate; anything else is dropped.
        picks = answer.picks.compactMap { pick in
            guard let index = Int(pick.id.dropFirst()), candidates.indices.contains(index - 1) else { return nil }
            return Pick(id: candidates[index - 1].id, reason: pick.reason)
        }
        curatedAt = Date()
        fingerprint = Self.fingerprint(candidates)
        self.projectKey = projectKey
        return nil
    }

    /// Claude's picks that are still candidates, in its order and with its reasons; nil when it
    /// hasn't sorted this project, or all its picks are done.
    func apply(to candidates: [NextUpItem], projectKey: String?) -> [NextUpItem]? {
        guard curatedAt != nil, projectKey == self.projectKey else { return nil }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = picks.compactMap { pick -> NextUpItem? in
            guard var next = byID[pick.id] else { return nil }
            next.note = pick.reason
            return next
        }
        return items.isEmpty ? nil : items
    }
}
