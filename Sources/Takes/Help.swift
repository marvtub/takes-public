import AppKit
import SwiftUI

// The Help menu (2026-10-22): "Takes Help" said help isn't available. Now it opens this window, a
// short guide to the five tabs, and ⌘/ opens it on the keyboard shortcuts. The tour, welcome and
// demo items moved up beside it, with Ask Takes and Send Feedback.

@MainActor @Observable final class HelpCenter {
    static let shared = HelpCenter()
    enum Page: String, CaseIterable { case guide = "Guide", shortcuts = "Shortcuts" }
    var page: Page = .guide

    static let releases = URL(string: "https://github.com/marvtub/takes-public/releases")!
    static let newIssue = URL(string: "https://github.com/marvtub/takes-public/issues/new")!

    struct Shortcut: Hashable { let name: String; let keys: String }
    struct ShortcutGroup: Hashable { let title: String; let items: [Shortcut] }

    /// The tabs come from `SessionMode`, so a moved shortcut moves here too. The rest copy the
    /// menus in `Views.swift`: change both.
    static var groups: [ShortcutGroup] {
        let tabs = [SessionMode.storyboard, .write, .record, .assets, .sounds, .broll, .post]
        return [
            ShortcutGroup(title: "Session", items: tabs.map { Shortcut(name: $0.title, keys: "⌘\($0.shortcut)") }),
            ShortcutGroup(title: "Recording", items: [
                Shortcut(name: "Start / stop a take", keys: "⌘R"),
                Shortcut(name: "Play the script", keys: "⌘P"),
                Shortcut(name: "Script to the top", keys: "⌘↑"),
                Shortcut(name: "Script in the notch", keys: "⌥⌘N"),
                Shortcut(name: "Bigger script", keys: "⌥⌘="),
                Shortcut(name: "Smaller script", keys: "⌥⌘-"),
            ]),
            ShortcutGroup(title: "Anywhere", items: [
                Shortcut(name: "New session", keys: "⌘N"),
                Shortcut(name: "Search", keys: "⌘K"),
                Shortcut(name: "Chat with Takes", keys: "⇧⌘L"),
                Shortcut(name: "Sidebar", keys: "⌘B"),
                Shortcut(name: "Styles", keys: "⇧⌘Y"),
                Shortcut(name: "Plugins", keys: "⇧⌘P"),
                Shortcut(name: "Bigger text", keys: "⌘="),
                Shortcut(name: "Smaller text", keys: "⌘-"),
                Shortcut(name: "Settings", keys: "⌘,"),
                Shortcut(name: "Help", keys: "⌘?"),
            ]),
        ]
    }

    /// The five steps of the guide: the header's tabs, in order.
    static let steps: [(mode: SessionMode, text: String)] = [
        (.storyboard, "Sketch the idea as shots on a timeline. Takes draws the sketches."),
        (.write, "Write what you say, with Takes beside you. Pick a hook from the options."),
        (.record, "Camera, mic and a prompter that follows your voice. Or put the script in the notch."),
        (.assets, "Your takes, edits, b-roll and sound. Comment on a frame and Takes fixes it."),
        (.post, "See the post as it looks in the feed, for LinkedIn, X, YouTube or vertical video."),
    ]
}

/// A Help menu item that opens the window on one page.
struct HelpButton: View {
    let title: String
    let page: HelpCenter.Page
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(title) { HelpCenter.shared.page = page; openWindow(id: "help") }
    }
}

struct HelpView: View {
    @Environment(AppModel.self) var app
    @Environment(\.dismissWindow) private var dismissWindow
    var center = HelpCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Takes Help").font(Theme.display(26))
                Spacer()
                TakesSwitch(selection: Binding(get: { center.page }, set: { center.page = $0 }),
                            options: HelpCenter.Page.allCases.map { ($0, $0.rawValue) })
                    .fixedSize()
            }
            .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 18)
            Rule()
            Group {
                switch center.page {
                case .guide: HelpGuide(go: go)
                case .shortcuts: HelpShortcuts()
                }
            }
            .id(center.page)
            .transition(.opacity)
        }
        .frame(width: 600)
        .background(Theme.paper)
        .animation(Theme.motion, value: center.page)
    }

    /// "Open" on a step: the main window goes to that tab, this one closes.
    private func go(_ m: SessionMode) {
        SessionMode.set(m)
        dismissWindow(id: "help")
    }
}

struct HelpGuide: View {
    var go: (SessionMode) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Write it, record it, post it.").font(Theme.display(21))
                Text("Each video is a session. A session goes through five tabs, left to right. You can skip any of them.")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .arrive(0)
            VStack(spacing: 2) {
                ForEach(Array(HelpCenter.steps.enumerated()), id: \.offset) { i, s in
                    HelpStep(number: i + 1, mode: s.mode, text: s.text, go: go)
                }
            }
            .arrive(1)
            Text("Stuck? Ask Takes in the chat (⇧⌘L). It can do the step for you.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                .arrive(2)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
    }
}

private struct HelpStep: View {
    let number: Int
    let mode: SessionMode
    let text: String
    let go: (SessionMode) -> Void
    @State private var hover = false

    var body: some View {
        Button { go(mode) } label: {
            HStack(alignment: .top, spacing: 14) {
                Text("\(number)").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.accentInk)
                    .frame(width: 26, height: 26).background(Circle().fill(Theme.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title).font(Theme.sans(14, .semibold))
                    Text(text).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                KeyCap(keys: "⌘\(mode.shortcut)")
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .help("Go to \(mode.title)")
    }
}

struct HelpShortcuts: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(HelpCenter.groups.enumerated()), id: \.offset) { i, g in
                VStack(alignment: .leading, spacing: 8) {
                    Text(g.title.uppercased()).font(Theme.sans(11, .semibold)).kerning(0.6).foregroundStyle(Theme.muted)
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 7) {
                        ForEach(0..<(g.items.count + 1) / 2, id: \.self) { row in
                            GridRow {
                                cell(g.items[row * 2])
                                if row * 2 + 1 < g.items.count { cell(g.items[row * 2 + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                            }
                        }
                    }
                }
                .arrive(i)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
    }

    private func cell(_ s: HelpCenter.Shortcut) -> some View {
        HStack {
            Text(s.name).font(Theme.sans(13))
            Spacer(minLength: 10)
            KeyCap(keys: s.keys)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A shortcut as a small key on a soft well.
struct KeyCap: View {
    let keys: String
    var body: some View {
        Text(keys).font(Theme.sans(12, .medium)).monospacedDigit().foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hover))
    }
}

@MainActor extension AppModel {
    /// ⇧⌘L. On Record the chat takes the script's column, and goes again.
    func toggleChat() {
        if chats.docked, UserDefaults.standard.string(forKey: "rightTab") == SessionMode.record.rawValue, board == nil {
            if chats.onRecord && chats.open { chats.onRecord = false }
            else { chats.onRecord = true; chats.open = true }
        } else { chats.open.toggle() }
    }

    /// Help › Ask Takes: open the chat, never close it.
    func openChat() {
        if chats.docked, UserDefaults.standard.string(forKey: "rightTab") == SessionMode.record.rawValue, board == nil {
            chats.onRecord = true
        }
        chats.open = true
    }
}

@MainActor extension NotchPanel {
    /// Help › Take the Quick Tour: the notch opens on the tour's first step.
    func tour(_ app: AppModel) {
        let d = UserDefaults.standard
        d.set(0, forKey: NotchView.introKey)
        d.set(true, forKey: Self.armedKey)
        d.set(true, forKey: Self.autoKey)
        if !shown { show(app) }
    }
}
