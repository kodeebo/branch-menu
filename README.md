# Branch Menu

An overview of your Claude Code sessions, your pull requests and your GitHub issues in one panel,
with a quick way to switch to the right session or start a new one.

Open it by clicking the branch icon in the menu bar or pressing **⌘B** anywhere (change it in Settings). It opens
centered on the screen with the mouse.

- **Sessions:** your Claude app sessions from the last 7 days (starred ones always), plus CLI
  sessions running in terminals. Sessions waiting for input sit at the top in an orange pill.
  Clicking one opens it in the Claude app (or brings its terminal forward).
- **Pull requests:** your open PRs (review state, checks, issues they close) and PRs where your
  review was requested. Clicking one opens it on GitHub; its sessions are listed under it.
- **Issues:** issues assigned to you, with their PR and sessions. Clicking one opens it on GitHub.
  With no session yet, **Start now** opens a new Claude app session with a starter text you can
  edit first.

Pointing at a row highlights everything linked to it. For example, an issue lights up its PR and
the sessions working on either.

| Key | Action |
|---|---|
| ⌘B | Open or close the overview (configurable) |
| ↑ ↓ / ⇥ / ⌘1–3 | Move within a column / to the next column / to a column |
| ↩ | Open: a session in the Claude app, a PR or issue on GitHub |
| ⌘↩ | Start a new session (with the starter text) |
| ⌘O | Open on GitHub |
| ⌘R | Refresh now (also the ↻ button; sessions refresh every 2 s, GitHub every 2 min) |
| ⌘, | Settings |
| esc | Clear the search, then close |

Right-clicking the menu bar icon gives Refresh, Settings and Quit.

## Build and run

```sh
./scripts/bundle.sh          # builds build/BranchMenu.app
open build/BranchMenu.app
```

For checking without clicking:

```sh
build/BranchMenu.app/Contents/MacOS/BranchMenu --dump                       # print the three columns
build/BranchMenu.app/Contents/MacOS/BranchMenu --snapshot /tmp/panel.png    # render the panel to a PNG
build/BranchMenu.app/Contents/MacOS/BranchMenu --snapshot /tmp/start.png --compose
```

Requires macOS 15+, Xcode / Swift 6, and the GitHub CLI (`gh`) logged in.

## How it works

| Data | Source |
|---|---|
| Claude app sessions | `~/Library/Application Support/Claude/claude-code-sessions/…/local_*.json`: title, folder, SSH host, the PRs the app linked, the branches the session committed to |
| Running sessions | `~/.claude/sessions/<pid>.json`, kept only while that `claude` process is alive |
| Status | `waitingFor` set → waiting, `status: "busy"` → running, else idle |
| Session branch | the last branch the session committed to; else the app's worktree branch; else `gitBranch` on the last transcript message |
| Repos | the folders of open sessions, folders used in the last 3 weeks (from the transcripts), and folders added in Settings |
| PRs and issues | `gh pr list` / `gh issue list` per GitHub repo, cached 2 min, refreshed when the panel opens |
| Host app | walk parent processes up to the first regular app |

Linking:

- **Session ↔ PR or issue**, first match wins:
  1. The session's title names it ("Cross-review 1234", "Issue 567 follow-up").
  2. Claude app sessions: the PRs the app linked, and the PRs of branches the session committed to.
     A Claude app session with neither is not linked, whatever branch was checked out.
  3. Terminal sessions: the branch they ran on (and an issue number in that branch name).
- **PR ↔ issue:** GitHub's closing references ("closes #567").

Switching and starting use the Claude app's undocumented deep links:
`claude://code/continue?session=local_…` and `claude://code/new?folder=…&q=…`. With
"New worktree" chosen, Start now first runs `git worktree add` in `<repo>/.claude/worktrees/`.
The session file format and the deep links may change when Claude Code updates.
