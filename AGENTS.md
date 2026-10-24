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
| `mcp/clean_voice.py`, `mcp/prepare_take.py` | Clean voice and word times for a take. They need packages, so they run through `uv`. |
| `<session>/_work/` | Clips from `cut_take` and `rough_cut` (working files, hidden on the Assets tab). |
| `<session>/_edit/` | An edit's sources (`_edit/<name>/`) and `render_edit`'s renders (`_edit/renders/`), hidden on the Assets tab. Each version's recipe sits beside it: `edits/<name>-vN.recipe.json` (`EditRecipe.swift`). |
| `mcp/tests/` | The server's tests (`unittest`). |
| `Tests/TakesTests/` | The app's tests (Swift Testing). |
| `ios/` | The iPhone app (`TakesPhone`). It talks to the Mac over HTTP (`PhoneHTTP.swift`). |
| `assets/` | Icon, fonts, brand kit. |
| `build.sh`, `test.sh` | Build and test. |

Two folders have their own `AGENTS.md`: `ios/AGENTS.md` (the iPhone app) and `mcp/AGENTS.md`
(the server). Read it before you change that folder.

Where things are in `Sources/Takes/`. This is a map of areas, not a list of every file: find the
rest with `grep`. Most files start with a comment that says what they are for.

| Area | Start here |
|---|---|
| Window, sidebar, tabs | `Shell.swift`, `Views.swift` |
| Look: colours, type, controls | `Theme.swift`, `Look.swift`, `MenuKit.swift` (menus, panels, switch, confirm), `Settings.swift` |
| Motion | `PageMotion.swift` (pages arrive), `Motion.swift` (endless animations) |
| Library on disk | `Library.swift`, `Watch.swift`, `Scripts.swift`, `Assets.swift`, `StyleLibrary.swift` |
| Recording | `AppModel.swift`, `CameraRecorder.swift`, `ScreenRecorder.swift`, `Notch.swift` (the script in the notch), `ScriptFollower.swift` |
| Transcripts and search | `Transcripts.swift`, `Search.swift` (⌘K), `ScreenFind.swift` (⌘F) |
| Storyboard | `Storyboard.swift` |
| Posts | `Post.swift` (LinkedIn), `XPost.swift`, `VideoPost.swift` (YouTube, vertical), `PostDrafts.swift`, `Hooks.swift`, `PostQueue.swift`, `Publish.swift`, `Cover.swift` |
| Review comments | `Comments.swift`, `OpenComments.swift` |
| Chat | `Chat.swift` (one Claude Code, Codex or pi run per turn; `Agents/ChatAdapters.swift` per agent), `ChatAgents.swift` (agent and model pick, Settings › Agents), `ChatAttach.swift`, `ChatRefs.swift`, `Dictation.swift` |
| Long jobs (renders the chat starts with `run_job`) | `Jobs.swift` (the Jobs row, and the note to the chat when a job ends) |
| Sound and voice | `Voice.swift`, `Sounds.swift`, `Broll.swift` |
| Image, video and voice models | `Gemini.swift`, `Higgsfield.swift`, `Replicate.swift`, `ElevenLabs.swift`, `ModelBrowser.swift` |
| Plugins | `Plugins/Plugins.swift` (the board and the hooks), `Plugins/Feedback.swift` (rules, comments per video) |
| The iPhone's server | `Phone.swift`, `PhoneHTTP.swift`, and the `Phone*.swift` files beside them |
| Agents and updates | `AgentSetup.swift` (MCP server and skills at launch), `Updater.swift` (`InstallRef.swift`: the install code of a download with a source), `Namer.swift` |
| First run | `Onboarding.swift`, `FirstTake.swift`, `Setup.swift` |
| Speed | `Perf.swift` |
| Private features (`Features.socialBoards`) | `Copilot.swift`, `CopilotView.swift` (LinkedIn comments), `Performance.swift`, `Social.swift`, `SocialWeek.swift` |
| Private blog (`Features.blog`, `BLOG` in the server) | `Article.swift`, `ArticleView.swift`. The public copy turns both off. |

