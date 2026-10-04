import Foundation

/// Tap-to-update for the iPhone app (2026-10-03). `ios/install.sh` no longer installs: it stages
/// the build in ~/Library/Application Support/Takes/phone-update with an update.json. The phone
/// asks GET /api/update and shows Update; a tap (POST /api/update/install) makes this Mac install
/// it with devicectl, which ends the app on the phone, and open it again. `install.sh --now`
/// still installs at once (refresh.sh keeps the 7-day profile alive with it).
final class PhoneUpdate: @unchecked Sendable {
    static let shared = PhoneUpdate()
    static let bundleID = "de.marvinaziz.takes.phone"

    /// What install.sh writes next to the staged app.
    struct Staged: Codable, Equatable {
        var stamp: String
        var changes: [String]?
        var device: String
        var staged: String?
    }

    /// What the phone sees: empty when nothing waits.
    struct Status: Codable, Equatable {
        var stamp: String?
        var changes: [String]?
        var installing: Bool?
        var error: String?
    }

    let dir: URL
    private let lock = NSLock()
    private var installing = false
    private var lastError: String?

    init(dir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Takes/phone-update")) {
        self.dir = dir
    }

    var app: URL { dir.appending(path: "Takes.app") }
    var manifest: URL { dir.appending(path: "update.json") }

    /// The staged build, if both its app and its update.json are there.
    func staged() -> Staged? {
        guard FileManager.default.fileExists(atPath: app.appending(path: "Info.plist").path),
              let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(Staged.self, from: data)
    }

    func status() -> Status {
        let (busy, error) = lock.withLock { (installing, lastError) }
        return Self.status(staged: staged(), installing: busy, error: error)
    }

    /// Pure: what to tell the phone. An error stays visible only while the build still waits.
    static func status(staged: Staged?, installing: Bool, error: String?) -> Status {
        guard let staged else { return Status() }
        return Status(stamp: staged.stamp, changes: staged.changes,
                      installing: installing ? true : nil, error: installing ? nil : error)
    }

    /// Starts the install in the background. False when nothing waits or one is already running.
    @discardableResult
    func install() -> Bool {
        guard let staged = staged() else { return false }
        let start = lock.withLock { () -> Bool in
            if installing { return false }
            installing = true; lastError = nil
            return true
        }
        guard start else { return false }
        Thread.detachNewThread { [self] in
            let (ok, output) = Self.run(["devicectl", "device", "install", "app", "--device", staged.device, app.path])
            if ok {
                _ = Self.run(["devicectl", "device", "process", "launch", "--device", staged.device, Self.bundleID])
                let fm = FileManager.default
                let installed = dir.appending(path: "installed.json")
                try? fm.removeItem(at: installed)
                try? fm.moveItem(at: manifest, to: installed)
                try? fm.removeItem(at: app)
            }
            lock.withLock {
                installing = false
                lastError = ok ? nil : Self.tail(output)
            }
        }
        return true
    }

    /// The last few lines, which is where devicectl says what went wrong.
    static func tail(_ output: String, lines: Int = 4) -> String {
        let all = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let last = all.suffix(lines).joined(separator: "\n")
        return last.isEmpty ? "The install failed." : last
    }

    private static func run(_ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}
