import AppKit
import SwiftUI

// Commands the agent left running (2026-10-18). A preview server in the foreground held a chat
// until its time limit, with "ship it" queued behind it. Now each shell command the chat's agent
// runs for more than a few seconds shows above the message box: what it is, its local address if
// it serves one, how long it runs, and Stop.

struct AgentCommand: Identifiable, Equatable {
    let pid: pid_t
    let command: String
    let seconds: Int
    var port: Int?
    var id: pid_t { pid }
}

enum AgentCommands {
    /// A command shows once it has run this long: quick ones come and go unseen.
    static let shownAfter = 8

    /// The shells under the agent's process, oldest first. Off main: it runs ps and lsof.
    static func list(under root: pid_t) -> [AgentCommand] {
        let rows = table()
        var out: [AgentCommand] = []
        for r in rows where r.ppid == root && r.seconds >= shownAfter {
            guard let cmd = shown(r.command) else { continue }
            out.append(AgentCommand(pid: r.pid, command: cmd, seconds: r.seconds,
                                    port: port(of: subtree(r.pid, rows))))
        }
        return out.sorted { $0.seconds > $1.seconds }
    }

    /// The command a shell runs, as the agent wrote it; nil for what is not a shell (MCP servers).
    /// Claude Code wraps each Bash call: `zsh -c source <snapshot> … && eval '<command>' < /dev/null …`.
    static func shown(_ line: String) -> String? {
        let shells = ["/bin/zsh -c ", "/bin/bash -c ", "/bin/sh -c ", "zsh -c ", "bash -c ", "sh -c "]
        guard let shell = shells.first(where: { line.hasPrefix($0) }) else { return nil }
        var cmd = String(line.dropFirst(shell.count))
        if let e = cmd.range(of: "eval '") {
            cmd = String(cmd[e.upperBound...])
            var out = "", rest = Substring(cmd)
            // The command ends at the first quote that is not part of '\''.
            while let q = rest.firstIndex(of: "'") {
                out += rest[..<q]
                let after = rest[q...]
                if after.hasPrefix("'\\''") { out += "'"; rest = after.dropFirst(4) } else { rest = ""; break }
            }
            if !rest.isEmpty { out += rest }
            cmd = out
        }
        // "cd somewhere && python3 -m http.server": the part after the cd says what runs.
        if cmd.hasPrefix("cd "), let and = cmd.range(of: " && ") { cmd = String(cmd[and.upperBound...]) }
        cmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        return cmd.isEmpty ? nil : cmd
    }

    /// Stops the command and everything it started: TERM, then KILL for what is left after 2 s.
    static func stop(_ pid: pid_t) {
        let pids = subtree(pid, table())
        for p in pids.reversed() { kill(p, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for p in pids.reversed() where kill(p, 0) == 0 { kill(p, SIGKILL) }
        }
    }

    /// "4:12", "1:02:09".
    static func clock(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: ps and lsof

    struct Row { let pid: pid_t; let ppid: pid_t; let seconds: Int; let command: String }

    static func table() -> [Row] {
        run("/bin/ps", ["-axo", "pid=,ppid=,etime=,command="]).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { return nil }
            return Row(pid: pid, ppid: ppid, seconds: seconds(String(parts[2])), command: String(parts[3]))
        }
    }

    /// ps etime: [[dd-]hh:]mm:ss.
    static func seconds(_ etime: String) -> Int {
        let dayParts = etime.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    static func subtree(_ root: pid_t, _ rows: [Row]) -> [pid_t] {
        var out = [root], i = 0
        while i < out.count {
            let p = out[i]
            out += rows.filter { $0.ppid == p }.map(\.pid)
            i += 1
        }
        return out
    }

    /// The lowest TCP port one of these processes listens on.
    static func port(of pids: [pid_t]) -> Int? {
        let list = pids.map(String.init).joined(separator: ",")
        let out = run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", list, "-Fn"])
        return out.split(separator: "\n").compactMap { l -> Int? in
            guard l.hasPrefix("n"), let colon = l.lastIndex(of: ":") else { return nil }
            return Int(l[l.index(after: colon)...])
        }.min()
    }

    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The running commands of one chat, read every 2 s while its panel shows.
struct AgentCommandsRow: View {
    let pid: pid_t?
    @State private var commands: [AgentCommand] = []

    var body: some View {
        VStack(spacing: 6) {
            ForEach(commands) { c in
                AgentCommandChip(command: c) {
                    AgentCommands.stop(c.pid)
                    withAnimation(Theme.motion) { commands.removeAll { $0.pid == c.pid } }
                }
            }
        }
        .task(id: pid) {
            guard let pid else { commands = []; return }
            while !Task.isCancelled {
                let now = await Task.detached(priority: .utility) { AgentCommands.list(under: pid) }.value
                if now != commands { withAnimation(Theme.motion) { commands = now } }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// One running command: a terminal mark, the command, its address, how long it runs, Stop.
struct AgentCommandChip: View {
    let command: AgentCommand
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            Text(command.command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let port = command.port, let url = URL(string: "http://localhost:\(port)") {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text(verbatim: "localhost:\(port)").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.accentInk)
                }
                .buttonStyle(.plain).help("Open it in the browser")
            }
            Text(AgentCommands.clock(command.seconds)).font(Theme.mono(11.5)).foregroundStyle(Theme.faint)
            Button(action: stop) {
                Text("Stop").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain).help("Stop this command and what it started")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        .help("A command Takes started. It is still running.")
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}
