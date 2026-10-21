import AppKit
import Darwin
import Foundation

/// Reads the per-process session files Claude Code writes to `~/.claude/sessions/`.
/// The format is undocumented, so every field is read leniently.
enum SessionReader {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/sessions", directoryHint: .isDirectory)

    @MainActor
    static func liveSessions(in dir: URL = directory) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(parse)
    }

    @MainActor
    private static func parse(_ url: URL) -> LiveSession? {
        guard
            let data = try? Data(contentsOf: url),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let pidNumber = obj["pid"] as? NSNumber,
            let sessionId = obj["sessionId"] as? String,
            let cwd = obj["cwd"] as? String
        else { return nil }

        let pid = pid_t(truncating: pidNumber)
        // Files outlive crashed sessions, and pids get reused: require a live `claude` process.
        guard Proc.isAlive(pid),
              Proc.executablePath(pid)?.lowercased().contains("claude") == true
        else { return nil }

        let waitingFor = obj["waitingFor"] as? String
        let status: SessionStatus =
            waitingFor != nil ? .waiting
            : (obj["status"] as? String) == "busy" ? .running
            : .idle
        let millis = (obj["statusUpdatedAt"] as? NSNumber ?? obj["updatedAt"] as? NSNumber)?.doubleValue
        let hostSessionId = obj["hostSessionId"] as? String

        return LiveSession(
            id: hostSessionId ?? sessionId,
            cliSessionId: sessionId,
            cwd: cwd,
            name: (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: cwd).lastPathComponent,
            entrypoint: obj["entrypoint"] as? String ?? "cli",
            hostSessionId: hostSessionId,
            status: status,
            waitingFor: waitingFor,
            updatedAt: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast,
            host: Proc.hostApp(for: pid),
            isLive: true
        )
    }
}

