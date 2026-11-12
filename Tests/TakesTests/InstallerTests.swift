import Foundation
import Testing

struct InstallerTests {
    @Test func aFailedCopyKeepsTheInstalledApp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let process = try fixture.run(copyFails: true)

        #expect(process.terminationStatus != 0)
        try fixture.expectInstalled("working app")
        #expect(!fixture.installed.appending(path: "partial").exists)
        #expect(!fixture.lockExists)
    }

    @Test func aFailedFinalReplacementKeepsTheInstalledApp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let process = try fixture.run(replacement: "fail")

        #expect(process.terminationStatus != 0)
        try fixture.expectInstalled("working app")
        #expect(!fixture.lockExists)
        #expect(try fixture.stages().isEmpty)
    }

    @Test func anInterruptedReplacementRecoversItsStaleLockOnTheNextRun() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let interrupted = try fixture.run(replacement: "kill")
        #expect(interrupted.terminationReason == .uncaughtSignal)
        try fixture.expectInstalled("working app")
        #expect(fixture.lockExists)
        #expect(try !fixture.stages().isEmpty)

        let recovered = try fixture.run(replacement: "success")

        #expect(recovered.terminationStatus == 0)
        try fixture.expectInstalled("new app")
        #expect(!fixture.lockExists)
        #expect(try fixture.stages().isEmpty)
    }

    @Test func concurrentInstallersCannotBothRecoverTheSameStaleLock() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeStaleLock()

        let installers = [
            try fixture.start(replacement: "gated-success"),
            try fixture.start(replacement: "gated-success"),
        ]
        await fixture.until {
            fixture.readyCount == 2 || installers.contains { !$0.isRunning }
        }

        #expect(fixture.readyCount <= 1)
        #expect(installers.filter { $0.isRunning }.count <= 1)
        fixture.openGate()
        installers.forEach { $0.waitUntilExit() }

        let successes = installers.filter { $0.terminationStatus == 0 }.count
        #expect(successes <= 1)
        if successes == 0 {
            let recovered = try fixture.run(replacement: "success")
            #expect(recovered.terminationStatus == 0)
        }
        try fixture.expectInstalled("new app")
        #expect(!fixture.lockExists)
        #expect(try fixture.stages().isEmpty)
    }

#if os(macOS)
    @Test func successfulInstallUsesFoundationReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let process = try fixture.run(replacement: "foundation")

        #expect(process.terminationStatus == 0)
        try fixture.expectInstalled("new app")
        #expect(!fixture.lockExists)
        #expect(try fixture.stages().isEmpty)
    }
