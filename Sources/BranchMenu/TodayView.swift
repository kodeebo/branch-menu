import SwiftUI

/// The band above the columns: what waits for you, what to do next, and your notes.
struct TodayStrip: View {
    let model: OverviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Today").font(.system(size: 14, weight: .semibold))
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                LocalCheckouts(model: model)
                Spacer()
                Button {
                    model.toggleToday()
                } label: {
                    HStack(spacing: 4) {
                        Text("Hide")
                        Keycap(text: "⌘T")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .pointerStyle(.link)
            }
            .padding(.horizontal, 4)

            HStack(alignment: .top, spacing: 12) {
                Card { WaitingCard(model: model) }
                    .frame(width: 290)
                Card { NextUpCard(model: model) }
                    .frame(maxWidth: .infinity)
                Card { NotesCard(model: model) }
                    .frame(width: 340)
            }
            .frame(height: 220)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.primary.opacity(0.025))
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(light: 0xFFFFFF, dark: 0x2C2C2E)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// "myapp on main · 3 changed": where localhost points right now.
private struct LocalCheckouts: View {
    let model: OverviewModel

    var body: some View {
        HStack(spacing: 12) {
            ForEach(model.localCheckouts, id: \.0.key) { repo, state in
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(verbatim: model.projectKey == nil ? "\(repo.name) on " : "on ")
                        .foregroundStyle(.secondary)
                        + Text(verbatim: state.branch).font(.system(size: 12, weight: .medium, design: .monospaced))
                    if state.changes > 0 {
                        Text(verbatim: "· \(state.changes) changed").foregroundStyle(StatusColor.amber)
                    }
                }
                .font(.system(size: 12))
                .help("The main checkout of \(repo.name) (\((repo.root as NSString).abbreviatingWithTildeInPath)) is on \(state.branch)")
            }
        }
        .lineLimit(1)
    }
}

private struct WaitingCard: View {
    let model: OverviewModel

    var body: some View {
        let waiting = model.waitingItems
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Waiting for you").font(.system(size: 12.5, weight: .semibold))
                if !waiting.isEmpty {
                    Text(verbatim: "\(waiting.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if waiting.isEmpty {
                Text("Nothing is waiting for you.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(waiting) { item in
                            if case .session(let session) = item.kind {
                                WaitingPill(model: model, item: item, session: session, isSelected: false)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NextUpCard: View {
    let model: OverviewModel

    var body: some View {
        let items = model.nextUp
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Next up").font(.system(size: 12.5, weight: .semibold))
                if !items.isEmpty {
                    Text(verbatim: "\(items.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.curator.isAvailable && !items.isEmpty {
                    CuratorControl(model: model)
                }
            }
            if items.isEmpty {
                Text(model.store.overview.githubLoaded ? "Nothing to merge, answer or review." : "Loading from GitHub…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { NextUpRow(model: model, next: $0) }
                    }
                }
            }
        }
    }
}

/// "Ask Claude" to sort the list; once sorted, when it was and a way back to the rules.
private struct CuratorControl: View {
    let model: OverviewModel

    var body: some View {
        HStack(spacing: 8) {
            if model.curator.isRunning {
                ProgressView().controlSize(.mini)
                Text("Claude is sorting…")
            } else if model.nextUpIsCurated, let date = model.curator.curatedAt {
                Image(systemName: "sparkles")
                let when = age(date) == "now" ? "just now" : "\(age(date)) ago"
                Text(verbatim: "Sorted by Claude \(when)" + (model.nextUpChangedSinceCurated ? " · list changed" : ""))
                link("Again") { model.askClaude() }
                link("Rules") { model.curator.clear() }
            } else {
                link("Ask Claude", icon: "sparkles") { model.askClaude() }
                    .help("Let Claude pick and order Next up, using your sessions and their recaps")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func link(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

private struct NextUpRow: View {
    let model: OverviewModel
    let next: NextUpItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 9) {
                Image(systemName: icon.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(icon.color)
                    .frame(width: 16)
                (Text(verbatim: next.action + " ").fontWeight(.medium) + Text(verbatim: next.title).foregroundStyle(.secondary))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(next.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Button(button.title, action: button.action)
                    .controlSize(.small)
                    .pointerStyle(.link)
            }
            // Claude's reason gets the whole width under the title.
            if let note = next.note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 25)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help([next.reason, next.note].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        let item = next.item
        let noun = item.column == .issues ? "issue" : "PR"
        if let number = item.number, item.url != nil {
            Button("Open \(noun) #\(number) on GitHub") { model.openOnGitHub(item) }
        }
        Button("Show in \(item.column.title)") { model.reveal(item) }
        Divider()
        if let session = item.linkedSessions.first {
            Button("Open session “\(session.name)”") { model.open(session) }
        }
        Button("Start new session…") { model.startNew(item) }
        if let url = item.url {
            Divider()
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    private var icon: (name: String, color: Color) {
        switch next.kind {
        case .merge: ("arrow.triangle.merge", Color(light: 0x8250DF, dark: 0xA371F7))
        case .answer: ("text.bubble", StatusColor.amber)
        case .update: ("arrow.triangle.branch", StatusColor.amber)
        case .fixChecks: ("xmark.octagon", StatusColor.red)
        case .review: ("eye", Color.accentColor)
        case .start: ("play.fill", StatusColor.green)
        }
    }

    private var button: (title: String, action: () -> Void) {
        let item = next.item
        let session = item.linkedSessions.first
        switch next.kind {
        case .merge:
            return ("Open PR", { model.openOnGitHub(item) })
        case .answer:
            return ("Open PR", { model.openOnGitHub(item) })
        case .fixChecks, .update:
            if let session { return ("Resume", { model.open(session) }) }
            return ("Start now", { model.startNew(item) })
        case .review:
            if let session { return ("Resume", { model.open(session) }) }
            return ("Start review", { model.startNew(item) })
        case .start:
            return ("Start now", { model.startNew(item) })
        }
    }
}
