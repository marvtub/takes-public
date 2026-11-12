import CryptoKit
import Foundation
import Testing
@testable import Takes

/// Security review T2 (2026-11-06): an update is a Takes.dmg from the public repo's GitHub
/// release, with the SHA-256 api.github.com lists for it. gettakes.app only says that a new
/// version exists. Every HTTP answer here comes from `UpdateStub`, so no network.
@Suite(.serialized)
struct UpdaterTests {
    static let repo = "https://github.com/marvtub/takes-public/releases/download"
    static let api = "https://api.github.com/repos/marvtub/takes-public"
    static let hint = URL(string: "https://gettakes.x.test/latest")!

    @Test func onlyThePublicReleasesTakesDMGIsADownload() {
        let tag = "v2026.10.7"
        #expect(Updater.isReleaseAsset(URL(string: "\(Self.repo)/\(tag)/Takes.dmg")!, tag: tag))
        for bad in ["http://github.com/marvtub/takes-public/releases/download/v2026.10.7/Takes.dmg",
                    "https://gettakes.app/releases/download/v2026.10.7/Takes.dmg",
                    "https://github.com.evil.x.test/marvtub/takes-public/releases/download/v2026.10.7/Takes.dmg",
                    "https://objects.githubusercontent.com/marvtub/takes-public/releases/download/v2026.10.7/Takes.dmg",
                    "https://github.com:8443/marvtub/takes-public/releases/download/v2026.10.7/Takes.dmg",
                    "https://me@github.com/marvtub/takes-public/releases/download/v2026.10.7/Takes.dmg",
                    "https://github.com/evil/takes-public/releases/download/v2026.10.7/Takes.dmg",
                    "https://github.com/marvtub/takes/releases/download/v2026.10.7/Takes.dmg",
                    "https://github.com/marvtub/takes-public/releases/download/v2026.10.8/Takes.dmg",
                    "https://github.com/marvtub/takes-public/releases/download/v2026.10.7/Other.dmg",
                    "https://github.com/marvtub/takes-public/releases/download/v2026.10.7/Takes.dmg?x=1",
                    "https://github.com/marvtub/takes-public/releases/download/v2026.10.7/../../../evil/Takes.dmg"] {
            #expect(!Updater.isReleaseAsset(URL(string: bad)!, tag: tag), "\(bad)")
        }
        #expect(!Updater.isReleaseAsset(URL(string: "\(Self.repo)/x/../Takes.dmg")!, tag: "x/.."))
        #expect(Updater.isTag("v2026.10.7.2"))
        #expect(!Updater.isTag("v2026.10.7/../x"))
        #expect(!Updater.isTag("latest"))
        #expect(Updater.sha256Hex(digest: "sha256:" + String(repeating: "Ab", count: 32)) == String(repeating: "ab", count: 32))
        #expect(Updater.sha256Hex(digest: nil) == nil)
        #expect(Updater.sha256Hex(digest: "md5:" + String(repeating: "a", count: 64)) == nil)
        #expect(Updater.sha256Hex(digest: "sha256:abc") == nil)
        #expect(Updater.sha256Hex(digest: "sha256:" + String(repeating: "g", count: 64)) == nil)
    }

    /// gettakes.app names a newer tag and a download of its own; the file comes from GitHub's
    /// release asset with GitHub's digest, and the hint's download is never asked for.
    @Test func aReleaseUpdatesFromGitHubWithItsDigest() async throws {
        let t = try Fixture()
        defer { t.done() }
        let evil = "https://evil.x.test/Takes.dmg"
        UpdateStub.set(Self.hint.absoluteString, json: ["tag_name": t.tag, "assets": [["name": "Takes.dmg", "browser_download_url": evil, "digest": "sha256:\(t.sha)"]]])
        t.gitHub(digest: "sha256:\(t.sha)")
        let tag = await Updater.fetchRelease(api: Self.hint, own: "v2026.10.6", skip: nil, bundleID: "de.example.takes", into: t.stage, session: UpdateStub.session)
        #expect(tag == t.tag)
        #expect(!UpdateStub.asked.contains(evil))
        let staged = try #require(Updater.read(t.stage.appending(path: "Takes.app"), ownStamp: "old"))
        #expect(staged.release == t.tag)
        #expect(staged.log.map(\.headline) == ["New"])
        // Already staged: nothing more is downloaded.
        #expect(await Updater.fetchRelease(api: Self.hint, own: "v2026.10.6", skip: t.tag, bundleID: "de.example.takes", into: t.stage, session: UpdateStub.session) == nil)
    }

    /// gettakes.app does not answer: GitHub's latest release is the hint, and the same checks hold.
    @Test func gitHubIsTheHintWhenGettakesIsDown() async throws {
        let t = try Fixture()
        defer { t.done() }
        UpdateStub.set("\(Self.api)/releases/latest", json: ["tag_name": t.tag, "assets": []])
        t.gitHub(digest: "sha256:\(t.sha)")
        #expect(await Updater.fetchRelease(api: Self.hint, own: "v2026.10.6", skip: nil, bundleID: "de.example.takes", into: t.stage, session: UpdateStub.session) == t.tag)
    }