The app and the server share one data format: the library folders in `~/Movies/Takes`. The
server's `instructions` describe that format. When you change the format, change both sides and
test both.

## The MCP server

An agent with the server connected gets the tool list and descriptions, so the tools need no
docs here. To add or change a tool, read `mcp/AGENTS.md`.

## Skills

Takes ships three skills. The app copies them to `~/.claude/skills` and `~/.agents/skills` at
launch, each with a `.takes-skill` marker (`AgentSetup.swift`):

- `takes-storyboard`: an idea becomes a script and a sketch storyboard (`set_storyboard`).
- `takes-video-edit`: edit a take (cuts, recipes, HyperFrames layers), write versions to `edits/`,
  answer review comments.
- `takes-image-prompt`: prompts for `make_image`, from a collection it downloads at run time.

Their source is `skills/`. Update a skill when you change the tools or the
workflow it describes.

Takes also downloads the **HyperFrames** skills (HeyGen, Apache-2.0, `SkillPack.hyperframes` in
`Plugins/Skills.swift`) from their GitHub repo at first launch, never bundled. The Skills plugin
(Plugins › Skills, public since 2026-10-13) switches each skill and pack on or off
(`skillsOff` in UserDefaults: launch skips those), updates the pack, and adds any skill from a
GitHub link or a folder. Takes updates and removes only skills with its marker.

## How to work here

**Worktrees.** Put your worktree in your scratchpad or temp directory:
`git worktree add "$TMPDIR/takes-<task>" origin/main`. This keeps the user's coding folder clean.
When your work is merged or dropped, remove it (`git worktree remove <path>`) and delete its
branch (`git branch -d <branch>`). Remove a worktree you did not create only when it is clean,
no process runs in it, and its branch is merged into `origin/main`.

**Scratch libraries.** A test library or a build copy you make to try something (a copy of a
session, of the whole library, or of the app) is yours to remove when you are done. Copy video
with `cp -c`: an APFS clone takes no space until one side changes. On 2026-10-11 such leftovers
held 65 GB of the user's disk.

**Board actions show in the chat (2026-10-19).** Every button, toggle, refresh or background
run on a board with a chat writes a line in that chat with `ClaudeChat.action`: what started (a
spinner with `running: true`), then what came of it (the same id with `update:`), or why it did
not work (`failed: true`). Pass `agent:` with the full result (the ideas, the numbers, the
answers), so the agent can talk about it: it gets every action in front of the user's next
message, without a reply now. A board action that runs an agent out of sight of the chat, or
changes what the board shows without a line, is a bug. Site stats does it through `SiteActivity`.

**Agents.** Takes must work with Claude Code, Codex or pi, whichever the user has. A feature
that asks an agent goes through `Agents.run(AgentRequest(...))` in `Sources/Takes/Agents/`; never
start `claude`, `codex` or `pi` yourself. A new need (a tool, an output shape) goes in
`AgentRequest` and in each adapter. The chat runs through a `ChatAdapter` per agent
(`Agents/ChatAdapters.swift`: its arguments, and how its output lines become messages); `Chat.swift`
never asks which agent it runs. `AgentsTests` fails when a file outside `Agents/` names a CLI or
builds its arguments. Admin-only tools (Comments, Site AI) may stay on Claude Code. Finish setup
(`Setup.swift`) and `install.sh` are done when any one agent is signed in (`Agents/SignIn.swift`);
they install Claude Code only on a Mac with none.

