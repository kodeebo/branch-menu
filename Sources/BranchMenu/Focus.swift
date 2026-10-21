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
            app.activate()
        }
    }

    static let claudeAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")

    /// A new Claude app Code session in `folder`, with `text` in the prompt box.
    static func newSession(folder: String, text: String) {
        var items = [URLQueryItem(name: "folder", value: folder)]
        if !text.isEmpty { items.append(URLQueryItem(name: "q", value: text)) }
        open("/new", items)
    }

    private static func open(_ path: String, _ items: [URLQueryItem]) {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = path
        components.queryItems = items + [URLQueryItem(name: "source", value: "url_external")]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
