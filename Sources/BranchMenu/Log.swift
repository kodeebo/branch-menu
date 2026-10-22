import AppKit
import Observation
import SwiftUI

/// What the app did: the commands it ran, the links it opened and what failed. Kept in memory for
/// the log window and appended to `~/Library/Logs/Branch Menu/branch-menu.log`.
enum Log {
    enum Level: String, Sendable {
        /// Routine work, like the git and gh calls behind every refresh.
        case debug
        /// Something you did or that changed: a checkout, a link opened, a session now waiting.
        case info
        case error
    }

    struct Entry: Identifiable, Sendable {
        let id: Int
        let date: Date
        let level: Level
        let category: String
        let message: String

        var line: String {
            // Local time: the ISO formatter would print UTC.
            let time = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
            let stamp = String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", time.year ?? 0, time.month ?? 0, time.day ?? 0,
                               time.hour ?? 0, time.minute ?? 0, time.second ?? 0, (time.nanosecond ?? 0) / 1_000_000)
            return "\(stamp) \(level.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) [\(category)] \(message)"
        }
    }

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Branch Menu/branch-menu.log")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter = 0
    nonisolated(unsafe) private static var handle: FileHandle?

    nonisolated static func debug(_ category: String, _ message: String) { write(.debug, category, message) }
    nonisolated static func info(_ category: String, _ message: String) { write(.info, category, message) }
    nonisolated static func error(_ category: String, _ message: String) { write(.error, category, message) }

    nonisolated static func write(_ level: Level, _ category: String, _ message: String) {
        lock.lock()
        counter += 1
        let entry = Entry(id: counter, date: Date(), level: level, category: category, message: message)
        if let data = (entry.line + "\n").data(using: .utf8) { openFile()?.write(data) }
        lock.unlock()
        DispatchQueue.main.async { MainActor.assumeIsolated { LogStore.shared.add(entry) } }
    }

    /// Opens the file for appending, starting it over once it passes 5 MB.
    private static func openFile() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? UInt64 ?? 0
        if size > 5_000_000 || !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        return handle
    }
}

@MainActor
@Observable
final class LogStore {
    static let shared = LogStore()
    private(set) var entries: [Log.Entry] = []

    func add(_ entry: Log.Entry) {
        entries.append(entry)
        if entries.count > 3000 { entries.removeFirst(entries.count - 3000) }
    }

    func clear() { entries.removeAll() }
}

struct LogView: View {
    @State private var showsRoutine = false
    @State private var query = ""
    private let store = LogStore.shared

    var body: some View {
        let entries = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Show routine commands", isOn: $showsRoutine)
                TextField("Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entries.map(\.line).joined(separator: "\n"), forType: .string)
                }
                .help("Copy the lines shown")
                Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }
                Button("Clear") { store.clear() }
                    .help("Clear this window; the file keeps everything")
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.date.formatted(.dateTime.hour().minute().second()))
                                    .foregroundStyle(.secondary)
                                Text(entry.level.rawValue)
                                    .foregroundStyle(color(entry.level))
                                    .frame(width: 40, alignment: .leading)
                                Text(entry.category)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                Text(entry.message)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: entries.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 420)
    }

    private var filtered: [Log.Entry] {
        let needle = query.lowercased()
        return store.entries.filter { entry in
            (showsRoutine || entry.level != .debug)
                && (needle.isEmpty || entry.message.lowercased().contains(needle) || entry.category.contains(needle))
        }
    }

    private func color(_ level: Log.Level) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .accentColor
        case .error: StatusColor.red
        }
    }
}