**Test.** Read [Tests](#tests). Run `./test.sh` before every push.

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
   Never quit, restart or swap `Takes.app` yourself, and never leave a script that does it
   later, not even when the user is away: you run inside Takes, so the quit stops you and every
   other chat with it (2026-10-10: a script like that cut off two chats, then died with Takes,
   and Takes stayed shut for five hours).

**Motion and controls.** Every page arrives the same way, so a new page must not do its own
thing (2026-10-09). Boards come in through `.transition(.page)`, set once where the boards switch
in `Views.swift`. A page's parts arrive in order with `.arrive(0)`, `.arrive(1)`… No spinner
while a page reads its data: draw nothing, then let the parts arrive. The helpers are in
`PageMotion.swift`. Draw controls and charts in Takes's own style (`Theme`, `AccentButtonStyle`,
`ToggleChip`, the Feedback board's `RuleSwitch`), not stock macOS pickers, switches,
bordered text fields or Swift Charts defaults.

**Menus and panels.** Every menu is the Takes menu kit in `MenuKit.swift` (2026-10-11, design:
https://claude.ai/artifact/YUNwytSXFvdBuM2JuUF4BZ). Use `TakesMenuButton` for a click menu,
`.takesContextMenu` for right-click, `.takesPopover` for a panel, `TakesSwitch` for two to four
choices and `TakesConfirm` in a `.sheet` for a question. Never `Menu`, `.contextMenu`, `.popover`,
a segmented or pop-up `Picker`, `.alert` or `NSAlert`. Rows: a group opens in place (`MenuGroup`);
a red danger row goes last, after a divider; the picked row has a check. The same thing in two
menus (a ⋯ menu and its right-click menu) uses one row builder, so both keep one order. Stays
native: the menu bar, right-click inside text, date pickers and folder pickers.

**Write.** Short, plain comments that say why, with the date for a decision
(`// Stays private for now (2026-10-04)`). The app calls its assistant "Takes", and errors from
the chat process say "the chat". Text in the app uses short sentences in the active voice.

## Tests

`./test.sh` runs the server tests (`mcp/tests/`, `unittest`), then the app tests
(`Tests/TakesTests/`, Swift Testing). `./test.sh --filter Storyboard` runs fewer. When a test
cannot find `Testing`, set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The iPhone
has its own checks: read `ios/AGENTS.md`.

**What needs a test**

- **A bug fix:** first a test that fails the way the bug did, then the fix. Name the test for
  what must stay true (`brokenFileIsNeverEmptied`), not for the bug.
- **A change to the files on disk:** test the side you changed. When the app and the server both
  read or write that file, test both.
- **A new MCP tool, or a new rule in a tool:** a test in `mcp/tests/` (read `mcp/AGENTS.md`).
- **Code that decides:** make the decision a plain function and test that function, as
  `Keys.swift` does for shortcuts. Do not test a decision through a view.
- **A new screen or a changed look:** render it and look at the picture (`BrandSnapshotTests`,
  `ReadmeShots`). A test that only builds the view proves nothing about how it looks.

**How tests behave**

- **Own temp folder.** Each test makes its own folder under `temporaryDirectory`, with a
  `UUID()` in the name, and removes it. Never read or write `~/Movies/Takes` or the user's files.
- **No network, no keys.** Replace the HTTP call with a fake (the server's tests swap functions
  such as `t.eleven_http`). Use `x.test` for made-up URLs. A test must pass on a new Mac with no
  keys and no internet.
- **No real `claude`.** Chat tests use the fake `claude` in `ChatTests.swift`. Tests that start it
  run one at a time in `ChatRunTests` (`@Suite(.serialized)`): put a new one there.
- **Wait for a state, not for a time.** Use `await until(seconds) { condition }`, not `sleep`.
  Give it room: a full run starts about 250 tests at once, so a step that takes 1 s alone can take
  20 s there.
- **A flaky test is a bug.** Find why it fails under load and fix that. Do not run it again until
  it passes. A test that times real playback or streaming goes in `TIMED` in `test.sh`: those run
  alone after the rest.
- **Cheap on CPU.** Builds and the parallel tests run at utility priority (`LOW` in
  `scripts/test-queue.sh`), so the user's apps come first. Each phase prints `Took N s, CPU N s`.
  Compare CPU, not times: on a busy Mac a run mostly waits. `python3 mcp/tests/run_parallel.py
  --cpu` lists the test classes that use the most. Make a test video small and short, and a
  frame grab that runs in a thread pool uses `ONE_THREAD`.
- **The docs are tested.** `AgentDocsTests` fails when an `AGENTS.md` names a file that is not in
  the repo. When you rename or delete a file, fix the docs in the same commit.

