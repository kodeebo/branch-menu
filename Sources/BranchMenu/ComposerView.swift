import SwiftUI

/// "Start a session": shows where the session will run and the starter text, both editable.
struct ComposerView: View {
    let model: OverviewModel
    @Bindable var composer: ComposerModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .onTapGesture { model.closeComposer() }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start a session").font(.headline)
                    Text(composer.heading)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Opens in").foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Label("Claude app", systemImage: "sparkle")
                            if !composer.sshTargets.isEmpty {
                                Picker("Machine", selection: $composer.target) {
                                    Label("This Mac", systemImage: "laptopcomputer").tag(ComposerModel.local)
                                    ForEach(composer.sshTargets, id: \.host) { target in
                                        Label("\(target.name) (SSH)", systemImage: "server.rack").tag(target.host)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .pointerStyle(.link)
                            }
                        }
                    }
                    if composer.target != ComposerModel.local {
                        GridRow {
                            Text("Folder").foregroundStyle(.secondary)
                            TextField("Folder on the remote machine", text: $composer.remoteFolder)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            Text("From your earlier sessions there. New worktrees are only made on this Mac.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if composer.target == ComposerModel.local {
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        Picker("Folder", selection: $composer.folderMode) {
                            ForEach(FolderMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    if composer.folderMode == .newWorktree {
                        GridRow {
                            Text("Branch").foregroundStyle(.secondary)
                            TextField("Branch", text: $composer.branch)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text(folderPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    }
                }
                .font(.system(size: 13))

                TextEditor(text: $composer.text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                    .focused($editorFocused)

                if let error = composer.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Edit templates…") { model.onOpenSettings?() }
                        .buttonStyle(.link)
                        .pointerStyle(.link)
                    Spacer()
                    Button("Cancel") { model.closeComposer() }
                        .pointerStyle(.link)
                    Button {
                        Task { await model.startComposer() }
                    } label: {
                        HStack(spacing: 6) {
                            if composer.isStarting { ProgressView().controlSize(.small) }
                            Text(composer.target == ComposerModel.local ? "Start in Claude" : "Start on \(composer.sshTargets.first { $0.host == composer.target }?.name ?? "SSH")")
                            Text("⌘↩").opacity(0.7)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .pointerStyle(.link)
                    .disabled(composer.isStarting)
                }
            }
            .padding(22)
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        }
        .onAppear { editorFocused = true }
    }

    private var folderPath: String {
        let path = composer.folderMode == .newWorktree
            ? Starter.worktreePath(repoRoot: composer.repo.root, branch: composer.branch)
            : composer.repo.root
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