#endif

    private final class Fixture {
        let fm = FileManager.default
        let root: URL
        let apps: URL
        let installed: URL
        let lock: URL
        var lockExists: Bool { (try? locks().isEmpty) == false }
        var readyCount: Int {
            (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("ready.") }.count) ?? 0
        }
        private let fakeBin: URL
        private let dmg: URL
        private let download: URL
        private let script: URL
        private let gate: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "takes-installer-\(UUID().uuidString)")
            apps = root.appending(path: "Applications")
            installed = apps.appending(path: "Takes.app")
            lock = apps.appending(path: ".takes-install.lock")
            fakeBin = root.appending(path: "bin")
            dmg = root.appending(path: "Takes.dmg")
            download = root.appending(path: "download/Takes.app")
            gate = root.appending(path: "gate")
            let files = FileManager.default
            script = try #require([
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/public/install.sh").standardized,
                URL(fileURLWithPath: files.currentDirectoryPath).appending(path: "scripts/public/install.sh"),
                URL(fileURLWithPath: files.currentDirectoryPath).appending(path: "install.sh"),
            ].first { files.fileExists(atPath: $0.path) })
            try fm.createDirectory(at: installed, withIntermediateDirectories: true)
            try fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
            try Data("working app".utf8).write(to: installed.appending(path: "marker"))
            try Data().write(to: dmg)
            try makeDownload()
            try makeCommands()
        }

        func run(copyFails: Bool = false, replacement: String = "fail") throws -> Process {
            let process = try start(copyFails: copyFails, replacement: replacement)
            process.waitUntilExit()
            return process
        }

        func start(copyFails: Bool = false, replacement: String = "fail") throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            let osascript = replacement == "foundation"
                ? "/usr/bin/osascript"
                : fakeBin.appending(path: "osascript").path
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HOME": root.appending(path: "home").path,
                "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "TAKES_APPS": apps.path,
                "TAKES_DMG": dmg.path,
                "TAKES_OSASCRIPT": osascript,
                "TAKES_PLISTBUDDY": fakeBin.appending(path: "PlistBuddy").path,
                "TEST_APP": download.path,
                "TEST_COPY_FAIL": copyFails ? "1" : "0",
                "TEST_GATE": gate.path,
                "TEST_ROOT": root.path,
                "TEST_REPLACE_MODE": replacement,
            ]) { _, test in test }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }

        func makeStaleLock() throws {
            try fm.createSymbolicLink(atPath: lock.path, withDestinationPath: "not-a-pid|stale")
        }

        func openGate() { _ = fm.createFile(atPath: gate.path, contents: nil) }

        func until(_ seconds: Double = 30, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !condition() && Date() < end {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        func expectInstalled(_ marker: String) throws {
            #expect(try Data(contentsOf: installed.appending(path: "marker")) == Data(marker.utf8))
        }

        func stages() throws -> [URL] {
            try fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)
                .filter {
                    $0.lastPathComponent.hasPrefix(".takes-install.") &&
                        !$0.lastPathComponent.hasPrefix(".takes-install.lock")
                }
        }

        func locks() throws -> [URL] {
            try fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".takes-install.lock") }
        }

        func remove() { try? fm.removeItem(at: root) }

        private func makeDownload() throws {
            let executable = download.appending(path: "Contents/MacOS/Takes")
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("new app".utf8).write(to: download.appending(path: "marker"))
            try Data().write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let plist: [String: Any] = [
                "CFBundleIdentifier": "de.marvinaziz.takes",
                "CFBundleExecutable": "Takes",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: download.appending(path: "Contents/Info.plist"))
        }

        private func makeCommands() throws {
            try executable("""
            #!/bin/sh
            [ "$1" = -s ] && echo Darwin || echo arm64
            """, named: "uname")
            try executable("""
            #!/bin/sh
            echo 15.0
            """, named: "sw_vers")
            try executable("""
            #!/bin/sh
            if [ "$1" = attach ]; then
              while [ "$#" -gt 0 ]; do
                if [ "$1" = -mountpoint ]; then
                  mkdir -p "$2"
                  /bin/cp -R "$TEST_APP" "$2/Takes.app"
                  exit 0
                fi
                shift
              done
            fi
            exit 0
            """, named: "hdiutil")
            try executable("""
            #!/bin/sh
            if [ "$TEST_COPY_FAIL" = 1 ]; then
              mkdir -p "$2"
              echo partial > "$2/partial"
              exit 1
            fi
            /bin/cp -R "$1" "$2"
            """, named: "ditto")
            try executable("""
            #!/bin/bash
            incoming="$4"
            installed="$5"
            backup="$6"
            case "$TEST_REPLACE_MODE" in
              fail) mv "$installed" "$backup"; exit 1 ;;
              kill) kill -KILL "$PPID"; exit 137 ;;
              gated-success)
                touch "$TEST_ROOT/ready.$PPID"
                while [ -d "$TEST_ROOT" ] && [ ! -e "$TEST_GATE" ]; do sleep 0.05; done
                rm -rf "$installed"; mv "$incoming" "$installed"
                ;;
              success) rm -rf "$installed"; mv "$incoming" "$installed" ;;
            esac
            """, named: "osascript")
            try executable("""
            #!/bin/sh
            case "$2" in
              *CFBundleIdentifier*) echo de.marvinaziz.takes ;;
              *CFBundleExecutable*) echo Takes ;;
            esac
            """, named: "PlistBuddy")
            try executable("#!/bin/sh\nexit 0", named: "xattr")
            try executable("#!/bin/sh\nexit 0", named: "ffmpeg")
            try executable("#!/bin/sh\nexit 0", named: "xcode-select")
            try executable("""
            #!/bin/sh
            [ "$1" = login ] && [ "$2" = status ] && echo 'Logged in'
            """, named: "codex")
        }

        private func executable(_ contents: String, named name: String) throws {
            let url = fakeBin.appending(path: name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
