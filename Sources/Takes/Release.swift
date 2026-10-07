import AppKit
import Foundation
import Observation
import SwiftUI

/// Takes > Release to GitHub (2026-10-04): runs scripts/public/release.sh in the background. It
/// copies origin/main without personal values, tests the copy and pushes the public repo. The
/// script itself comes from origin/main too, so the checkout's branch or edits never matter.
/// build.sh writes the repo into Info.plist (ReleaseRepo) only where the script exists, so a
/// build of the public copy has no Release item.
///
/// Progress (2026-10-06): the release only showed in the menu title and then a sheet when it
/// stopped. Now a row under Update in the sidebar shows the step, a bar and the time left; its
/// popover lists the steps and says in plain words why a release stopped.
@MainActor @Observable
final class Releaser {
    static let shared = Releaser()

    nonisolated static let repo: String? = Bundle.main.object(forInfoDictionaryKey: "ReleaseRepo") as? String
    nonisolated static var available: Bool { repo.map { FileManager.default.fileExists(atPath: $0 + "/.git") } ?? false }
    /// Fetches, then runs origin/main's release.sh; extra arguments follow it.
    nonisolated static func command(_ repo: String) -> String {
        let r = "'" + repo.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "git -C \(r) fetch -q origin && TAKES_REPO=\(r) bash <(git -C \(r) show origin/main:scripts/public/release.sh)"
    }

    /// The release that runs or last ended; nil once dismissed.
    var run: ReleaseRun?
    /// Opens the row's popover: set when a release stops, so the reason shows without a click.
    var showDetail = false
    var running: Bool { run?.outcome == .running }
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var partial = ""
    @ObservationIgnored private var lastArgs: [String] = []
    @ObservationIgnored private var toast: (String) -> Void = { _ in }

    var menuTitle: String { running ? "Releasing… \(run?.current?.title.lowercased() ?? "")" : "Release to GitHub…" }

    /// Asks first (the push is public once the repo is), then runs. `toast` gets the result.
    func confirmAndRun(toast: @escaping (String) -> Void) {
        guard Self.repo != nil, !running else { return }
        let alert = NSAlert()
        alert.messageText = "Release Takes to GitHub?"
        alert.informativeText = "Takes copies main without your personal data, builds and tests the copy, "
            + "and pushes it to the public repo. It runs in the background and takes a few minutes: "
            + "the sidebar shows how far it is."
        alert.addButton(withTitle: "Release")
        alert.addButton(withTitle: "Cancel")
        let media = NSButton(checkboxWithTitle: "Redraw the README pictures first", target: nil, action: nil)
        alert.accessoryView = media
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        start(args: media.state == .on ? ["--media"] : [], toast: toast)
    }

    func retry() { start(args: lastArgs, toast: toast) }

    func dismiss() {
        guard !running else { return }
        run = nil
        showDetail = false
    }

    /// Stops the script and everything it started (the tests, the build). The script's EXIT trap
    /// removes its worktree.
    func stop() {
        guard let p = process, p.isRunning else { return }
        run?.outcome = .stopped
        for pid in Self.descendants(of: p.processIdentifier).reversed() { kill(pid, SIGTERM) }
        p.terminate()
    }

