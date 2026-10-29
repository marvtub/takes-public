# The iPhone app: notes for agents

Read the root `AGENTS.md` first. This file adds what is true only in `ios/`.

## What it is

`TakesPhone/` is a SwiftUI app with no packages. It holds no library of its own: it talks to the
Mac over HTTPS on Tailscale (`API.swift`). The Mac side is `Sources/Takes/Phone.swift`,
`PhoneHTTP.swift` and the other `Phone*.swift` files. A change to a route changes both sides.

- **The phone copies the Mac.** Same look, same words, same order. Draw Takes's own controls
  (`Panel.swift` for menus and confirms), never stock iOS menus, alerts or cards.
- **Changes wait when the Mac is away.** `Outbox.swift` keeps them and sends them later.
- **Face ID guards the token** (`Vault.swift`).

## Build and project

- `project.yml` is the source. XcodeGen makes `TakesPhone.xcodeproj` from it. Change
  `project.yml`, not the project. The scripts run `xcodegen generate` for you.
- The scripts use full Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
- `install.sh` builds and stages: the phone shows Update, and the tap installs it. Use
  `install.sh --now` only when the user asks.
- A free Apple ID signs the app for 7 days. `refresh.sh` (an hourly LaunchAgent) renews it.

## Check it

`./test.sh` does not run the phone. Use these:

| Command | What it does |
|---|---|
| `ios/check.sh` | Builds the app and runs the whole UI suite in a hidden simulator, against `standin.py` on 8797 (started when none runs). Each test resets the stand-in. Screenshots go to `build.noindex/shots`. Never opens Simulator.app. |
| `ios/check.sh offline` | Starts `standin.py` (a fake Mac) and tests that changes wait, then go out. |
| `ios/check.sh chat` | Streaming, keyboard and reading position in the chat. |
| `ios/check.sh parity` | Walks the screens that copy the Mac (`ParityTests`). |
| `python3 ios/tests/test_chat_standin.py` | The stand-in's chat stream format. |

Logic with no UIKit gets a plain test in `ios/tests/` that `swiftc` builds and runs (see the
top of `ChatScrollStateTests.swift`). Look at the screenshots before you say a screen works.
