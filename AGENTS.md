# Takes: notes for agents

Takes is a Mac app (plus an iPhone app) for video. The user writes a script, records takes, and gets
the posts for every platform. Claude Code does the storyboard, the edit and the post drafts
through the `takes` MCP server. This file is for agents that work on the Takes code.

## Two kinds of agents

1. **Agents that change this repo** (you, now): read this file.
2. **Agents that use Takes** (the Takes chat, or Claude Code in a terminal) to storyboard, edit
   or post. They run outside this repo, so they never read this file. They learn Takes from:
   - the MCP server's `instructions` and each tool's description, in `mcp/takes_mcp.py`;
   - the context the chat adds to each run, in `Sources/Takes/Chat.swift` and `ChatRefs.swift`;
   - the skills (see [Skills](#skills)).

   To change how those agents work, change one of these three. Put each fact in one place: a
   tool's own rule goes in its description, a rule for all of Takes goes in the server
   instructions, and a whole workflow (an edit, a storyboard) goes in a skill.

## The repo

| Path | What |
|---|---|
| `Sources/Takes/` | The Mac app: SwiftUI, AVFoundation, ScreenCaptureKit. A Swift package, no Xcode project. |
| `mcp/takes_mcp.py` | The `takes` MCP server: one Python file, standard library only. |
| `mcp/tests/` | The server's tests (`unittest`). |
| `Tests/TakesTests/` | The app's tests (Swift Testing). |
| `ios/` | The iPhone app (`TakesPhone`). It talks to the Mac over HTTP (`PhoneHTTP.swift`). |
| `assets/` | Icon, fonts, brand kit. |
| `build.sh`, `test.sh` | Build and test. |

Where things are in `Sources/Takes/`:

- **Window and layout:** `Views.swift` (sidebar, session, tabs), `Shell.swift` (the five session
  tabs), `Theme.swift` and `Look.swift` (colours, type, light and dark, palettes), `Settings.swift`.
- **Library on disk:** `Library.swift` (projects, sessions, `session.json`, `SESSION.md`),
  `Watch.swift` (file changes), `Scripts.swift` (variants, history), `Assets.swift`.
- **Recording:** `CameraRecorder.swift`, `ScreenRecorder.swift`, `AppModel.swift` (the record flow).
- **Storyboard:** `Storyboard.swift`.
- **Posts:** `Post.swift` (LinkedIn), `XPost.swift`, `VideoPost.swift` (YouTube, vertical),
  `Article.swift` and `ArticleView.swift` (blog), `PostDrafts.swift`, `Hooks.swift`,
  `PostQueue.swift` (the plan), `Publish.swift` (published posts and their numbers).
- **Review comments:** `Comments.swift`, `OpenComments.swift`.
- **Chat with Claude Code:** `Chat.swift`, `ChatAttach.swift`, `ChatRefs.swift`.
- **Sound and voice:** `Voice.swift`, `Sounds.swift`, `Broll.swift`.
- **Agents and updates:** `AgentSetup.swift` (sets up the MCP server and skills at launch),
  `Updater.swift` (the Update button), `Namer.swift` (session titles).
- **Private features** (`Features.socialBoards`): `Copilot.swift` and `CopilotView.swift` (LinkedIn
  comments), `Performance.swift`, `Social.swift`, `SocialWeek.swift`.
- **Private blog** (`Features.blog`, `BLOG` in `mcp/takes_mcp.py`): the Article side of the post tab
  (`Article.swift`, `ArticleView.swift`) and the server's `article` platform. The public copy turns both off.

The app and the server share one data format: the library folders in `~/Movies/Takes`. The
server's `instructions` describe that format. When you change the format, change both sides and
test both.

## The MCP server

An agent with the server connected gets the tool list and descriptions, so the tools need no
docs here. To add or change a tool:

1. Write a `t_<name>(a)` function in `mcp/takes_mcp.py`.
2. Add its entry to `TOOLS`: name, description, input schema, required fields, function.
3. Add a test in `mcp/tests/`. Each test sets `TAKES_ROOT` to a temp folder.
4. Try it by hand on a scratch library: `TAKES_ROOT=/tmp/lib python3 mcp/takes_mcp.py`.

Write descriptions for the agent that calls the tool: what it does, when to use it, and what to
call next.

## Skills

Takes ships two skills. The app copies them to `~/.claude/skills` at launch (`AgentSetup.swift`):

- `takes-storyboard`: an idea becomes a script and a sketch storyboard (`set_storyboard`).
- `takes-video-edit`: edit a take with ffmpeg and Whisper, write versions to `edits/`, answer
  review comments.

Their source is `skills/`. Update a skill when you change the tools or the
workflow it describes.

## How to work here

**Worktrees.** Put your worktree in your scratchpad or temp directory:
`git worktree add "$TMPDIR/takes-<task>" origin/main`. This keeps the user's coding folder clean.
When your work is merged or dropped, remove it (`git worktree remove <path>`) and delete its
branch (`git branch -d <branch>`). Remove a worktree you did not create only when it is clean,
no process runs in it, and its branch is merged into `origin/main`.

**Test.** `./test.sh` runs the server tests, then the app tests. Pass a filter to run fewer:
`./test.sh --filter Storyboard`. Tests that use the fake `claude` run one at a time in
`ChatRunTests`; put a new one in that suite.

**Look at UI changes.** Render the view and look at the picture before you say it works. The
`BrandSnapshot` and `ReadmeShots` tests show how.

**Ship.** Work goes to `main`:

1. Commit. The subject is `Area: what changed`, for example
   `Player: safe-zone button for vertical videos`.
2. `git fetch && git merge origin/main`, then `./test.sh`.
3. `git push origin HEAD:main`.
4. `./build.sh install`. It installs only what is on `origin/main`, and while Takes runs it
   stages the build. The user starts it with the Update button in the sidebar, when the chats are
   done. The iPhone works the same way: `ios/install.sh` stages, and the phone shows Update.

**Write.** Short, plain comments that say why, with the date for a decision
(`// Stays private for now (2026-10-04)`). The app calls its assistant "Takes", and errors from
the chat process say "the chat". Text in the app uses short sentences in the active voice.

