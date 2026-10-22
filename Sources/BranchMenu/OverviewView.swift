import AppKit
import SwiftUI

struct OverviewView: View {
    @Bindable var model: OverviewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model, focused: $searchFocused)
            Divider()
            if model.showsToday {
                TodayStrip(model: model)
                Divider()
            }
            HStack(spacing: 0) {
                ColumnView(model: model, column: .sessions)
                Divider()
                ColumnView(model: model, column: .prs)
                Divider()
                ColumnView(model: model, column: .issues)
            }
            Divider()
            Footer(model: model)
        }
        .overlay { HoverLayer(model: model) }
        .overlay {
            if let composer = model.composer {
                ComposerView(model: model, composer: composer)
            }
        }
        .coordinateSpace(name: HoverLayer.space)
        .onChange(of: model.focusToken, initial: true) { searchFocused = true }
        // A light wash over the blurred background, so the panel reads lighter.
        .background(Color(light: 0xFAFAFC, dark: 0x1E1E20).opacity(0.72))
    }
}

// MARK: - Search and footer

private struct SearchBar: View {
    @Bindable var model: OverviewModel
    var focused: FocusState<Bool>.Binding
    @AppStorage(Settings.Key.hotKeyLabel) private var hotKeyLabel = Settings.defaultHotKey.label

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            TextField("Search sessions, PRs and issues", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused(focused)
            if model.store.isFetchingGitHub {
                ProgressView().controlSize(.small)
            }
            ProjectPicker(model: model)
            Button {
                model.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .help("Refresh sessions, PRs and issues  ⌘R")
            if !model.isInWindow {
                Button {
                    model.onOpenWindow?()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .pointerStyle(.link)
                .help("Keep it open as a window")
            }
            Button {
                model.onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .help("Settings  ⌘,")
            Keycap(text: hotKeyLabel)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

}

/// Shows one project's sessions, PRs and issues, or all of them.
private struct ProjectPicker: View {
    let model: OverviewModel

    var body: some View {
        Menu {
            Button {
                model.setProject(nil)
            } label: {
                if model.projectKey == nil { Label("All projects", systemImage: "checkmark") } else { Text("All projects") }
            }
            Divider()
            ForEach(model.store.repos, id: \.key) { repo in
                Button {
                    model.setProject(repo)
                } label: {
                    if model.projectKey == repo.key { Label(repo.name, systemImage: "checkmark") } else { Text(repo.name) }
                }
            }
        } label: {
            Label(model.projectName ?? "All projects", systemImage: "folder")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .pointerStyle(.link)
        .help("Show one project")
    }
}

/// "Mine" and "To review" above the PR column: tap one to show only it, again to show both.
private struct PRFilterPills: View {
    let model: OverviewModel

    var body: some View {
        let prs = model.projectItems(.prs)
        let mine = prs.filter { if case .myPR = $0.kind { true } else { false } }.count
        HStack(spacing: 6) {
            pill("Mine", count: mine, filter: .mine)
            pill("To review", count: prs.count - mine, filter: .review)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    private func pill(_ title: String, count: Int, filter: OverviewModel.PRFilter) -> some View {
        let active = model.prFilter == .all || model.prFilter == filter
        return Button {
            model.togglePRFilter(filter)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text(verbatim: "\(count)").opacity(0.7)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(model.prFilter == filter ? "Show both lists" : "Show only \(title.lowercased())")
    }
}

private struct Footer: View {
    let model: OverviewModel

    var body: some View {
        HStack(spacing: 16) {
            Text("⇥ next column")
            Text("↑↓ move")
            Text("↩ open")
            Text("⌘↩ start session")
            Text("⌘O GitHub")
            Text("esc close")
            Text("⌘L log")
            Spacer(minLength: 12)
            if let toast = model.toast {
                Button {
                    if toast.isError { model.onOpenLog?() }
                } label: {
                    Label(toast.text, systemImage: toast.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(toast.isError ? StatusColor.red : StatusColor.green)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .pointerStyle(toast.isError ? .link : nil)
                .help(toast.isError ? "\(toast.text)\nClick to open the log  ⌘L" : toast.text)
            } else if let error = model.store.overview.errors.first {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let summary = linkSummary {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 10, height: 10)
                    Text(summary)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(height: 34)
    }

    /// "Linked to #567: 1 PR · 2 sessions"
    private var linkSummary: String? {
        guard let item = model.selectedItem, !item.linked.isEmpty else { return nil }
        let prs = item.linked.filter { $0.hasPrefix("pr:") }.count
        let issues = item.linked.filter { $0.hasPrefix("issue:") }.count
        let sessions = item.linked.filter { $0.hasPrefix("session:") }.count
        let parts = [
            prs > 0 ? plural(prs, "PR") : nil,
            issues > 0 ? plural(issues, "issue") : nil,
            sessions > 0 ? plural(sessions, "session") : nil,
        ].compactMap { $0 }
        let name = item.number.map { "#\($0)" } ?? "this session"
        return "Linked to \(name): \(parts.joined(separator: " · "))"
    }
}

// MARK: - Columns

private struct ColumnView: View {
    let model: OverviewModel
    let column: Column

    var body: some View {
        let items = model.items(column)
        let isActive = model.column == column
        let selectedID = isActive ? model.selectedID(in: column) : nil
        let linked = model.linkedIDs

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(column.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? .primary : .secondary)
                Text(summary(items))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("⌘\(column.rawValue + 1)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { model.focus(column) }

            if column == .prs {
                PRFilterPills(model: model)
            }

            if items.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(sections(items), id: \.title) { section in
                                if section.title != Linker.waitingSection || model.showsToday {
                                    Text(section.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.top, 8)
                                        .padding(.bottom, 2)
                                }
                                ForEach(section.items) { item in
                                    RowView(
                                        model: model,
                                        item: item,
                                        isSelected: item.id == selectedID,
                                        isLinked: linked.contains(item.id)
                                    )
                                    .id(item.id)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func summary(_ items: [OverviewItem]) -> String {
        switch column {
        case .sessions:
            let waiting = items.filter { $0.section == Linker.waitingSection }.count
            return waiting > 0 ? "\(items.count) open · \(waiting) waiting" : "\(items.count) open"
        case .prs:
            return "\(items.count) open"
        case .issues:
            return "\(items.count) assigned to me"
        }
    }

    private var emptyText: String {
        if !model.query.isEmpty { return "No matches" }
        let loading = model.store.isFetchingGitHub || !model.store.overview.githubLoaded
        switch column {
        case .sessions: return "No open Claude Code sessions"
        case .prs: return loading ? "Loading from GitHub…" : "No open PRs"
        case .issues: return loading ? "Loading from GitHub…" : "No issues assigned to you"
        }
    }

    private struct Section {
        let title: String
        var items: [OverviewItem]
    }

    private func sections(_ items: [OverviewItem]) -> [Section] {
        var result: [Section] = []
        for item in items {
            if result.last?.title == item.section {
                result[result.count - 1].items.append(item)
            } else {
                result.append(Section(title: item.section, items: [item]))
            }
        }
        return result
    }
}

// MARK: - Rows

/// Colors for a row's content, inverted on the selected (accent-filled) row.
private struct RowStyle {
    let selected: Bool

    var primary: Color { selected ? .white : .primary }
    var secondary: Color { selected ? .white.opacity(0.8) : .secondary }
    func tint(_ color: Color) -> Color { selected ? .white : color }
}

private struct RowView: View {
    let model: OverviewModel
    let item: OverviewItem
    let isSelected: Bool
    let isLinked: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { model.select(item) }
            }
            .onTapGesture { model.activate(item) }
            .pointerStyle(.link)
            .modifier(RowHover(model: model, item: item))
            .contextMenu {
                if case .session(let session) = item.kind {
                    Button("Open session") { model.open(session) }
                } else if let session = item.linkedSessions.first {
                    Button("Open newest session") { model.open(session) }
                }
                Button("Start new session…") { model.startNew(item) }
                if let url = item.url {
                    Button("Open on GitHub") { model.openOnGitHub(item) }
                    Button("Copy link") { copy(url.absoluteString) }
                }
                if let branch = item.branch {
                    Button("Copy branch name") { copy(branch) }
                }
                if isPR, let branch = item.branch {
                    Divider()
                    let current = item.repo.flatMap { model.store.localStates[$0.key]?.branch }
                    Button(current == branch ? "Checked out locally" : "Check out \(branch) locally") { model.checkOut(item) }
                        .disabled(current == branch)
                }
            }
    }

    private var isSession: Bool {
        if case .session = item.kind { true } else { false }
    }


    private var isPR: Bool {
        switch item.kind {
        case .myPR, .review: true
        default: false
        }
    }

    @ViewBuilder
    private var content: some View {
        let style = RowStyle(selected: isSelected)
        switch item.kind {
        case .session(let session) where session.status == .waiting && !model.showsToday:
            WaitingPill(model: model, item: item, session: session, isSelected: isSelected)
        default:
            VStack(alignment: .leading, spacing: 4) {
                switch item.kind {
                case .session(let session):
                    SessionRow(item: item, session: session, style: style, showsRepo: model.showsRepo(in: item.column))
                case .myPR(let pr):
                    MyPRRow(model: model, item: item, pr: pr, style: style, showsRepo: model.showsRepo(in: item.column))
                case .review(let pr):
                    ReviewRow(model: model, item: item, pr: pr, style: style, showsRepo: model.showsRepo(in: item.column))
                case .issue(let issue):
                    IssueRow(model: model, item: item, issue: issue, style: style, showsRepo: model.showsRepo(in: item.column))
                }
                if !isSession && !item.linkedSessions.isEmpty && model.isExpanded(item) {
                    LinkedSessions(model: model, sessions: item.linkedSessions, style: style)
                        .padding(.leading, 19)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor : isLinked ? Color.accentColor.opacity(0.14) : .clear)
            )
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct SessionRow: View {
    let item: OverviewItem
    let session: LiveSession
    let style: RowStyle
    let showsRepo: Bool

    var body: some View {
        HStack(spacing: 9) {
            HostIcon(host: session.host, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 13))
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = session.suggestion.map({ "Suggested: \($0)" }) ?? session.summary {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if session.status == .running {
                Circle().fill(style.tint(.green)).frame(width: 7, height: 7)
            } else if session.status == .waiting {
                Circle().fill(style.tint(.orange)).frame(width: 7, height: 7)
            } else {
                Text(age(session.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(style.secondary)
            }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let ssh = session.sshHost { parts.append("ssh \(sshMachine(ssh))") }
        if showsRepo, let repo = item.repo { parts.append(repo.name) }
        parts.append(item.branch ?? "no branch")
        if let pr = item.branchPR { parts.append("#\(pr.number)") }
        return parts.joined(separator: " · ")
    }
}

struct WaitingPill: View {
    let model: OverviewModel
    let item: OverviewItem
    let session: LiveSession
    let isSelected: Bool

    private static let fill = Color(light: 0xFCEBD3, dark: 0x4A2E0E)
    private static let ink = Color(light: 0x5A3405, dark: 0xFCEBD3)

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(.orange).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(age(session.updatedAt))
                        .font(.system(size: 11))
                        .opacity(0.7)
                }
                // What it waits on: a question, a plan to approve, or a tool that wants permission.
                Text(session.waitingFor ?? "Waiting for you")
                    .font(.system(size: 11))
                    .opacity(0.85)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !session.replyOptions.isEmpty {
                    Text(session.replyOptions.joined(separator: "  ·  "))
                        .font(.system(size: 10.5, weight: .medium))
                        .opacity(0.65)
                        .lineLimit(1)
                        .help("The answers offered in the Claude app")
                }
            }
            Spacer(minLength: 8)
            Button {
                model.activate(item)
            } label: {
                Text("Resume")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(Self.fill)
                    .background(Self.ink, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Self.fill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        .sessionHoverCard(session, model: model)
        .padding(.bottom, 4)
    }

}

private struct MyPRRow: View {
    let model: OverviewModel
    let item: OverviewItem
    let pr: MyPR
    let style: RowStyle
    let showsRepo: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.tint(pr.isDraft ? .secondary : StatusColor.green))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                TitleLine(number: pr.number, title: pr.title, style: style)
                meta
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            SessionsControl(model: model, item: item, style: style, startTitle: "Start now")
        }
    }

    /// One Text, so the line truncates at its end instead of squeezing every part.
    private var meta: Text {
        var parts: [Text] = []
        func add(_ text: String, _ color: Color? = nil) {
            parts.append(Text(verbatim: text).foregroundStyle(color.map(style.tint) ?? style.secondary))
        }
        if showsRepo { add(pr.repo.name) }
        if pr.isDraft {
            add("draft")
        } else {
            switch pr.review {
            case .approved: add("approved", StatusColor.green)
            case .changesRequested: add("changes requested", StatusColor.red)
            case .reviewRequired: add("review required", StatusColor.amber)
            case nil: break
            }
        }
        switch pr.checks.state {
        case .failing: add("\(pr.checks.failing) failing", StatusColor.red)
        case .pending: add("checks running", StatusColor.amber)
        case .passing: add("checks pass", StatusColor.green)
        case .none: break
        }
        add(pr.branch)
        if !pr.closes.isEmpty { add("closes " + pr.closes.map { "#\($0)" }.joined(separator: ", ")) }

        let separator = Text(verbatim: "  ")
        return parts.dropFirst().reduce(parts.first ?? Text(verbatim: "")) { $0 + separator + $1 }
    }
}

private struct ReviewRow: View {
    let model: OverviewModel
    let item: OverviewItem
    let pr: ReviewRequest
    let style: RowStyle
    let showsRepo: Bool

    var body: some View {
        HStack(spacing: 9) {
            Text(initials)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(style.selected ? Color.accentColor : Color(light: 0x0B4FA8, dark: 0xBFD6F6))
                .frame(width: 20, height: 20)
                .background(Circle().fill(style.selected ? Color.white : Color(light: 0xDCE6F2, dark: 0x22344A)))
            VStack(alignment: .leading, spacing: 2) {
                TitleLine(number: pr.number, title: pr.title, style: style)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            SessionsControl(model: model, item: item, style: style, startTitle: "Start review")
        }
    }

    private var initials: String {
        let words = (pr.authorName ?? pr.authorLogin).split(separator: " ")
        let letters = words.count >= 2 ? [words[0].first, words[1].first] : [words.first?.first, words.first?.dropFirst().first]
        return String(letters.compactMap { $0 }).uppercased()
    }

    private var meta: String {
        var parts: [String] = []
        if showsRepo { parts.append(pr.repo.name) }
        parts.append("@\(pr.authorLogin)")
        parts.append("opened \(age(pr.createdAt)) ago")
        return parts.joined(separator: " · ")
    }
}

private struct IssueRow: View {
    let model: OverviewModel
    let item: OverviewItem
    let issue: Issue
    let style: RowStyle
    let showsRepo: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "smallcircle.filled.circle")
                .font(.system(size: 13))
                .foregroundStyle(style.tint(StatusColor.green))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                TitleLine(number: issue.number, title: issue.title, style: style)
                (statusText + Text(verbatim: meta).foregroundStyle(style.secondary))
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            SessionsControl(model: model, item: item, style: style, startTitle: "Start now")
        }
    }

    /// The board status, coloured by what it means for starting work.
    private var statusText: Text {
        guard let status = issue.boardStatus else { return Text(verbatim: "") }
        let color: Color = switch issue.stage {
        case .blocked: StatusColor.red
        case .notStarted: StatusColor.green
        case .underway: StatusColor.amber
        }
        return Text(verbatim: status).foregroundStyle(style.tint(color)) + Text(verbatim: meta.isEmpty ? "" : "  ")
    }

    private var meta: String {
        var parts: [String] = []
        if showsRepo { parts.append(issue.repo.name) }
        if !item.linkedPRNumbers.isEmpty {
            parts.append("PR " + item.linkedPRNumbers.map { "#\($0)" }.joined(separator: ", "))
        }
        parts.append(contentsOf: issue.labels.prefix(2))
        return parts.isEmpty && issue.boardStatus == nil ? "no labels" : parts.joined(separator: " · ")
    }
}

/// Session rows show the hover card; PR and issue rows say a click opens GitHub.
private struct RowHover: ViewModifier {
    let model: OverviewModel
    let item: OverviewItem

    func body(content: Content) -> some View {
        if case .session(let session) = item.kind, session.status != .waiting || model.showsToday {
            content.sessionHoverCard(session, model: model)
        } else if case .session = item.kind {
            content  // the waiting pill has its own
        } else {
            content.help("Open on GitHub")
        }
    }
}

/// The sessions under a PR or issue; each opens in the Claude app (or its terminal).
private struct LinkedSessions: View {
    let model: OverviewModel
    let sessions: [LiveSession]
    let style: RowStyle

    private let limit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(sessions.prefix(limit)) { session in
                LinkedSessionRow(model: model, session: session, style: style)
            }
            if sessions.count > limit {
                Text("+ \(sessions.count - limit) more")
                    .font(.system(size: 11))
                    .foregroundStyle(style.secondary)
                    .padding(.leading, 6)
            }
        }
    }
}

private struct LinkedSessionRow: View {
    let model: OverviewModel
    let session: LiveSession
    let style: RowStyle
    @State private var hovering = false

    var body: some View {
        Button {
            model.open(session)
        } label: {
            HStack(spacing: 7) {
                HostIcon(host: session.host, size: 14)
                Text(session.name)
                    .font(.system(size: 12))
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                if let ssh = session.sshHost {
                    Text("ssh \(sshMachine(ssh))")
                        .font(.system(size: 11))
                        .foregroundStyle(style.secondary)
                }
                Spacer(minLength: 6)
                switch session.status {
                case .waiting:
                    Text("waiting").font(.system(size: 11)).foregroundStyle(style.tint(.orange))
                case .running:
                    Circle().fill(style.tint(.green)).frame(width: 6, height: 6)
                case .idle:
                    Text(age(session.updatedAt)).font(.system(size: 11)).foregroundStyle(style.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? (style.selected ? Color.white.opacity(0.18) : Color.primary.opacity(0.07)) : .clear)
            )
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .sessionHoverCard(session, model: model)
    }
}

/// "3 sessions ⌄" opens and closes a row's session list; with none, the start button instead.
private struct SessionsControl: View {
    let model: OverviewModel
    let item: OverviewItem
    let style: RowStyle
    let startTitle: String

    var body: some View {
        let count = item.linkedSessions.count
        if count == 0 {
            StartButton(title: startTitle) { model.startNew(item) }
        } else {
            let open = model.isExpanded(item)
            let waiting = item.linkedSessions.contains { $0.status == .waiting }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.setExpanded(item, !open) }
            } label: {
                HStack(spacing: 4) {
                    if waiting { Circle().fill(.orange).frame(width: 6, height: 6) }
                    Text(verbatim: "\(count)")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(style.selected ? Color.white.opacity(0.2) : Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(open ? "Hide \(count) session\(count == 1 ? "" : "s")  ←" : "Show \(count) session\(count == 1 ? "" : "s")  →")
        }
    }
}

private struct StartButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "play.fill")
        }
        .controlSize(.small)
        .pointerStyle(.link)
        .help("Start a new session with a starter text")
    }
}

/// "devbox" from "me@devbox".
private func sshMachine(_ host: String) -> String {
    host.split(separator: "@").last.map(String.init) ?? host
}

private struct TitleLine: View {
    let number: Int
    let title: String
    let style: RowStyle

    var body: some View {
        // verbatim: a localized "#\(number)" would print 1234 as "1 234" in some locales.
        (Text(verbatim: "#\(number) ").foregroundStyle(style.secondary) + Text(verbatim: title).foregroundStyle(style.primary))
            .font(.system(size: 13))
            .lineLimit(1)
    }
}

// MARK: - Shared bits

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
    }
}

private struct HostIcon: View {
    let host: HostApp?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = host?.bundleURL {
                Image(nsImage: IconCache.icon(for: url)).resizable()
            } else {
                Image(systemName: "terminal").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

@MainActor
private enum IconCache {
    static var icons: [URL: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let icon = icons[url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = icon
        return icon
    }
}

enum StatusColor {
    static let green = Color(light: 0x1A7F37, dark: 0x3FB950)
    static let red = Color(light: 0xCF222E, dark: 0xF85149)
    static let amber = Color(light: 0x9A6700, dark: 0xD29922)
}

extension Color {
    /// A color that follows the system appearance, given as 0xRRGGBB for each mode.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

func age(_ date: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    default: return "\(Int(seconds / 86_400))d"
    }
}

private func sessionCount(_ count: Int) -> String {
    count == 0 ? "no sessions" : plural(count, "session")
}

private func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
