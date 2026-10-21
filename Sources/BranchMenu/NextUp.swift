import Foundation
import Observation

/// One suggested action in "Next up". Built from GitHub and session state by fixed rules; the
/// Claude summary only puts them in words.
struct NextUpItem: Identifiable {
    enum Kind: String {
        case merge, answer, fixChecks, review, start
    }

    let kind: Kind
    let item: OverviewItem
    let action: String
    let title: String
    let reason: String

    var id: String { "\(kind.rawValue)|\(item.id)" }
}

enum NextUp {
    /// In priority order: finish what is done, unblock others, then start new work.
    static func items(prs: [OverviewItem], issues: [OverviewItem], limit: Int = 7) -> [NextUpItem] {
        var merge: [NextUpItem] = []
        var answer: [NextUpItem] = []
        var fix: [NextUpItem] = []
        for item in prs {
            guard case .myPR(let pr) = item.kind, !pr.isDraft else { continue }
            if pr.review == .approved && pr.checks.state == .passing {
                merge.append(NextUpItem(kind: .merge, item: item, action: "Merge #\(pr.number)", title: pr.title, reason: "approved · checks pass"))
            }
            if pr.review == .changesRequested || pr.newFeedback > 0 {
                let reason = pr.review == .changesRequested
                    ? "changes requested"
                    : "\(pr.newFeedback) new comment\(pr.newFeedback == 1 ? "" : "s") since your last push"
                answer.append(NextUpItem(kind: .answer, item: item, action: "Answer #\(pr.number)", title: pr.title, reason: reason))
            }
            if pr.checks.state == .failing {
                fix.append(NextUpItem(kind: .fixChecks, item: item, action: "Fix #\(pr.number)", title: pr.title, reason: "\(pr.checks.failing) check\(pr.checks.failing == 1 ? "" : "s") failing"))
            }
        }

        let reviews: [NextUpItem] = prs
            .compactMap { item -> (OverviewItem, ReviewRequest)? in
                if case .review(let pr) = item.kind { (item, pr) } else { nil }
            }
            .sorted { $0.1.createdAt < $1.1.createdAt }
            .prefix(3)
            .map { item, pr in
                NextUpItem(kind: .review, item: item, action: "Review #\(pr.number)", title: pr.title,
                           reason: "@\(pr.authorLogin) · waiting \(age(pr.createdAt))")
            }

        let start: [NextUpItem] = issues
            .filter { $0.linkedSessions.isEmpty && $0.linkedPRNumbers.isEmpty }
            .prefix(2)
            .compactMap { item in
                guard case .issue(let issue) = item.kind else { return nil }
                return NextUpItem(kind: .start, item: item, action: "Start #\(issue.number)", title: issue.title, reason: "assigned, no session yet")
            }

        return Array((merge + answer + fix + reviews + start).prefix(limit))
    }

    /// The state handed to Claude for the summary, as plain lines.
    static func describe(
        project: String?, local: [(RepoRef, LocalState)], waiting: [LiveSession], next: [NextUpItem],
        counts: (mine: Int, reviews: Int, issues: Int)
    ) -> String {
        var lines = ["Now: \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))"]
        lines.append("Project: \(project ?? "all projects")")
        for (repo, state) in local {
            let changes = state.changes > 0 ? " with \(state.changes) uncommitted file\(state.changes == 1 ? "" : "s")" : ", clean"
            lines.append("Local checkout: \(repo.name) is on \(state.branch)\(changes)")
        }
        if waiting.isEmpty {
            lines.append("No Claude Code session is waiting for the developer.")
        } else {
            lines.append("Claude Code sessions waiting for the developer:")
            for session in waiting {
                lines.append("- \"\(session.name)\": \(session.waitingFor ?? "needs input") (\(age(session.updatedAt)) ago)")
            }
        }
        if !next.isEmpty {
            lines.append("Suggested actions, in priority order:")
            for item in next { lines.append("- \(item.action) \"\(item.title)\": \(item.reason)") }
        }
        lines.append("Open: \(counts.mine) own PRs, \(counts.reviews) review requests, \(counts.issues) assigned issues.")
        return lines.joined(separator: "\n")
    }
}

/// Writes the short "Next up" summary by running `claude -p` with Sonnet, on the user's own
/// Claude login. No tools, no saved session; a few seconds per run.
@MainActor
@Observable
final class Assistant {
    private(set) var text: String?
    private(set) var updatedAt: Date?
    private(set) var isRunning = false
    private(set) var error: String?
    @ObservationIgnored private var lastFingerprint: String?

    static let cliPath = [
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude").path,
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    var isAvailable: Bool { Self.cliPath != nil }

    private static let instructions = """
        You write the "Next up" line in a developer's dashboard. From the state below, say in two or \
        three short sentences (at most 55 words) what they should do first and why. Plain text only: \
        no markdown, no lists, no greeting. Refer to PRs and issues as #number. Pick what matters \
        most instead of repeating every item. Mention the local checkout only if it matters. Every PR \
        and issue listed is open; don't mention any other.
        """

    /// Writes a new summary when what there is to do changed (`fingerprint`, at most once a
    /// minute), when the last one is half an hour old, or when forced.
    func refresh(state: String, fingerprint: String, force: Bool) {
        guard let cli = Self.cliPath, !isRunning else { return }
        if !force, let updatedAt {
            let age = Date().timeIntervalSince(updatedAt)
            if age < 60 { return }
            if fingerprint == lastFingerprint && age < 1800 { return }
        }
        isRunning = true
        error = nil
        let prompt = "\(Self.instructions)\n\n<state>\n\(state)\n</state>"
        Task {
            let result = await Background.run {
                Shell.run(cli, [
                    "-p", "--model", "sonnet", "--no-session-persistence",
                    "--tools", "", "--disable-slash-commands", "--strict-mcp-config", prompt,
                ], in: NSTemporaryDirectory(), timeout: 90)
            }
            isRunning = false
            let answer = String(decoding: result.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, !answer.isEmpty {
                text = answer
                updatedAt = Date()
                lastFingerprint = fingerprint
            } else {
                error = result.err.split(separator: "\n").first.map(String.init) ?? "Claude did not answer"
            }
        }
    }
}