/// Reads the Claude app's own list of Code sessions, one `local_<uuid>.json` per session under
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`. It holds every
/// session in the sidebar, including the many with no running process. Undocumented format.
enum AppSessionReader {
    struct AppSession: Sendable {
        let id: String
        let cliSessionId: String?
        let cwd: String
        let title: String
        let lastActivity: Date
        let isArchived: Bool
        let isStarred: Bool
        let branch: String?
        let sshHost: String?
        let prNumbers: [Int]
        let prRepo: String?
        /// Branches the session committed to, oldest first.
        let writtenBranches: [String]
    }

    struct Entry: Sendable {
        let modified: Date
        let session: AppSession?
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Claude/claude-code-sessions", directoryHint: .isDirectory)

    /// Keyed by file path. Only files whose modification date changed are parsed again.
    nonisolated static func read(cache: [String: Entry]) -> [String: Entry] {
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: Entry] = [:]
        for case let url as URL in files where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let cached = cache[url.path], cached.modified == modified {
                result[url.path] = cached
            } else {
                result[url.path] = Entry(modified: modified, session: (try? Data(contentsOf: url)).flatMap(parse))
            }
        }
        return result
    }

    nonisolated private static func parse(_ data: Data) -> AppSession? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["sessionId"] as? String,
              let cwd = obj["cwd"] as? String
        else { return nil }

        let prs = obj["prs"] as? [[String: Any]] ?? []
        var numbers = prs.compactMap { $0["prNumber"] as? Int }
        if let number = obj["prNumber"] as? Int, !numbers.contains(number) { numbers.append(number) }
        let millis = (obj["lastActivityAt"] as? NSNumber ?? obj["createdAt"] as? NSNumber)?.doubleValue

        return AppSession(
            id: id,
            cliSessionId: obj["cliSessionId"] as? String,
            cwd: cwd,
            title: (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: cwd).lastPathComponent,
            lastActivity: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast,
            isArchived: obj["isArchived"] as? Bool ?? false,
            isStarred: obj["isStarred"] as? Bool ?? false,
            branch: (obj["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            sshHost: (obj["sshConfig"] as? [String: Any])?["sshHost"] as? String,
            prNumbers: numbers,
            prRepo: prs.first?["repo"] as? String ?? obj["prRepository"] as? String,
            // Entries are "branch" or "<repo path>\0branch".
            writtenBranches: (obj["writtenBranches"] as? [String] ?? []).compactMap {
                $0.split(separator: "\u{0}").last.map(String.init)
            }
        )
    }
}

enum GitProbe {
    static let git = "/usr/bin/git"

    /// Repo, branch and worktree status for a directory, or nil when it is not in a git repo.
    /// Blocks on `git` subprocesses; call it through `Background.run`.
    nonisolated static func info(for cwd: String) -> GitInfo? {
        let dirs = Shell.run(git, ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"])
        let lines = Shell.lines(dirs.out)
        guard dirs.status == 0, lines.count >= 2 else { return nil }
        let commonDir = URL(fileURLWithPath: lines[0]).standardizedFileURL
        let mainRoot = commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent() : commonDir
        let toplevel = URL(fileURLWithPath: lines[1]).standardizedFileURL

        // symbolic-ref also works on a branch with no commits yet; fall back to a short sha when detached.
        let symbolic = Shell.run(git, ["-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"])
        let sha = Shell.run(git, ["-C", cwd, "rev-parse", "--short", "HEAD"])
        let branch = (symbolic.status == 0 ? Shell.lines(symbolic.out).first : nil)
            ?? (sha.status == 0 ? Shell.lines(sha.out).first.map { "detached @ \($0)" } : nil)
            ?? "detached HEAD"

        return GitInfo(
            repoKey: commonDir.path,
            repoName: mainRoot.lastPathComponent,
            repoRoot: mainRoot.path,
            branch: branch,
            isWorktree: toplevel.path != mainRoot.path
        )
    }
}

/// Finds a session's transcript (`~/.claude/projects/<encoded cwd>/<sessionId>.jsonl`) and the
/// `gitBranch` recorded on its last message, which is the branch the session actually worked on.
enum TranscriptReader {
    struct Entry: Sendable {
        let url: URL
        let size: UInt64
        let branch: String?
    }

    static let projectsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/projects", directoryHint: .isDirectory)

    /// Reuses `cached` while the file has not grown, so idle sessions cost one stat per refresh.
    nonisolated static func resolve(sessionId: String, cwd: String, cached: Entry?) -> Entry? {
        let url = cached.flatMap { FileManager.default.fileExists(atPath: $0.url.path) ? $0.url : nil }
            ?? locate(sessionId: sessionId, cwd: cwd)
        guard let url,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64
        else { return nil }
        if let cached, cached.url == url, cached.size == size { return cached }
        return Entry(url: url, size: size, branch: lastBranch(in: url, size: size))
    }

    nonisolated private static func locate(sessionId: String, cwd: String) -> URL? {
        let file = "\(sessionId).jsonl"
        // Claude Code names the folder after the cwd with every non-alphanumeric character as "-".
        let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let direct = projectsDirectory.appending(path: encoded).appending(path: file)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        let dirs = (try? FileManager.default.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy.map { $0.appending(path: file) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Scans backwards from the end of the file in growing chunks; transcripts run to several MB.
    nonisolated private static func lastBranch(in url: URL, size: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let marker = "\"gitBranch\":\""
        var chunk: UInt64 = 256 * 1024
        while true {
            let offset = size > chunk ? size - chunk : 0
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: Int(size - offset))
            else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            if let start = text.range(of: marker, options: .backwards)?.upperBound,
               let end = text[start...].firstIndex(of: "\"") {
                let branch = String(text[start..<end])
                return branch.isEmpty ? nil : branch
            }
            if offset == 0 { return nil }
            chunk *= 4
        }
    }
}

/// Finds the folders you have used Claude Code in lately, so repos show up even with no open session.
enum RepoDiscovery {
    nonisolated static func recentFolders(days: Double = 21) -> [String] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let dirs = (try? fm.contentsOfDirectory(at: TranscriptReader.projectsDirectory, includingPropertiesForKeys: nil)) ?? []
        var folders: Set<String> = []
        // ssh-* folders hold sessions that ran on another machine; their paths do not exist here.
        for dir in dirs where !dir.lastPathComponent.hasPrefix("ssh-") {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url in
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) }
                }
                .max { $0.1 < $1.1 }
            guard let (file, modified) = newest, modified > cutoff, let cwd = firstCwd(in: file) else { continue }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.insert(cwd)
            }
        }
        return Array(folders)
    }

    nonisolated private static func firstCwd(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let cwd = obj["cwd"] as? String {
                return cwd
            }
        }
        return nil
    }
}

enum Proc {
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    /// Walks up the parent chain to the first regular (Dock) app. For Claude app sessions that is
    /// Claude.app; for a CLI it is the terminal or editor hosting the shell.
    @MainActor
    static func hostApp(for pid: pid_t) -> HostApp? {
        var current: pid_t? = pid
        for _ in 0..<24 {
            guard let p = current else { break }
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                return HostApp(pid: p, name: app.localizedName ?? "App", bundleURL: app.bundleURL)
            }
            current = parent(of: p)
        }
        return nil
    }
}

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let out: Data
        let err: String
    }

    /// Runs a command to completion. Blocking: call it through `Background.run`.
    nonisolated static func run(_ executable: String, _ args: [String], in directory: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return Result(status: -1, out: Data(), err: error.localizedDescription)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, out: data, err: String(decoding: errData, as: UTF8.self))
    }

    nonisolated static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

enum Background {
    /// Runs blocking work (subprocesses, file reads) on a GCD queue so it never ties up
    /// Swift's cooperative thread pool.
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}
