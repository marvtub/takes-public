import SwiftUI

// Hook options for the opening line, suggested by Claude (MCP `set_hooks`) and kept in
// <session>/hooks.json:  {"hooks": [{"id": "h1", "text": "...", "note": "..."}], "chosen": "h1"}
//
// The first paragraph of the script is the hook slot. Choosing a hook replaces that paragraph when
// it is one of the hooks, and otherwise puts the hook above it, so no text is ever lost.
// Each take records the hook it was read with (Take.hook).

struct Hook: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var note: String?
}

struct HooksFile: Codable {
    var hooks: [Hook] = []
    var chosen: String?
}

@MainActor
final class HookStore: ObservableObject {
    @Published private(set) var hooks: [Hook] = []
    private var url: URL?
    private var stamp: Date?
    /// The hooks file of a session: the script's, or the post's (posts/hooks.json).
    private let fileIn: @MainActor (URL) -> URL

    init(file: @escaping @MainActor (URL) -> URL = HookStore.file) { fileIn = file }

    static func file(_ session: URL) -> URL { session.appending(path: "hooks.json") }

    static func read(_ session: URL) -> HooksFile { read(file: file(session)) }

    static func read(file: URL) -> HooksFile {
        guard let data = try? Data(contentsOf: file),
              let f = try? JSONDecoder().decode(HooksFile.self, from: data) else { return HooksFile() }
        return f
    }

    /// Cheap: rereads only when the file changed.
    func load(_ session: URL) {
        let s = Store.modified(fileIn(session))
        guard session != url || s != stamp else { return }
        url = session
        stamp = s
        let fresh = Self.read(file: fileIn(session)).hooks
        if fresh != hooks { hooks = fresh }
    }

    /// Records the pick, so Claude sees which hook the user chose.
    func markChosen(_ hook: Hook, in session: URL) {
        let u = fileIn(session)
        var f = Self.read(file: u)
        f.chosen = hook.id
        if let data = try? JSONEncoder().encode(f) { try? data.write(to: u) }
        stamp = Store.modified(u)
    }

    func choose(_ hook: Hook, in doc: SessionDoc) {
        doc.snapshotDirty()
        doc.activeText = Self.apply(hook.text, to: doc.activeText, known: hooks.map(\.text))
        var f = Self.read(doc.url)
        f.chosen = hook.id
        if let data = try? JSONEncoder().encode(f) { try? data.write(to: Self.file(doc.url)) }
        stamp = Store.modified(Self.file(doc.url))
    }

    // MARK: Hook slot

    static func firstParagraph(_ script: String) -> String {
        let t = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = t.range(of: "\n\n")?.lowerBound ?? t.endIndex
        return String(t[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func apply(_ hook: String, to script: String, known: [String]) -> String {
        let hook = hook.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return hook + "\n" }
        let first = firstParagraph(t)
        let isHook = known.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == first }
        guard isHook else { return hook + "\n\n" + t + "\n" }
        let rest = t.range(of: "\n\n").map { String(t[$0.upperBound...]) } ?? ""
        return rest.isEmpty ? hook + "\n" : hook + "\n\n" + rest + "\n"
    }

    /// The hook that sits in the script's hook slot now, if any.
    static func current(_ script: String, _ hooks: [Hook]) -> Hook? {
        let first = firstParagraph(script)
        return hooks.first { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == first }
    }
}

/// Hook options above the teleprompter. Dark, like the prompter.
struct HookPicker: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    @StateObject private var store = HookStore()
    @AppStorage("hooksCollapsed") private var collapsed = false

    var body: some View {
        // A VStack, not a Group: with no hooks a Group is empty, and an empty Group never appears,
        // so onAppear and the file watch below never ran and new hooks stayed hidden (2026-10-01).
        VStack(spacing: 0) {
            if !store.hooks.isEmpty && !app.isRecording {
                let current = HookStore.current(doc.activeText, store.hooks)
                VStack(alignment: .leading, spacing: 0) {
                    header(current)
                    if !collapsed {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(Array(store.hooks.enumerated()), id: \.element.id) { i, h in
                                    row(i + 1, h, selected: current?.id == h.id)
                                }
                            }
                            .padding(.horizontal, 10).padding(.bottom, 10)
                        }
                        .frame(maxHeight: 170)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .background(Theme.canvas)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .onAppear { store.load(doc.url) }
        .onChange(of: doc.url) { store.load(doc.url) }
        .onFilesChanged(in: doc.url) { store.load(doc.url) }
    }

    private func header(_ current: Hook?) -> some View {
        Button { withAnimation(Theme.motion) { collapsed.toggle() } } label: {
            HStack(spacing: 8) {
                Text("HOOKS").font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.accent)
                if collapsed, let current, let n = store.hooks.firstIndex(of: current) {
                    Text("\(n + 1) of \(store.hooks.count) in script")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                    Text(current.text).font(Theme.sans(12)).foregroundStyle(Theme.faint).lineLimit(1)
                } else {
                    Text("\(store.hooks.count) options · pick one")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the hook options" : "Hide the hook options")
    }

    private func row(_ n: Int, _ h: Hook, selected: Bool) -> some View {
        HookRow(n: n, hook: h, selected: selected) {
            withAnimation(Theme.motion) { store.choose(h, in: doc) }
        }
    }
}

private struct HookRow: View {
    let n: Int
    let hook: Hook
    let selected: Bool
    let use: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", n)).font(Theme.mono(11, .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.faint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(hook.text).font(Theme.sans(13.5, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = hook.note, !note.isEmpty {
                    Text(note).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Label("in script", systemImage: "checkmark")
                    .font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            } else {
                Text(hover ? "[ use ]" : "use").font(Theme.mono(10.5, .medium))
                    .foregroundStyle(hover ? Theme.ink : Theme.faint)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.radius)
            .fill(selected ? Theme.paper : hover ? Theme.hover : .clear))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 2).padding(.vertical, 6) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if !selected { use() } }
        .help(selected ? "This hook opens the script now" : "Put this hook at the top of the script")
    }
}
