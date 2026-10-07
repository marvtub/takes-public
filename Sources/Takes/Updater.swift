import AppKit
import Foundation
import Observation
import SwiftUI

/// Agents never restart Takes (2026-10-03). `./build.sh install` stages a new build in
/// `~/Applications/.update.noindex/Takes.app` while Takes runs; this notices it, the sidebar shows
/// Update, and only the user's click swaps it in: once nothing records or runs (a Claude reply, an
/// export), Takes quits, the new build replaces the old one, and it opens again. `.noindex`
/// keeps Spotlight, and so macOS, from opening the staged copy.
///
/// Public releases (2026-10-07): a Takes from a GitHub release (its Info.plist has ReleaseTag)
/// also asks GitHub for the newest release, at launch and every six hours. A newer one is
/// downloaded and staged in the same folder, so the same Update row shows, with the release
/// notes as What's new. Before this, users of a release never heard of a newer one.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// The waiting build: when it was made, and the commits it adds, newest first. `release` is
    /// the tag of a staged GitHub release ("v2026.10.7"), nil for a local build.
    struct Staged: Equatable { var stamp: String; var changes: [String]; var log: [Change] = []; var release: String? = nil }

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

        /// A release's notes (release.sh): "### Area" headings over "- headline" lines. The
        /// Install section is for the download page, not news.
        nonisolated static func notes(_ body: String) -> [Change] {
            var out: [Change] = [], area = "Takes"
            for line in body.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("### ") { area = String(line.dropFirst(4)); continue }
                guard line.hasPrefix("- "), area != "Install" else { continue }
                out.append(Change(id: "\(area)-\(out.count)", area: area, headline: String(line.dropFirst(2)), detail: ""))
            }
            return out
        }
    }
    private(set) var staged: Staged?
    /// Clicked: waits for the recording or the work to end, then restarts.
    private(set) var applying = false
    private(set) var waitingFor: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private var releaseTimer: Timer?
    @ObservationIgnored private var fetching = false

    static let releaseRepo = "marvtub/takes-public"
    /// This build's release tag; nil for a build from source, which never updates itself.
    private var ownRelease: String? { Bundle.main.infoDictionary?["ReleaseTag"] as? String }

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
        guard ownRelease != nil else { return }
        checkRelease()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.checkRelease() }
        }
    }

    /// "v2026.10.6.2" is newer than "v2026.10.6": the numbers compare in order.
    nonisolated static func isNewer(_ tag: String, than own: String) -> Bool {
        func parts(_ t: String) -> [Int] { t.drop { !$0.isNumber }.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(tag), b = parts(own)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        var tag_name: String
        var body: String?
        var assets: [Asset]
    }

    /// Asks GitHub for the newest release; a newer one is downloaded and staged. Quiet when
    /// offline or when GitHub says no: it tries again in six hours.
    func checkRelease() {
        guard let own = ownRelease, !fetching, !applying else { return }
        fetching = true
        let api = URL(string: "https://api.github.com/repos/\(Self.releaseRepo)/releases/latest")!
        let stage = waiting.deletingLastPathComponent(), skip = staged?.release, id = Bundle.main.bundleIdentifier ?? ""
        Task { @MainActor in
            defer { fetching = false }
            if await Self.fetchRelease(api: api, own: own, skip: skip, bundleID: id, into: stage) != nil {
                lastRead = nil; check()
            }
        }
    }

    /// Reads the newest release from `api`; when it is newer than `own` and not `skip` (already
    /// staged), downloads its Takes.dmg and stages it. Returns the staged tag.
    nonisolated static func fetchRelease(api: URL, own: String, skip: String?, bundleID: String, into stage: URL) async -> String? {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(Release.self, from: data),
              isNewer(r.tag_name, than: own), skip != r.tag_name,
              let dmg = r.assets.first(where: { $0.name == "Takes.dmg" }),
              let (file, dresp) = try? await URLSession.shared.download(from: dmg.browser_download_url) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard (dresp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let notes = (try? JSONEncoder().encode(["tag": r.tag_name, "body": r.body ?? ""])) ?? Data()
        return Self.stage(dmg: file, tag: r.tag_name, bundleID: bundleID, notes: notes, into: stage) ? r.tag_name : nil
    }

    /// Mounts the download, checks it is Takes at that tag, and stages its app as build.sh does.
    /// The notes go beside it as release.json for What's new.
    nonisolated static func stage(dmg: URL, tag: String, bundleID: String, notes: Data, into stage: URL) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("takes-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
              (try? notes.write(to: tmp.appendingPathComponent("release.json"))) != nil else { return false }
        let script = """
        set -e
        mnt="$0/mnt"; trap 'hdiutil detach -quiet "$mnt" 2>/dev/null || true' EXIT
        hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$1"
        plist="$mnt/Takes.app/Contents/Info.plist"
        [ "$(/usr/libexec/PlistBuddy -c 'Print :ReleaseTag' "$plist")" = "$2" ]
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "$3" ]
        mkdir -p "$4"; rm -rf "$4/incoming.app"
        ditto "$mnt/Takes.app" "$4/incoming.app"
        xattr -dr com.apple.quarantine "$4/incoming.app" 2>/dev/null || true
        cp "$0/release.json" "$4/release.json"
        rm -rf "$4/Takes.app"; mv "$4/incoming.app" "$4/Takes.app"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, tmp.path, dmg.path, tag, bundleID, stage.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Reads the staged Info.plist again only when it changed. A plist is read directly, not
    /// through Bundle, which caches it per path.
    func check() {
        let plist = waiting.appendingPathComponent("Contents/Info.plist")
        let changed = (try? FileManager.default.attributesOfItem(atPath: plist.path))?[.modificationDate] as? Date
        if changed != nil, changed == lastRead { return }
        lastRead = changed
        let next = Self.read(waiting, ownStamp: Bundle.main.infoDictionary?["BuildStamp"] as? String)
        if staged != next { staged = next }
    }

    /// The build staged at `waiting`, or nil when there is none or it is this build.
    nonisolated static func read(_ waiting: URL, ownStamp: String?) -> Staged? {
        guard let info = NSDictionary(contentsOf: waiting.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let stamp = info["BuildStamp"] as? String, stamp != ownStamp else { return nil }
        let changes = (info["BuildChanges"] as? String ?? "").split(separator: "\n").map(String.init)
        let json = try? Data(contentsOf: waiting.appendingPathComponent("Contents/Resources/changes.json"))
        var log = Change.load(json)
        // A staged release shows its notes: the public repo's own commits say nothing.
        let release = info["ReleaseTag"] as? String
        if let release, let data = try? Data(contentsOf: waiting.deletingLastPathComponent().appendingPathComponent("release.json")),
           let notes = try? JSONDecoder().decode([String: String].self, from: data), notes["tag"] == release {
            log = Change.notes(notes["body"] ?? "")
        }
        if log.isEmpty { log = changes.map { Change.parse(subject: $0) } }
        return Staged(stamp: stamp, changes: changes, log: log, release: release)
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
                Text("\(staged.log.count == 1 ? "1 change" : "\(staged.log.count) changes") in \(staged.release.map { "Takes \($0.dropFirst())" } ?? "the build from \(staged.stamp.split(separator: " ").dropFirst().joined(separator: " "))")")
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
