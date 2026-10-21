import AppKit
import Observation
import SwiftUI

/// One running notes file, `~/Library/Application Support/Branch Menu/Notes.md`. Archive moves
/// it to `Archive/<date>.md` and starts a fresh one. Lines starting with `[ ]` are to-dos.
@MainActor
@Observable
final class NotesStore {
    private(set) var text = ""
    /// The editor is open (else the notes show rendered, with clickable checkboxes).
    var isEditing = false

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Branch Menu", directoryHint: .isDirectory)
    static let file = folder.appending(path: "Notes.md")

    init() {
        text = (try? String(contentsOf: Self.file, encoding: .utf8)) ?? ""
    }

    func update(_ newText: String) {
        text = newText
        save(text, to: Self.file)
    }

    func toggle(line index: Int) {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(index), let range = lines[index].range(of: #"\[( |x|X)\]"#, options: .regularExpression) else { return }
        lines[index].replaceSubrange(range, with: lines[index][range] == "[ ]" ? "[x]" : "[ ]")
        update(lines.joined(separator: "\n"))
    }

    func addTodo() {
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        update(text + separator + "[ ] ")
        isEditing = true
    }

    func archive() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)", timeZone: .current, calendar: .current))
        save(text, to: Self.folder.appending(path: "Archive/\(stamp).md"))
        update("")
        isEditing = false
    }

    func revealInFinder() {
        if !FileManager.default.fileExists(atPath: Self.file.path) { save(text, to: Self.file) }
        NSWorkspace.shared.activateFileViewerSelecting([Self.file])
    }

    private func save(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    struct Line: Identifiable {
        enum Kind {
            case todo(done: Bool, text: String)
            case text(String)
            case blank
        }

        let id: Int
        let kind: Kind
    }

    var lines: [Line] {
        text.components(separatedBy: "\n").enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return Line(id: index, kind: .blank) }
            if let match = trimmed.firstMatch(of: /^(?:[-*]\s+)?\[( |x|X)\]\s?(.*)$/) {
                return Line(id: index, kind: .todo(done: match.1 != " ", text: String(match.2)))
            }
            return Line(id: index, kind: .text(line))
        }
    }
}

/// The notes card: rendered with clickable checkboxes, and an editor on click.
struct NotesCard: View {
    let model: OverviewModel
    @FocusState private var editorFocused: Bool

    private var notes: NotesStore { model.notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Notes").font(.system(size: 12.5, weight: .semibold))
                let todos = notes.lines.filter { if case .todo = $0.kind { true } else { false } }
                if !todos.isEmpty {
                    let done = todos.filter { if case .todo(true, _) = $0.kind { true } else { false } }.count
                    Text(verbatim: "\(done) of \(todos.count) done")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    notes.addTodo()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .pointerStyle(.link)
                .help("Add a to-do  ⌘N")
                Button {
                    notes.archive()
                } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.borderless)
                .pointerStyle(.link)
                .help("Archive these notes and start empty")
                .disabled(notes.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    notes.revealInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .pointerStyle(.link)
                .help("Show the notes file and archive in Finder")
            }
            .font(.system(size: 12))

            if notes.isEditing {
                TextEditor(text: Binding(get: { notes.text }, set: { notes.update($0) }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .onAppear { editorFocused = true }
                    .onChange(of: editorFocused) { _, focused in
                        if !focused { notes.isEditing = false }
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if notes.text.isEmpty {
                            Text("Click to write. Lines starting with [ ] become to-dos.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(notes.lines) { line in
                            switch line.kind {
                            case .todo(let done, let text):
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Button {
                                        notes.toggle(line: line.id)
                                    } label: {
                                        Image(systemName: done ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(done ? Color.accentColor : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .pointerStyle(.link)
                                    Text(linkified(text))
                                        .strikethrough(done)
                                        .foregroundStyle(done ? .secondary : .primary)
                                }
                            case .text(let text):
                                Text(linkified(text))
                            case .blank:
                                Color.clear.frame(height: 4)
                            }
                        }
                    }
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { notes.isEditing = true }
                .pointerStyle(.horizontalText)
            }
        }
    }

    /// "#5217" in the accent color.
    private func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in text.matches(of: /#\d{2,}/) {
            if let range = Range(match.range, in: result) { result[range].foregroundColor = .accentColor }
        }
        return result
    }
}
