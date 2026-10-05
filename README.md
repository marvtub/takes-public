<p align="center"><img src="docs/banner.webp" alt="Takes: record takes, Claude Code does the rest" width="100%"></p>

<p align="center">
  A Mac app for recording video takes and turning them into posts,<br>
  with <a href="https://claude.com/claude-code">Claude Code</a> working beside you.
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-0b1530">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-3b82f6">
  <img alt="MCP" src="https://img.shields.io/badge/Claude%20Code-MCP%20server-d97757">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-22c55e">
</p>

<p align="center"><img src="docs/tour.webp" alt="Storyboard, record and post in Takes" width="100%"></p>

You write a script, record takes (camera, or camera and screen at once) and star the keeper. Claude Code reads the same files: it storyboards the video, cuts the edit, and drafts the posts for LinkedIn, X, YouTube and vertical video. Takes shows each post the way the platform will show it, so you review the real thing, not a text box.

> **Shared as is.** This is a personal tool, made public so you can read it, fork it and make it yours. It does not take pull requests (a bot closes them) and it has no support, but [Discussions](https://github.com/marvtub/takes-public/discussions) are open.

## Getting started

Paste this in Terminal:

```sh
curl -fsSL https://gettakes.app/install | bash
```

It installs Takes, ffmpeg and [Claude Code](https://claude.com/claude-code) (if you don't have them), signs you in to Claude and opens Takes. Run it again to update. Then allow the camera and mic, and press ⌘R.

<details>
<summary>Other ways to install</summary>

- **Download:** get `Takes.dmg` from [Releases](https://github.com/marvtub/takes-public/releases/latest) and drag Takes to Applications. Apple has not notarized Takes, so the first open is blocked: open System Settings > Privacy & Security and click **Open Anyway**. Then click **Finish setup** in the sidebar: it installs Claude Code and ffmpeg for you.
- **From source:** clone this repo, `brew install ffmpeg`, then `./build.sh install`.

</details>

On its first launch Takes connects itself to Claude Code: it adds the `takes` MCP server and two skills, `takes-storyboard` and `takes-video-edit`. Then ask Claude Code, in the Takes chat or any terminal: *"storyboard my next Takes video"* or *"cut my last take"*.

## What it does

**Storyboard → Record → Post.** One session holds one video, from the first idea to the posts.

| | |
|---|---|
| <img src="docs/storyboard.webp" alt="Storyboard tab"> | **Storyboard.** Claude writes the script and sketches every shot. A filmstrip runs along the top; each shot shows its line, how to film it and a Record button. |
| <img src="docs/record.webp" alt="Record tab"> | **Record.** A teleprompter beside the camera, hook options to pick from, script variants and history, and every take with its keeper star. Camera and screen record as two files, synced. |
| <img src="docs/post-linkedin.webp" alt="Post tab"> | **Post.** One draft per platform, each shown as that platform shows it, with variants, opening hooks, history, comments for Claude and a schedule. |

**Every platform, previewed as it will look.**

<p align="center"><img src="docs/posts.webp" alt="LinkedIn, X, YouTube and vertical previews" width="100%"></p>

<details>
<summary>All the screens</summary>

| LinkedIn | X thread |
|---|---|
| <img src="docs/post-linkedin.webp"> | <img src="docs/post-x.webp"> |
| **YouTube** | **TikTok, Reels and Shorts** |
| <img src="docs/post-youtube.webp"> | <img src="docs/post-vertical.webp"> |
| **Light mode** | |
| <img src="docs/record-light.webp"> | |

</details>

The pictures are the real app, rendered from a made-up library.

## How it works

Your library is plain folders in `~/Movies/Takes`. The app records into them. Claude Code reads and writes them through the `takes` MCP server, which `./build.sh install` sets up. When a file changes, the app updates.

```mermaid
flowchart LR
    app["<b>Takes.app</b><br/>record · review"]
    lib[("<b>~/Movies/Takes</b><br/>scripts · takes · posts")]
    claude["<b>Claude Code</b><br/>chat panel or your terminal"]
    app <--> lib
    claude -- "takes MCP" --> lib
    app -- "starts" --> claude
```

## Good to know

- **Needs:** a Mac with Apple silicon, macOS 15+, a Claude plan. The install script gets the rest. Building from source also needs the Swift toolchain (Xcode or the Command Line Tools).
- **Optional:** `whisper` for transcripts, a `GEMINI_API_KEY` for storyboard sketches, the iPhone app (`TAKES_TEAM=<team id> ios/install.sh`).
- **Questions and ideas:** [Discussions](https://github.com/marvtub/takes-public/discussions). Pull requests are closed by a bot; fork it and make it yours.
- **Tests:** `./test.sh`.

## Support

Takes is free. If it saves you time, you can buy me a coffee:

<p>
  <a href="https://paypal.me/webtotheflow"><img alt="Donate with PayPal" src="https://img.shields.io/badge/PayPal-Buy%20me%20a%20coffee-003087?style=for-the-badge&logo=paypal&logoColor=white"></a>
  <a href="https://venmo.com/u/MarvinAziz"><img alt="Donate with Venmo" src="https://img.shields.io/badge/Venmo-Buy%20me%20a%20coffee-008CFF?style=for-the-badge&logo=venmo&logoColor=white"></a>
</p>