    private func start(args: [String], toast: @escaping (String) -> Void) {
        guard let repo = Self.repo, !running else { return }
        lastArgs = args
        self.toast = toast
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", Self.command(repo) + " " + args.joined(separator: " ")]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeChat.shellPath
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in Releaser.shared.read(text) }
        }
        p.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            let ok = p.terminationStatus == 0
            Task { @MainActor in
                Releaser.shared.read(rest)
                Releaser.shared.finish(ok: ok)
            }
        }
        partial = ""
        showDetail = false
        run = ReleaseRun(media: args.contains("--media"), started: .now)
        process = p
        do { try p.run() } catch {
            run?.read("Could not start the release: \(error.localizedDescription)", at: .now)
            finish(ok: false)
        }
    }

    private func read(_ text: String) {
        let lines = (partial + text).components(separatedBy: "\n")
        partial = lines.last ?? ""
        for l in lines.dropLast() { run?.read(l, at: .now) }
    }

    private func finish(ok: Bool) {
        if !partial.isEmpty { run?.read(partial, at: .now); partial = "" }
        process = nil
        guard var r = run else { return }
        if r.outcome == .stopped {
            run = nil
            toast("Release stopped")
            return
        }
        r.end(ok: ok, at: .now)
        run = r
        if ok {
            ReleaseEstimates.save(r)
            toast(r.outcome == .nothingNew ? "Released: nothing new since the last release" : "Released to GitHub")
        } else {
            showDetail = true
        }
    }

    /// Every process under `pid`, parents first.
    nonisolated static func descendants(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let kids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0) }
        return kids.flatMap { [$0] + descendants(of: $0) }
    }

    /// A ready ask for an agent in the Takes repo: where it stopped, why and where the log is.
    var agentAsk: String {
        guard let r = run else { return "" }
        var s = "The Takes public release stopped at \"\(r.failedStep?.title ?? "the start")\"."
        let why = r.failure
        if !why.items.isEmpty { s += " \(why.title):\n" + why.items.map { "- \($0)" }.joined(separator: "\n") }
        if let log = r.log { s += "\n\nFull log: \(log)" }
        s += "\n\nFind the cause on main in \(Self.repo ?? "the Takes repo"), fix it, run ./test.sh, push to main, "
            + "then run Takes > Release to GitHub again. The export swaps personal values for neutral ones "
            + "(scripts/public/export.py), so a test can pass here and fail in the public copy."
        return s
    }

    /// One line for the chat agents, so "release Takes" works from any chat.
    nonisolated static var agentNote: String? {
        guard available, let repo else { return nil }
        return "To release Takes to its public GitHub repo (only when asked), run in bash: \(command(repo)). It copies "
            + "origin/main without personal data, tests the copy and pushes it, then prints the result. "
            + "Never edit or build the public copy by hand."
    }
}

/// One run of release.sh, read from its output. release.sh prints "▸ Step" when a step starts,
/// "· detail" while it runs ("· tests 120" counts finished tests) and "@log", "@tag", "@url".
/// Other lines are what went wrong, if it stops.
struct ReleaseRun: Equatable {
    struct Step: Equatable, Identifiable {
        let title: String
        var started: Date?
        var ended: Date?
        var id: String { title }
    }
    enum Outcome: Equatable { case running, released, nothingNew, failed, stopped }

    static let plan = ["Getting the latest main", "Drawing the README pictures", "Removing personal data",
                       "Testing the copy", "Pushing the public repo", "Building the download",
                       "Publishing the GitHub release"]

    var steps: [Step]
    let started: Date
    var ended: Date?
    var outcome = Outcome.running
    var detail = ""
    var tests = 0
    var log: String?
    var tag: String?
    var url: URL?
    /// Lines that are not progress: the reason, when it stops.
    var errors: [String] = []

    init(media: Bool, started: Date) {
        self.started = started
        steps = Self.plan.filter { media || $0 != "Drawing the README pictures" }.map { Step(title: $0) }
    }

    var currentIndex: Int? { steps.lastIndex { $0.started != nil && $0.ended == nil } }
    var current: Step? { currentIndex.map { steps[$0] } }
    /// The step it stopped in.
    var failedStep: Step? {
        guard outcome == .failed else { return nil }
        return steps.last { $0.started != nil } ?? steps.first
    }

