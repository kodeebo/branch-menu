import AppKit

/// Brings sessions to the front and opens new ones. Claude app sessions use the app's
/// (undocumented) `claude://code/…` deep links; anything else activates the app hosting the process.
@MainActor
enum Focus {
    static func session(_ session: LiveSession) {
        if session.isClaudeApp, let hostId = session.hostSessionId {
            open("/continue", [URLQueryItem(name: "session", value: hostId)])
            return
        }
        if let pid = session.host?.pid, let app = NSRunningApplication(processIdentifier: pid) {
            Log.info("focus", "activating \(app.localizedName ?? "app") for \"\(session.name)\"")
            app.activate()
        } else {
            Log.error("focus", "no app to switch to for \"\(session.name)\"")
        }
    }

    static let claudeAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")

    /// A new Claude app Code session with `text` in the prompt box. Without a `folder`, the app
    /// uses the folder its new-session screen has selected; a link that names one makes the app
    /// ask you to allow that folder, every time.
    static func newSession(folder: String?, text: String) {
        var items = folder.map { [URLQueryItem(name: "folder", value: $0)] } ?? []
        if !text.isEmpty { items.append(URLQueryItem(name: "q", value: text)) }
        open("/new", items)
    }

    /// A new Claude app Code session on another machine over SSH.
    static func newSSHSession(host: String, folder: String, text: String) {
        var items = [URLQueryItem(name: "ssh_host", value: host)]
        if !folder.isEmpty { items.append(URLQueryItem(name: "ssh_folder", value: folder)) }
        if !text.isEmpty { items.append(URLQueryItem(name: "q", value: text)) }
        open("/new", items)
    }

    private static func open(_ path: String, _ items: [URLQueryItem]) {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = path
        components.queryItems = items + [URLQueryItem(name: "source", value: "url_external")]
        guard let url = components.url else {
            Log.error("link", "could not build a claude:// link for \(path)")
            return
        }
        let shown = url.absoluteString
        Log.info("link", shown.count > 300 ? String(shown.prefix(300)) + "…" : shown)
        NSWorkspace.shared.open(url)
    }
}
