import SwiftUI

/// The session under the mouse and where its row sits, in the overview's coordinates.
struct HoverTarget {
    let session: LiveSession
    let frame: CGRect
}

extension View {
    /// Shows the session's hover card while the mouse is over this view.
    func sessionHoverCard(_ session: LiveSession, model: OverviewModel) -> some View {
        modifier(SessionHover(session: session, model: model))
    }
}

/// The hover is tracked on the row itself (an invisible background view behind it never sees the
/// mouse), and the row's frame is kept up to date as it scrolls.
private struct SessionHover: ViewModifier {
    let session: LiveSession
    let model: OverviewModel
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HoverLayer.space)) } action: { newFrame in
                frame = newFrame
                if model.hover?.session.id == session.id {
                    model.hover = HoverTarget(session: session, frame: newFrame)
                }
            }
            .onHover { inside in
                if inside {
                    model.hover = HoverTarget(session: session, frame: frame)
                } else if model.hover?.session.id == session.id {
                    model.hover = nil
                }
            }
    }
}

/// Draws the hover card right above the hovered row, as wide as the row, so it stays over the
/// row's own column; below the row when there is no room above. Kept inside the overview.
struct HoverLayer: View {
    nonisolated static let space = "overview"
    private static let gap: CGFloat = 6

    let model: OverviewModel
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            if let target = model.hover {
                let bounds = geometry.size
                let width = Self.width(for: target.frame, in: bounds)
                let origin = Self.place(target.frame, width: width, height: cardHeight, in: bounds)
                SessionCard(model: model, session: target.session)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .offset(x: origin.x, y: origin.y)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.08), value: model.hover?.session.id)
    }

    /// The row's width, but readable: no narrower than 320 and no wider than 440.
    private static func width(for row: CGRect, in bounds: CGSize) -> CGFloat {
        min(max(row.width, 320), 440, bounds.width - 2 * gap)
    }

    private static func place(_ row: CGRect, width: CGFloat, height: CGFloat, in bounds: CGSize) -> CGPoint {
        let x = min(max(row.minX, gap), bounds.width - width - gap)
        let above = row.minY - gap - height
        let y = above >= gap ? above : min(row.maxY + gap, bounds.height - height - gap)
        return CGPoint(x: x, y: max(y, gap))
    }
}

private struct SessionCard: View {
    let model: OverviewModel
    let session: LiveSession

    /// The Sessions column's row for this session carries its repo, branch and PR.
    private var item: OverviewItem? {
        model.store.overview.sessions.first { $0.id == "session:\(session.id)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                HoverHostIcon(host: session.host)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                status
            }

            if let recap = session.recap ?? session.summary {
                Text(recap)
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(12)
            } else {
                Text("No recap yet for this session.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            if session.status == .waiting, let question = session.waitingFor {
                VStack(alignment: .leading, spacing: 4) {
                    Text(question)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if !session.replyOptions.isEmpty {
                        Text(session.replyOptions.joined(separator: "  ·  "))
                            .font(.system(size: 11))
                            .opacity(0.75)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(Color(light: 0x5A3405, dark: 0xFCEBD3))
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(light: 0xFCEBD3, dark: 0x4A2E0E)))
            }

            HStack(spacing: 6) {
                Text(place)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text("active \(age(session.updatedAt) == "now" ? "just now" : "\(age(session.updatedAt)) ago")")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(light: 0xFFFFFF, dark: 0x2C2C2E)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    private var meta: String {
        var parts: [String] = []
        if let ssh = session.sshHost { parts.append("ssh \(ssh.split(separator: "@").last.map(String.init) ?? ssh)") }
        if let repo = item?.repo { parts.append(repo.name) }
        if let branch = item?.branch { parts.append(branch) }
        if let pr = item?.branchPR { parts.append("#\(pr.number)") }
        return parts.joined(separator: " · ")
    }

    private var place: String {
        let app = session.sshHost.map { "SSH \($0)" } ?? (session.isClaudeApp ? "Claude app" : session.host?.name ?? "Terminal")
        return "\(app) · \((session.cwd as NSString).abbreviatingWithTildeInPath)"
    }

    @ViewBuilder
    private var status: some View {
        switch session.status {
        case .waiting:
            chip("waiting", StatusColor.amber)
        case .running:
            chip("running", StatusColor.green)
        case .idle:
            EmptyView()
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct HoverHostIcon: View {
    let host: HostApp?

    var body: some View {
        Group {
            if let url = host?.bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "terminal").foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}
