# Branch Menu

An overview of your Claude Code sessions, your pull requests and your GitHub issues in one panel,
with a quick way to switch to the right session or start a new one.

Open it by clicking the branch icon in the menu bar (an orange count next to it says how many
sessions wait for input) or pressing **⌥⌘Space** anywhere (change it in Settings). macOS uses ⌥⌘Space for
"Show Finder search window", so turn that off first: System Settings › Keyboard › Keyboard Shortcuts ›
Spotlight. It opens
centered on the screen with the mouse.

- **Sessions:** your Claude app sessions from the last 7 days (starred ones always), plus CLI
  sessions running in terminals. Sessions waiting for input sit at the top in an orange pill.
  Clicking one opens it in the Claude app (or brings its terminal forward).
- **Pull requests:** your open PRs (review state, checks, issues they close) and PRs where your
  review was requested. Clicking one opens it on GitHub; its sessions are listed under it.
- **Issues:** issues assigned to you, with their PR and sessions. Clicking one opens it on GitHub.
  With no session yet, **Start now** opens a new Claude app session with a starter text you can
  edit first.

Above the columns, **Today** (⌘T to hide) shows:

- **Waiting for you:** sessions that stopped on a question, an approval or a review, with what
  each one needs, taken from the Claude app's own wrap-up of the session.
- **Next up:** what to merge (approved and green), answer (comments or change requests from people
  since your last push; bots don't count), fix (failing checks), review (oldest request first) and
  start (assigned issues with nothing yet), each with a button.
- **Notes:** Markdown notes in `~/Library/Application Support/Branch Menu/Notes/`, one open at a
  time. Click the title to rename the note, and use the ⌄ menu to switch notes or start a new one.
  Lines starting with `[ ]` become to-dos you can tick off; ⌘N adds one. **Archive** moves the text
  to `Archive/<title> <date>.md` and empties the note.
- Which branch each repo's main checkout is on, and how many files are changed there.

Hovering a session shows its recap: the paragraph the Claude app wrote at the end of its last turn on what it did and where things stand.

Pointing at a row highlights everything linked to it. For example, an issue lights up its PR and
the sessions working on either.

| Key | Action |
|---|---|
| ⌥⌘Space | Open or close the overview (configurable) |
| ↑ ↓ / ⇥ / ⌘1–3 | Move within a column / to the next column / to a column |
| ↩ | Open: a session in the Claude app, a PR or issue on GitHub |
| ⌘↩ | Start a new session (with the starter text) |
| ⌘O | Open on GitHub |
| ⌘R | Refresh now (also the ↻ button; sessions refresh every 2 s, GitHub every 2 min) |
| ⌘T / ⌘N | Show or hide Today / add a to-do |
| → / ← | Show or hide a PR's or issue's sessions (with an empty search) |
| ⌘L | Log |
| ⌘, | Settings |
| esc | Clear the search, then close |

To keep it up while you work elsewhere, click the window button in the search bar (or right-click
the menu bar icon › Open as Window). It becomes a normal window, in the Dock and ⌘Tab, that
remembers its size and place; the shortcut and the menu bar icon then bring it to the front.
Close it to go back to the panel.

Right-clicking the menu bar icon gives Open as Window, Refresh, Settings, Show Log and Quit.

**Log:** ⌘L in the overview, right-click › Show Log, or click an error in the footer. It lists
every command the app runs (with exit code, time and error output), every link it opens in the
Claude app, checkouts, summaries and sessions that start or stop waiting. "Show routine
commands" adds the git and gh calls behind each refresh. The same lines go to
`~/Library/Logs/Branch Menu/branch-menu.log`.

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
| Status | running while a turn runs; waiting when a question, a plan or a permission prompt is open (see below); else idle |
| Session branch | the last branch the session committed to; else the app's worktree branch; else `gitBranch` on the last transcript message |
| Repos | the folders of open sessions, folders used in the last 3 weeks (from the transcripts), and folders added in Settings |
| PRs and issues | `gh pr list` / `gh issue list` per GitHub repo, cached 2 min, refreshed when the panel opens |
| Host app | walk parent processes up to the first regular app |

Waiting for you, from three signals:

- **Question cards.** The Claude app ends a turn with an `mcp__ccd_turn__wrap_up` tool call; when it
  carries `ask` (and `actions`, the answer buttons), the app shows a question card. A session waits
  while the card belongs to its latest turn (`lastTurnEdgeAt` in the app's session file) and you
  have not written since. Older cards are history.
- **Open wrap-up questions** (`turnWrapUp.needsUser` in the app's session file), with the same
  "you have not written since" rule.
- **Pending prompts in a running session**, read from the end of its transcript: a question
  (`AskUserQuestion`) or plan (`ExitPlanMode`), an instant tool (Edit, Write, Read, …) with no result
  after 4 seconds, or a Bash call with no command running under it.

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
