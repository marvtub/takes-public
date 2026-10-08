import Foundation
import Testing
@testable import Takes

// The public README's phone pictures (2026-10-08): serves the made-up library that
// scripts/public/demo.py builds to the iPhone simulator, until the stop file appears.
// scripts/public/media.sh runs it beside ios/TakesPhoneUITests/ReadmeShots.swift.
//   TAKES_PHONE_DEMO=/tmp/takes-demo TAKES_PHONE_PORT=8799 TAKES_PHONE_STOP=/tmp/stop ./test.sh --filter PhoneReadmeServer
@Suite struct PhoneReadmeServer {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_PHONE_DEMO"] != nil))
    func serveTheDemoLibrary() async throws {
        let env = ProcessInfo.processInfo.environment
        let server = PhoneServer(root: URL(fileURLWithPath: env["TAKES_PHONE_DEMO"]!), demo: true)
        let listener = PhoneListener(handler: server)
        try listener.start(port: UInt16(env["TAKES_PHONE_PORT"] ?? "8799")!)
        defer { listener.stop() }
        let stop = env["TAKES_PHONE_STOP"] ?? "/tmp/takes-phone-stop"
        let end = Date().addingTimeInterval(900)
        while !FileManager.default.fileExists(atPath: stop) && Date() < end {
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// The demo shows only the made-up creator: never the Mac's LinkedIn name or photo.
    @Test func theDemoNeverShowsTheMacsProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PhoneServer(root: root, demo: true)
        let photo = await server.respond(PhoneRequest(method: "GET", path: "/api/profile/photo"))
        guard case .json(_, 404) = photo else { Issue.record("The demo sent a photo with no creator"); return }

        let avatar = root.appending(path: "avatar.jpg")
        try Data([0xFF, 0xD8]).write(to: avatar)
        try JSONSerialization.data(withJSONObject: ["name": "Maya Okafor", "headline": "Food creator", "avatar": avatar.path])
            .write(to: root.appending(path: ".creator.json"))
        guard case .file(let f, _) = await server.respond(PhoneRequest(method: "GET", path: "/api/profile/photo")) else {
            Issue.record("No creator photo"); return
        }
        #expect(f == avatar)
        guard case .json(_, 404) = await server.respond(PhoneRequest(method: "GET", path: "/api/update")) else {
            Issue.record("The demo showed this Mac's phone build"); return
        }
    }
}
