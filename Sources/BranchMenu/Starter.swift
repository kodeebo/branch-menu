import Foundation

enum Starter {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Opens a new Claude app session with `text` filled in on another machine over SSH.
    @MainActor
    static func startOverSSH(host: String, folder: String, text: String) {
        Focus.newSSHSession(host: host, folder: folder, text: StarterText.forLink(text) ?? text)
    }

    /// Opens a new Claude app session with `text` filled in, in the repo or in a worktree for `worktreeBranch`.
    @MainActor
    static func start(repoRoot: String, worktreeBranch: String?, text: String) async throws {
        var folder: String?
        if let branch = worktreeBranch {
            let result = await Background.run { Worktree.ensure(repoRoot: repoRoot, branch: branch) }
            folder = try result.get()
        }
        Focus.newSession(folder: folder, text: StarterText.forLink(text) ?? text)
    }

    static func worktreePath(repoRoot: String, branch: String) -> String {
        // Same place the Claude app puts its own worktrees.
        "\(repoRoot)/.claude/worktrees/\(branch.replacingOccurrences(of: "/", with: "-"))"
    }
}

enum Worktree {
    /// The worktree that has `branch` checked out, if any (the main checkout counts too).
    nonisolated static func path(of branch: String, repoRoot: String) -> String? {
        let list = Shell.run(GitProbe.git, ["-C", repoRoot, "worktree", "list", "--porcelain"])
        var current: String?
        for line in Shell.lines(list.out) {
            if line.hasPrefix("worktree ") { current = String(line.dropFirst(9)) }
            if line == "branch refs/heads/\(branch)" { return current }
        }
        return nil
    }

    /// Returns the worktree folder for `branch`, creating it when missing. An existing local or
    /// remote branch is checked out; otherwise a new branch starts from the remote's default branch.
    nonisolated static func ensure(repoRoot: String, branch: String) -> Result<String, Starter.Failure> {
        let git = GitProbe.git
        let path = Starter.worktreePath(repoRoot: repoRoot, branch: branch)
        if FileManager.default.fileExists(atPath: path) { return .success(path) }

        // Best effort: a stale origin only means an older starting point.
        _ = Shell.run(git, ["-C", repoRoot, "fetch", "--quiet", "origin"])

        func refExists(_ ref: String) -> Bool {
            Shell.run(git, ["-C", repoRoot, "show-ref", "--verify", "--quiet", ref], probe: true).status == 0
        }
        let args: [String]
        if refExists("refs/heads/\(branch)") || refExists("refs/remotes/origin/\(branch)") {
            // git creates a tracking branch from origin/<branch> when there is no local one.
            args = ["-C", repoRoot, "worktree", "add", path, branch]
        } else {
            let head = Shell.run(git, ["-C", repoRoot, "rev-parse", "--abbrev-ref", "origin/HEAD"], probe: true)
            let base = head.status == 0 ? Shell.lines(head.out).first ?? "HEAD" : "HEAD"
            args = ["-C", repoRoot, "worktree", "add", "-b", branch, path, base]
        }
        let result = Shell.run(git, args)
        guard result.status == 0 else {
            let reason = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Starter.Failure(message: reason.isEmpty ? "git worktree add failed" : reason))
        }
        return .success(path)
    }
}

enum StarterText {
    /// The Claude app does not run a slash command that arrives in a link's prompt, but Claude
    /// uses a skill when asked to by name: "/cross-review 1234" becomes
    /// "Use the cross-review skill: 1234". Nil when the text doesn't start with a command.
    static func forLink(_ text: String) -> String? {
        guard let match = text.firstMatch(of: /^\/([A-Za-z0-9][A-Za-z0-9:_-]*)[ \t]*([^\n]*)/) else { return nil }
        let name = String(match.1)
        let arguments = String(match.2).trimmingCharacters(in: .whitespaces)
        let rest = String(text[match.range.upperBound...])
        return "Use the \(name) skill" + (arguments.isEmpty ? "." : ": \(arguments)") + rest
    }
}