    mutating func read(_ raw: String, at now: Date) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if line.hasPrefix("▸ ") {
            let title = String(line.dropFirst(2))
            if let i = currentIndex { steps[i].ended = now }
            if let i = steps.firstIndex(where: { $0.title == title }) {
                steps[i].started = now
            } else {
                // A step this app does not know yet (a newer release.sh): after the last started one.
                let at = (steps.lastIndex { $0.started != nil } ?? -1) + 1
                steps.insert(Step(title: title, started: now), at: at)
            }
            detail = ""
        } else if line.hasPrefix("· tests ") {
            tests = Int(line.dropFirst(8)) ?? tests
        } else if line.hasPrefix("· ") {
            detail = String(line.dropFirst(2))
        } else if line.hasPrefix("@log ") {
            log = String(line.dropFirst(5))
        } else if line.hasPrefix("@tag ") {
            tag = String(line.dropFirst(5))
        } else if line.hasPrefix("@url ") {
            url = URL(string: String(line.dropFirst(5)))
        } else if line.hasPrefix("Released: ") || line.hasPrefix("Nothing new") {
            if line.hasPrefix("Nothing new") { outcome = .nothingNew }
        } else {
            errors.append(line)
        }
    }

    mutating func end(ok: Bool, at now: Date) {
        ended = now
        if let i = currentIndex { steps[i].ended = now }
        if ok {
            if outcome != .nothingNew { outcome = .released }
        } else if outcome != .stopped {
            outcome = .failed
        }
    }

    // MARK: How far

    /// 0...1 of the whole run, from how long each step took last time and how many tests ran.
    func fraction(now: Date, estimates e: ReleaseEstimates) -> Double {
        let total = steps.reduce(0) { $0 + e.seconds($1.title) }
        guard total > 0 else { return 0 }
        var done = 0.0
        for (i, s) in steps.enumerated() {
            if s.ended != nil { done += e.seconds(s.title) }
            else if i == currentIndex { done += e.seconds(s.title) * within(s, now: now, estimates: e) }
        }
        return min(done / total, 0.99)
    }

    /// Seconds left, or nil once it runs longer than last time.
    func remaining(now: Date, estimates e: ReleaseEstimates) -> TimeInterval? {
        guard let i = currentIndex else { return nil }
        let s = steps[i]
        let left = e.seconds(s.title) * (1 - within(s, now: now, estimates: e))
            + steps[(i + 1)...].reduce(0) { $0 + e.seconds($1.title) }
        let over = now.timeIntervalSince(s.started ?? now) > e.seconds(s.title) * 1.5 && !(s.title == "Testing the copy" && tests > 0)
        return over ? nil : left
    }

    /// How far into one step: by time, and by finished tests while testing.
    private func within(_ s: Step, now: Date, estimates e: ReleaseEstimates) -> Double {
        let byTime = min(now.timeIntervalSince(s.started ?? now) / max(e.seconds(s.title), 1), 0.95)
        if s.title == "Testing the copy", tests > 0 {
            // Python tests and the build come first: about a third of the step.
            return min(0.35 + 0.6 * Double(tests) / Double(max(e.tests, tests + 1)), 0.95)
        }
        return byTime
    }

    // MARK: Why it stopped

    /// The reason in plain words: the failed tests by name, build errors, personal data left.
    var failure: (title: String, items: [String]) {
        var tests: [String] = []
        var other: [String] = []
        for l in errors {
            if l.hasPrefix("FAIL: ") || l.hasPrefix("ERROR: ") {
                let name = l.split(separator: " ").dropFirst().first.map(String.init) ?? l
                tests.append(Self.words(name))
            } else if let r = l.range(of: #"Test (\S+)\(.*\)? (failed|recorded)"#, options: .regularExpression),
                      l.contains("✘") {
                let name = l[r].dropFirst(5).prefix { $0 != "(" && $0 != " " }
                tests.append(Self.words(String(name)))
            } else if l.contains("error:") {
                other.append(l.components(separatedBy: "error:").last!.trimmingCharacters(in: .whitespaces))
            } else if l.hasPrefix("Personal values left") {
                other.append("Personal data was left in the public copy")
            }
        }
        tests = tests.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        other = other.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if !tests.isEmpty {
            return (tests.count == 1 ? "1 test failed in the public copy" : "\(tests.count) tests failed in the public copy",
                    Array(tests.prefix(8)) + other.prefix(3))
        }
        if !other.isEmpty { return ("It stopped with an error", Array(other.prefix(6))) }
        return ("It stopped", errors.suffix(3).map { $0 })
    }

    /// "test_a_voice_is_found" and "aVoiceIsFound()" both read "A voice is found".
    static func words(_ name: String) -> String {
        var s = name.hasPrefix("test_") ? String(name.dropFirst(5)) : name
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([A-Z])([A-Z][a-z])"#, with: "$1 $2", options: .regularExpression).lowercased()
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// How long each step took on the last good release, and how many tests ran, so the bar and
/// "minutes left" match this Mac.
struct ReleaseEstimates {
    static let defaults: [String: Double] = [
        "Getting the latest main": 6, "Drawing the README pictures": 90, "Removing personal data": 15,
        "Testing the copy": 420, "Pushing the public repo": 6, "Building the download": 150,
        "Publishing the GitHub release": 25,
    ]
    var times: [String: Double]
    var tests: Int

    static var current: ReleaseEstimates {
        let d = UserDefaults.standard
        return ReleaseEstimates(times: d.dictionary(forKey: "releaseTimes") as? [String: Double] ?? [:],
                                tests: d.integer(forKey: "releaseTests").nonZero ?? 290)
    }

    func seconds(_ step: String) -> Double { times[step] ?? Self.defaults[step] ?? 30 }

    static func save(_ run: ReleaseRun) {
        var t = current.times
        for s in run.steps { if let a = s.started, let b = s.ended { t[s.title] = b.timeIntervalSince(a) } }
        UserDefaults.standard.set(t, forKey: "releaseTimes")
        if run.tests > 0 { UserDefaults.standard.set(run.tests, forKey: "releaseTests") }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - Sidebar

/// Under Update in the sidebar while a release runs or after it ended: the step, a bar and the
/// time left. A click opens the steps; a stopped release opens them by itself.
struct ReleaseRow: View {
    @Bindable var releaser = Releaser.shared
    @State private var hover = false

    var body: some View {
        if let run = releaser.run {
            TimelineView(.periodic(from: .now, by: 1)) { t in
                let e = ReleaseEstimates.current
                Button { releaser.showDetail.toggle() } label: { label(run, now: t.date, e: e) }
                    .buttonStyle(.plain)
            }
            .onHover { hover = $0 }
            .popover(isPresented: $releaser.showDetail, arrowEdge: .trailing) { ReleaseDetail(releaser: releaser) }
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    private func tint(_ run: ReleaseRun) -> Color {
        switch run.outcome {
        case .failed: Theme.danger
        case .released, .nothingNew: Theme.live
        default: Theme.accentInk
        }
    }

    private func label(_ run: ReleaseRun, now: Date, e: ReleaseEstimates) -> some View {
        let color = tint(run)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Group {
                    switch run.outcome {
                    case .running, .stopped: ProgressView().controlSize(.mini)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill")
                    case .released, .nothingNew: Image(systemName: "checkmark.circle.fill")
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(run)).font(Theme.sans(13, .semibold)).lineLimit(1)
                    Text(subtitle(run, now: now, e: e)).font(Theme.mono(11)).opacity(0.75).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, run.outcome == .running ? 6 : 7)
            if run.outcome == .running {
                GeometryReader { g in
                    Capsule().fill(color.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule().fill(color).frame(width: max(4, g.size.width * run.fraction(now: now, estimates: e)))
                        }
                }
                .frame(height: 3)
                .padding(.horizontal, 10).padding(.bottom, 7)
                .animation(.linear(duration: 1), value: now)
            }
        }
        .foregroundStyle(color)
        .background(color.opacity(hover ? 0.18 : 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .help("Release to GitHub: see the steps")
    }

    private func title(_ run: ReleaseRun) -> String {
        switch run.outcome {
        case .running, .stopped: "Releasing to GitHub"
        case .failed: "Release stopped"
        case .released: run.tag.map { "Released \($0)" } ?? "Released to GitHub"
        case .nothingNew: "Nothing new to release"
        }
    }

    private func subtitle(_ run: ReleaseRun, now: Date, e: ReleaseEstimates) -> String {
        switch run.outcome {
        case .running:
            let step = run.current?.title ?? "Starting"
            guard let left = run.remaining(now: now, estimates: e) else { return "\(step) · longer than last time" }
            return "\(step) · \(ReleaseDetail.minutes(left))"
        case .stopped: return "Stopping…"
        case .failed: return run.failure.title
        case .released, .nothingNew: return "took \(ReleaseDetail.clock((run.ended ?? now).timeIntervalSince(run.started)))"
        }
    }
}

/// The steps of a release with their times, why it stopped, and what to do next.
struct ReleaseDetail: View {
    let releaser: Releaser
    @State private var copied = false
    @State private var details = false

    static func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
    static func minutes(_ t: TimeInterval) -> String {
        t < 60 ? "under a minute left" : "\(Int((t / 60).rounded(.up))) min left"
    }

    var body: some View {
        if let run = releaser.run {
            TimelineView(.periodic(from: .now, by: 1)) { t in
                content(run, now: t.date)
            }
            .padding(16)
            .frame(width: 380)
        }
    }

    private func content(_ run: ReleaseRun, now: Date) -> some View {
        let e = ReleaseEstimates.current
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Release to GitHub").font(Theme.display(17))
                Spacer()
                Text(Self.clock((run.ended ?? now).timeIntervalSince(run.started))).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                if run.outcome != .running && run.outcome != .stopped {
                    Button { releaser.dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(BracketButtonStyle()).help("Close: hides the release row until the next release")
                }
            }
            if run.outcome == .running {
                GeometryReader { g in
                    Capsule().fill(Theme.accent.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.accent).frame(width: max(5, g.size.width * run.fraction(now: now, estimates: e)))
                        }
                }
                .frame(height: 5)
                .animation(.linear(duration: 1), value: now)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(run.steps) { s in row(s, run: run, now: now, e: e) }
            }
            if run.outcome == .failed { failure(run) }
            buttons(run)
        }
    }

    private func row(_ s: ReleaseRun.Step, run: ReleaseRun, now: Date, e: ReleaseEstimates) -> some View {
        let failed = run.failedStep?.id == s.id
        let live = s.started != nil && s.ended == nil && run.outcome == .running
        return HStack(spacing: 9) {
            Group {
                if failed {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                } else if live {
                    ProgressView().controlSize(.mini)
                } else if s.ended != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.live)
                } else {
                    Image(systemName: "circle").foregroundStyle(Theme.faint)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(Theme.sans(13, live || failed ? .semibold : .regular))
                    .foregroundStyle(s.started == nil ? Theme.muted : Theme.ink)
                if live, let d = detail(run, e: e) {
                    Text(d).font(Theme.sans(11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let a = s.started {
                Text(Self.clock((s.ended ?? run.ended ?? now).timeIntervalSince(a))).font(Theme.mono(11)).foregroundStyle(Theme.faint)
            } else if run.outcome == .running {
                Text("~" + Self.clock(e.seconds(s.title))).font(Theme.mono(11)).foregroundStyle(Theme.faint.opacity(0.7))
            }
        }
    }

    private func detail(_ run: ReleaseRun, e: ReleaseEstimates) -> String? {
        if run.current?.title == "Testing the copy", run.tests > 0 {
            return "\(run.tests) of about \(max(e.tests, run.tests)) tests done"
        }
        return run.detail.isEmpty ? nil : run.detail
    }

    private func failure(_ run: ReleaseRun) -> some View {
        let why = run.failure
        return VStack(alignment: .leading, spacing: 8) {
            Text(why.title).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(why.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Theme.faint)
                        Text(item).font(Theme.sans(12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            DisclosureGroup(isExpanded: $details) {
                ScrollView {
                    Text(run.errors.joined(separator: "\n")).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            } label: {
                Text("What the script said").font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .background(Theme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func buttons(_ run: ReleaseRun) -> some View {
        HStack(spacing: 6) {
            switch run.outcome {
            case .running, .stopped:
                Spacer()
                Button(run.outcome == .stopped ? "Stopping…" : "Stop release") { releaser.stop() }
                    .buttonStyle(AccentButtonStyle(kind: .quiet)).fixedSize().disabled(run.outcome == .stopped)
            case .failed:
                Button(copied ? "Copied" : "Copy for an agent") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(releaser.agentAsk, forType: .string)
                    copied = true
                }
                .buttonStyle(BracketButtonStyle()).fixedSize()
                .help("Copies where it stopped, why, and the log path, ready to paste into Claude Code")
                logButton(run)
                Spacer(minLength: 4)
                Button("Try again") { releaser.retry() }.buttonStyle(AccentButtonStyle(kind: .accent)).fixedSize()
            case .released, .nothingNew:
                logButton(run)
                Spacer()
                if let url = run.url {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }.buttonStyle(AccentButtonStyle(kind: .accent)).fixedSize()
                }
            }
        }
    }

    @ViewBuilder private func logButton(_ run: ReleaseRun) -> some View {
        if let log = run.log {
            Button("Show log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }.buttonStyle(BracketButtonStyle()).fixedSize()
        }
    }
}