    /// Another file, no digest, a download off GitHub or no answer from api.github.com: no update.
    @Test func aDMGGitHubDoesNotVouchForIsRefused() async throws {
        let t = try Fixture()
        defer { t.done() }
        func attempt() async -> String? {
            await Updater.fetchRelease(api: Self.hint, own: "v2026.10.6", skip: nil, bundleID: "de.example.takes", into: t.stage, session: UpdateStub.session)
        }
        func nothingStaged() -> Bool { !FileManager.default.fileExists(atPath: t.stage.appending(path: "Takes.app").path) }
        UpdateStub.set(Self.hint.absoluteString, json: ["tag_name": t.tag])

        t.gitHub(digest: "sha256:" + SHA256.hash(data: Data("another file".utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(await attempt() == nil)
        #expect(UpdateStub.asked.contains(t.download))
        #expect(nothingStaged())

        UpdateStub.reset(); UpdateStub.set(Self.hint.absoluteString, json: ["tag_name": t.tag])
        t.gitHub(digest: nil)
        #expect(await attempt() == nil)
        #expect(!UpdateStub.asked.contains(t.download))
        #expect(nothingStaged())

        UpdateStub.reset(); UpdateStub.set(Self.hint.absoluteString, json: ["tag_name": t.tag])
        let elsewhere = "https://evil.x.test/marvtub/takes-public/releases/download/\(t.tag)/Takes.dmg"
        t.gitHub(digest: "sha256:\(t.sha)", url: elsewhere)
        UpdateStub.set(elsewhere, data: t.dmgData)
        #expect(await attempt() == nil)
        #expect(!UpdateStub.asked.contains(elsewhere))
        #expect(nothingStaged())

        UpdateStub.reset(); UpdateStub.set(Self.hint.absoluteString, json: ["tag_name": t.tag])
        UpdateStub.set(t.download, data: t.dmgData)   // the file is there, GitHub's API is not
        #expect(await attempt() == nil)
        #expect(!UpdateStub.asked.contains(t.download))
        #expect(nothingStaged())
    }

    /// A real DMG of a Takes at `tag`, its SHA-256, and a stage folder.
    struct Fixture {
        let tag = "v2026.10.7"
        let dir: URL, stage: URL, dmgData: Data, sha: String
        var download: String { "\(UpdaterTests.repo)/\(tag)/Takes.dmg" }

        init() throws {
            UpdateStub.reset()
            let fm = FileManager.default
            dir = fm.temporaryDirectory.appending(path: "takes-updater-\(UUID().uuidString)")
            let app = dir.appending(path: "disk/Takes.app/Contents")
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            let info: NSDictionary = ["ReleaseTag": tag, "CFBundleIdentifier": "de.example.takes", "BuildStamp": "abc Oct 7 10:00"]
            try info.write(to: app.appending(path: "Info.plist"))
            let dmg = dir.appending(path: "Takes.dmg")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["create", "-quiet", "-volname", "Takes", "-srcfolder", dir.appending(path: "disk").path, "-format", "UDZO", dmg.path]
            try p.run(); p.waitUntilExit()
            try #require(p.terminationStatus == 0)
            dmgData = try Data(contentsOf: dmg)
            sha = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
            stage = dir.appending(path: ".update.noindex")
        }

        /// What api.github.com says about the release, and the file at its download.
        func gitHub(digest: String?, url: String? = nil) {
            var asset: [String: Any] = ["name": "Takes.dmg", "browser_download_url": url ?? download]
            if let digest { asset["digest"] = digest }
            UpdateStub.set("\(UpdaterTests.api)/releases/tags/\(tag)", json: ["tag_name": tag, "body": "### Chat\n- New", "assets": [asset]])
            if url == nil { UpdateStub.set(download, data: dmgData) }
        }

        func done() { UpdateStub.reset(); try? FileManager.default.removeItem(at: dir) }
    }
}

/// Answers a session's requests from a table of URL → body; any other URL is a 404. It notes
/// every URL asked for.
final class UpdateStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Data] = [:]
    nonisolated(unsafe) private static var seen: [String] = []

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [UpdateStub.self]
        return URLSession(configuration: c)
    }()

    static func set(_ url: String, data: Data) { lock.withLock { routes[url] = data } }
    static func set(_ url: String, json: Any) { set(url, data: try! JSONSerialization.data(withJSONObject: json)) }
    static func reset() { lock.withLock { routes = [:]; seen = [] } }
    static var asked: [String] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body = Self.lock.withLock { () -> Data? in Self.seen.append(url.absoluteString); return Self.routes[url.absoluteString] }
        let resp = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
