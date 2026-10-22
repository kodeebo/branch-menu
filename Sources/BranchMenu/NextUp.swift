import Foundation

/// One suggested action in "Next up", built from GitHub and session state by fixed rules.
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

        // Only issues nothing has started on: no PR, no session, and Ready (or no status) on the board.
        let start: [NextUpItem] = issues
            .filter { $0.linkedSessions.isEmpty && $0.linkedPRNumbers.isEmpty }
            .compactMap { item -> NextUpItem? in
                guard case .issue(let issue) = item.kind, issue.stage == .notStarted else { return nil }
                let reason = issue.boardStatus.map { "\($0) on the board, no session yet" } ?? "assigned, no session yet"
                return NextUpItem(kind: .start, item: item, action: "Start #\(issue.number)", title: issue.title, reason: reason)
            }
            .prefix(2)
            .map { $0 }

        return Array((merge + answer + fix + reviews + start).prefix(limit))
    }


}
