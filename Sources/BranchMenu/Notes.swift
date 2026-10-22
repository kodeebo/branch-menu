import AppKit
import Observation
import SwiftUI

/// Notes as Markdown files in `~/Library/Application Support/Branch Menu/Notes/`, one open at a
/// time. The file name is the note's title. Archive moves the text to `Archive/<title> <date>.md`
/// and empties the note. Lines starting with `[ ]` are to-dos.
@MainActor
@Observable
final class NotesStore {
    private(set) var name: String
    private(set) var text = ""
    /// The editor is open (else the note shows rendered, with clickable checkboxes).
    var isEditing = false
    /// The title is being renamed.
    var isRenaming = false

    static let base = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Branch Menu", directoryHint: .isDirectory)
    static let folder = base.appending(path: "Notes", directoryHint: .isDirectory)
    private static let currentKey = "currentNote"

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        // Before there were several notes there was one file, Notes.md, next to the folder.
        let single = Self.base.appending(path: "Notes.md")
        if fm.fileExists(atPath: single.path), !fm.fileExists(atPath: Self.folder.appending(path: "Notes.md").path) {
            try? fm.moveItem(at: single, to: Self.folder.appending(path: "Notes.md"))
        }
        let saved = UserDefaults.standard.string(forKey: Self.currentKey)
        let names = Self.listNames()
        name = saved.flatMap { names.contains($0) ? $0 : nil } ?? names.first ?? "Notes"
        text = (try? String(contentsOf: url(for: name), encoding: .utf8)) ?? ""
    }

    /// All notes, most recently changed first.
    var names: [String] { Self.listNames() }

    private static func listNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .map { url in (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0.deletingPathExtension().lastPathComponent }
    }

    private func url(for name: String) -> URL { Self.folder.appending(path: "\(name).md") }

    func update(_ newText: String) {
        text = newText
        save(text, to: url(for: name))
    }

    func open(_ newName: String) {
        guard newName != name else { return }
        name = newName
        text = (try? String(contentsOf: url(for: newName), encoding: .utf8)) ?? ""
        isEditing = false
        UserDefaults.standard.set(newName, forKey: Self.currentKey)
    }

    func newNote() {
        let existing = Set(names)
        var candidate = "Untitled"
        var counter = 2
        while existing.contains(candidate) {
            candidate = "Untitled \(counter)"
            counter += 1
        }
        save("", to: url(for: candidate))
        open(candidate)
        isRenaming = true
    }

    /// Renames the note's file. Returns false when the name is empty or taken.
    @discardableResult
    func rename(to proposed: String) -> Bool {
        // A file name can't hold "/" or ":", or start with a dot.
        let cleaned = proposed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        isRenaming = false
        guard !cleaned.isEmpty, cleaned != name else { return cleaned == name }
        guard !names.contains(cleaned) else { return false }
        save(text, to: url(for: name))
        do {
            try FileManager.default.moveItem(at: url(for: name), to: url(for: cleaned))
        } catch {
            Log.error("notes", "could not rename \(name) to \(cleaned): \(error.localizedDescription)")
            return false
        }
        name = cleaned
        UserDefaults.standard.set(cleaned, forKey: Self.currentKey)
        return true
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
        save(text, to: Self.base.appending(path: "Archive/\(name) \(stamp).md"))
        update("")
        isEditing = false
    }

    func revealInFinder() {
        if !FileManager.default.fileExists(atPath: url(for: name).path) { save(text, to: url(for: name)) }
        NSWorkspace.shared.activateFileViewerSelecting([url(for: name)])
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

/// The notes card: the note's title (click to rename), a switcher, and the note rendered with
/// clickable checkboxes, or the editor on click.
struct NotesCard: View {
    let model: OverviewModel
    @FocusState private var editorFocused: Bool
    @FocusState private var titleFocused: Bool
    @State private var draftTitle = ""

    private var notes: NotesStore { model.notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                title
                let todos = notes.lines.filter { if case .todo = $0.kind { true } else { false } }
                if !todos.isEmpty && !notes.isRenaming {
                    let done = todos.filter { if case .todo(true, _) = $0.kind { true } else { false } }.count
                    Text(verbatim: "\(done) of \(todos.count) done")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
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
                .help("Archive this note's text and start it empty")
                .disabled(notes.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                switcher
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
                rendered
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        if notes.isRenaming {
            TextField("Note title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .focused($titleFocused)
                .onAppear {
                    draftTitle = notes.name
                    titleFocused = true
                }
                .onSubmit {
                    if !notes.rename(to: draftTitle) { model.flash("A note called \u{201C}\(draftTitle)\u{201D} already exists") }
                }
                .onChange(of: titleFocused) { _, focused in
                    if !focused && notes.isRenaming { notes.rename(to: draftTitle) }
                }
        } else {
            Button {
                notes.isRenaming = true
            } label: {
                Text(notes.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Rename this note")
        }
    }

    /// Lists the notes; picking one switches to it.
    private var switcher: some View {
        Menu {
            ForEach(notes.names, id: \.self) { name in
                Button {
                    notes.open(name)
                } label: {
                    if name == notes.name { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button("New Note") { notes.newNote() }
            Button("Show in Finder") { notes.revealInFinder() }
        } label: {
            Image(systemName: "chevron.down.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerStyle(.link)
        .help("Switch note")
    }

    private var rendered: some View {
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

    /// "#123" in the accent color.
    private func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in text.matches(of: /#\d{2,}/) {
            if let range = Range(match.range, in: result) { result[range].foregroundColor = .accentColor }
        }
        return result
    }
}
