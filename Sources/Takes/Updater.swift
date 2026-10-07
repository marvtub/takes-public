import AppKit
import Foundation
import Observation
import SwiftUI

/// Agents never restart Takes (2026-10-03). `./build.sh install` stages a new build in
/// `~/Applications/.update.noindex/Takes.app` while Takes runs; this notices it, the sidebar shows
/// Update, and only the user's click swaps it in: once nothing records or runs (a Claude reply, an
/// export), Takes quits, the new build replaces the old one, and it opens again. `.noindex`
/// keeps Spotlight, and so macOS, from opening the staged copy.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// The waiting build: when it was made, and the commits it adds, newest first.
    struct Staged: Equatable { var stamp: String; var changes: [String]; var log: [Change] = [] }

    /// One commit in the What's new panel. "Chat: @comments shows as a chip; …" gives the area
    /// "Chat", the headline before the first ";", and the rest plus the message body as detail.
    struct Change: Equatable, Identifiable {
        var id: String
        var area: String
        var headline: String
        var detail: String
        var date: Date?

        nonisolated static func parse(subject: String, body: String = "", id: String = UUID().uuidString, date: Date? = nil) -> Change {
            var area = "", rest = Substring(subject)
            // An area is a short label before ": ", like "Post tab" or "iPhone Videos home".
            if let r = subject.range(of: ": "), subject[..<r.lowerBound].count <= 24 {
                area = String(subject[..<r.lowerBound])
                rest = subject[r.upperBound...]
            }
            var headline = String(rest), more = ""
            if let r = rest.range(of: "; ") {
                headline = String(rest[..<r.lowerBound])
                more = String(rest[r.upperBound...])
            }
            if let first = headline.first { headline = first.uppercased() + headline.dropFirst() }
            if let first = more.first { more = first.uppercased() + more.dropFirst() + (more.hasSuffix(".") ? "" : ".") }
            let detail = [more, body.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return Change(id: id, area: area.isEmpty ? "Takes" : area, headline: headline, detail: detail, date: date)
        }

        /// changes.json from build.sh; [] when the build has none (older builds).
        nonisolated static func load(_ data: Data?) -> [Change] {
            struct Raw: Decodable { var hash: String; var date: String; var subject: String; var body: String }
            guard let data, let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
            let iso = ISO8601DateFormatter()
            return raw.map { parse(subject: $0.subject, body: $0.body, id: $0.hash, date: iso.date(from: $0.date)) }
        }
    }
    private(set) var staged: Staged?
    /// Clicked: waits for the recording or the work to end, then restarts.
    private(set) var applying = false
    private(set) var waitingFor: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastRead: Date?

    private var running: URL { Bundle.main.bundleURL }
    private var waiting: URL {
        running.deletingLastPathComponent().appendingPathComponent(".update.noindex")
            .appendingPathComponent(running.lastPathComponent)
    }

    private init() {}

    func start() {
        guard timer == nil, running.pathExtension == "app" else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check() }
        }
    }

    /// Reads the staged Info.plist again only when it changed. A plist is read directly, not
    /// through Bundle, which caches it per path.
    func check() {
        let plist = waiting.appendingPathComponent("Contents/Info.plist")
        let changed = (try? FileManager.default.attributesOfItem(atPath: plist.path))?[.modificationDate] as? Date
        if changed != nil, changed == lastRead { return }
        lastRead = changed
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let stamp = info["BuildStamp"] as? String,
              stamp != Bundle.main.infoDictionary?["BuildStamp"] as? String else {
            if staged != nil { staged = nil }
            return
        }
        let changes = (info["BuildChanges"] as? String ?? "").split(separator: "\n").map(String.init)
        let json = try? Data(contentsOf: waiting.appendingPathComponent("Contents/Resources/changes.json"))
        var log = Change.load(json)
        if log.isEmpty { log = changes.map { Change.parse(subject: $0) } }
        let next = Staged(stamp: stamp, changes: changes, log: log)
        if staged != next { staged = next }
    }

    /// What quitting now would cut off, if anything.
    private func busy(recording: () -> Bool) -> String? {
        if recording() { return "the recording" }
        // Claude replies, exports and voice cleanup run as child processes. The ⌘K search helper
        // runs all the time and only holds an index it saves as it goes, so it does not count.
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(getpid())"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let helper = MediaSearch.shared.helperPID
        let kids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        return kids.contains { $0 != helper } ? "a chat reply or an export" : nil
    }

    /// Waits until nothing records or runs, then a small shell swaps the bundles after this
    /// process is gone and opens Takes again. If the swap fails it opens the old build.
    func apply(recording: @escaping () -> Bool) {
        guard staged != nil, !applying else { return }
        applying = true
        Task { @MainActor in
            while let what = busy(recording: recording) {
                waitingFor = what
                try? await Task.sleep(for: .seconds(2))
            }
            waitingFor = nil
            MediaSearch.shared.stopHelper()   // it saves its index and quits
            let old = waiting.deletingLastPathComponent().appendingPathComponent("previous.app")
            let script = """
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            rm -rf "$2"
            if mv "$0" "$2"; then
              if mv "$1" "$0"; then rm -rf "$2"; else mv "$2" "$0"; fi
            fi
            /usr/bin/open "$0"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, running.path, waiting.path, old.path]
            do { try p.run() } catch { applying = false; return }
            NSApp.terminate(nil)
        }
    }
}

/// "Update" beside the name at the top of the sidebar, only while a new build waits. Two click
/// areas (2026-10-04): "Update Takes" updates now; "N changes ›" opens What's new.
struct UpdateButton: View {
    var library: Library
    private var updater = Updater.shared
    @State private var open = false
    @State private var hover: Side?
    private enum Side { case update, changes }

    init(library: Library) { self.library = library }

    private func apply() { updater.apply { [library] in library.isRecording } }

    var body: some View {
        if let staged = updater.staged {
            HStack(spacing: 0) {
                Button(action: apply) {
                    HStack(spacing: 9) {
                        Group {
                            if updater.applying {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                        }
                        .frame(width: 16)
                        Text(updater.applying ? "Updating…" : "Update Takes").font(Theme.sans(13, .semibold))
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(hover == .update ? Theme.accent.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(updater.applying)
                .onHover { hover = $0 ? .update : (hover == .update ? nil : hover) }
                .help(updater.waitingFor.map { "Restarts once \($0) is done." } ?? "Update now: Takes restarts on the new build")
                Rectangle().fill(Theme.accentInk.opacity(0.18)).frame(width: 0.5, height: 18)
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        if !staged.log.isEmpty {
                            Text(staged.log.count == 1 ? "1 change" : "\(staged.log.count) changes")
                                .font(Theme.sans(11, .medium)).opacity(0.8).lineLimit(1)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
                    }
                    .padding(.leading, 9).padding(.trailing, 10).padding(.vertical, 7)
                    .frame(maxHeight: .infinity)
                    .background(hover == .changes || open ? Theme.accent.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? .changes : (hover == .changes ? nil : hover) }
                .help("See what's new")
                .popover(isPresented: $open, arrowEdge: .trailing) {
                    WhatsNew(staged: staged, updater: updater, update: apply)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Theme.accentInk)
            .background(Theme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .animation(Theme.motion, value: hover)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

/// The waiting build's changes, grouped by area, each one opens to its full message. The Update
/// tooltip only listed eight commit titles (2026-10-04). The list is as tall as its changes, up
/// to 560 points: a ScrollView alone in a popover shrank to one row and hid the rest (2026-10-04).
/// With up to six changes, every one starts open.
struct WhatsNew: View {
    let staged: Updater.Staged
    let updater: Updater
    let update: () -> Void
    @State private var expanded: Set<String>
    @State private var listHeight: CGFloat = 0

    init(staged: Updater.Staged, updater: Updater, expanded: Set<String>? = nil, update: @escaping () -> Void) {
        self.staged = staged; self.updater = updater; self.update = update
        _expanded = State(initialValue: expanded ?? (staged.log.count <= 6 ? Set(staged.log.map(\.id)) : []))
    }

    /// Areas in order of their newest change; "Notice" and "Notices" are one area.
    private var groups: [(area: String, changes: [Updater.Change])] {
        var order: [(key: String, area: String)] = [], byKey: [String: [Updater.Change]] = [:]
        for c in staged.log {
            var key = c.area.lowercased()
            if key.hasSuffix("s") { key.removeLast() }
            if byKey[key] == nil { order.append((key, c.area)) }
            byKey[key, default: []].append(c)
        }
        return order.map { ($0.area, byKey[$0.key]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What's new").font(Theme.display(17))
                Text("\(staged.log.count == 1 ? "1 change" : "\(staged.log.count) changes") in the build from \(staged.stamp.split(separator: " ").dropFirst().joined(separator: " "))")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.area) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.area.uppercased()).font(Theme.sans(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
                                .padding(.horizontal, 8)
                            ForEach(g.changes) { c in row(c) }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 60), 560))
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                Text(updater.waitingFor.map { "Waits until \($0) is done." } ?? "Takes restarts on the new build.")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(2)
                Spacer(minLength: 8)
                Button(action: update) {
                    HStack(spacing: 6) {
                        if updater.applying { ProgressView().controlSize(.mini) }
                        Text(updater.applying ? "Updating…" : "Update now").font(Theme.sans(12.5, .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(updater.applying)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 440)
        .background(Theme.paper)
    }

    private func row(_ c: Updater.Change) -> some View {
        let isOpen = expanded.contains(c.id)
        return Button {
            withAnimation(Theme.motion) { if isOpen { expanded.remove(c.id) } else { expanded.insert(c.id) } }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                VStack(alignment: .leading, spacing: 5) {
                    Text(c.headline).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                        .lineLimit(isOpen ? nil : 2).fixedSize(horizontal: false, vertical: true)
                    if isOpen, !c.detail.isEmpty {
                        Text(c.detail).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 4)
                if !c.detail.isEmpty {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOpen && !c.detail.isEmpty ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
