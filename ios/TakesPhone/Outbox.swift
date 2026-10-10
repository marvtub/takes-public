import Foundation
import SwiftUI
import UIKit

// Offline (2026-10-03). Every change the user makes on the phone goes out through here. With the
// Mac reachable it goes at once; without it, it waits in a list on the phone (Application
// Support, so iOS never clears it) and goes out in order as soon as the Mac answers again.
// Screens show waiting changes as if they were done (Model.patch). A take waits as a file next
// to the list and uploads in the background once the Mac is back; it is deleted only after the
// Mac has it.

@MainActor
final class Outbox: ObservableObject {
    struct Op: Codable, Identifiable, Hashable {
        enum Kind: String, Codable { case newSession, script, post, postDraft, scriptDraft, comment, reply, resolve, keeper, cover, decide, say, take, archive, side }
        var id = UUID()
        var kind: Kind
        /// The session id, or the suggestion id for a decision.
        var session: String
        var path: String
        var query: [String: String] = [:]
        var method = "POST"
        var body: Data?
        /// A take: its file in Outbox.files, and the name the Mac gets.
        var file: String?
        var name: String?
        var created = Date()
        /// The Mac answered but said no (for example the script changed there meanwhile).
        /// It waits for the user: send again or drop.
        var refused: String?

        init(_ kind: Kind, session: String, path: String, query: [String: String] = [:], method: String = "POST", json: [String: Any]? = nil) {
            self.kind = kind
            self.session = session
            self.path = path
            self.query = query
            self.method = method
            body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        }

        var json: [String: Any] { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
        func string(_ k: String) -> String? { json[k] as? String }

        /// What the list of waiting changes calls it.
        var label: String {
            switch kind {
            case .newSession: return "New video"
            case .script: return "Script edit"
            case .post: return "Post edit"
            case .postDraft: return string("action") == "save" ? "Post version edit" : "Post version change"
            case .scriptDraft: return string("action") == "save" ? "Script version edit" : "Script version change"
            case .comment: return "Comment: \(string("text") ?? "")"
            case .reply: return "Reply: \(string("text") ?? "")"
            case .resolve: return string("resolved") == "true" ? "Comment resolved" : "Comment reopened"
            case .keeper: return "Keeper take"
            case .cover: return "Cover picture"
            case .decide: return "Comment draft: \(string("action") ?? "")"
            case .say: return "Message: \(string("text") ?? "")"
            case .take: return "Take \(name ?? "")"
            case .archive: return query["on"] == "0" ? "Unarchive" : "Archive"
            case .side: return string("status").map { $0 == "posted" ? "Post marked posted" : "Post back to draft" } ?? "Post edit"
            }
        }
    }

    enum Sent { case now(Data), queued(Op) }

    @Published private(set) var ops: [Op] = []
    /// Goes up when changes reached the Mac: screens reload.
    @Published private(set) var delivered = 0
    weak var model: Model?
    private var flushing = false
    /// False until the app knows which takes the background session still sends.
    private var ready = false
    /// Takes the background session is sending right now.
    private var uploading: Set<UUID> = []

    static let dir = URL.applicationSupportDirectory.appending(path: "outbox")
    static let files = dir.appending(path: "files")
    private static var list: URL { dir.appending(path: "ops.json") }

    var waiting: [Op] { ops.filter { $0.refused == nil } }
    var refused: [Op] { ops.filter { $0.refused != nil } }
    func ops(_ kind: Op.Kind, in session: String) -> [Op] { ops.filter { $0.kind == kind && $0.session == session } }

    init() {
        if let d = try? Data(contentsOf: Self.list), let o = try? JSONDecoder().decode([Op].self, from: d) { ops = o }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        // Readable after the first unlock, so a take can go on uploading while the phone is locked.
        try? JSONEncoder().encode(ops).write(to: Self.list, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Sends now when it can. Queues it when the Mac is away, or when older changes still wait
    /// (they go first). Throws only when the Mac answered no while online, as before.
    func send(_ op: Op) async throws -> Sent {
        guard let model else { throw URLError(.notConnectedToInternet) }
        var op = op
        op.session = model.resolve(op.session)
        // A take uploads on its own: edits do not wait behind it. A video the Mac has not made
        // yet takes everything in it into the queue.
        if model.connected && !op.session.hasPrefix("phone/") && !waiting.contains(where: { $0.kind != .take }) {
            do {
                return .now(try await model.api.raw(request(op), session: Self.session))
            } catch let e as APIError {
                throw e
            } catch {
                model.connected = false
            }
        }
        ops.append(op)
        save()
        if model.connected { Task { await flush() } }
        return .queued(op)
    }

    func add(_ op: Op) {
        ops.append(op)
        save()
        Task { await flush() }
    }

    /// A take, or a file for the session: kept on the phone until the Mac has it.
    func take(_ file: URL, name: String, session: String, asTake: Bool, shot: String?) {
        try? FileManager.default.createDirectory(at: Self.files, withIntermediateDirectories: true)
        let keep = UUID().uuidString + "-" + name
        let to = Self.files.appending(path: keep)
        do {
            if file.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try FileManager.default.moveItem(at: file, to: to)
            } else {
                try FileManager.default.copyItem(at: file, to: to)
            }
        } catch {
            model?.error = "Could not keep \(name) on the phone."
            return
        }
        let session = model?.resolve(session) ?? session
        var q = ["session": session, "name": name]
        if asTake { q["as"] = "take" }
        if let shot { q["shot"] = shot }
        var op = Op(.take, session: session, path: "/api/upload", query: q, method: "PUT")
        op.file = keep
        op.name = name
        ops.append(op)
        save()
        Task { await flush() }
    }

    /// Short: a change should not hang for long when the Mac is asleep. It waits instead.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        return URLSession(configuration: c)
    }()

    func request(_ op: Op) -> URLRequest {
        var r = model!.api.request(op.path, op.query, method: op.method)
        if let b = op.body {
            r.httpBody = b
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// Sends what waits, oldest first. Stops at the first change the Mac can't be reached for.
    func flush() async {
        guard let model, ready, !flushing, !ops.isEmpty, model.phase == .open, model.api.token != nil else { return }
        flushing = true
        defer { flushing = false }
        var sent = false
        for id in ops.map(\.id) {
            // Read it again: making a video earlier in the loop changes the session of the rest.
            guard let op = ops.first(where: { $0.id == id }), op.refused == nil else { continue }
            if op.kind == .take {
                if !op.session.hasPrefix("phone/"), !uploading.contains(op.id), let file = op.file {
                    uploading.insert(op.id)
                    model.uploads.start(op, file: Self.files.appending(path: file))
                }
                continue
            }
            if op.session.hasPrefix("phone/") && op.kind != .newSession { continue }
            do {
                let data = try await model.api.raw(request(op), session: Self.session)
                if op.kind == .newSession {
                    let s = try API.decoder.decode(Session.self, from: data)
                    rename(op.session, to: s.id)
                    model.adopt(op.session, as: s)
                }
                ops.removeAll { $0.id == op.id }
                sent = true
            } catch let e as APIError {
                if e.status == 401 { break }
                mark(op.id, refused: e.message)
            } catch {
                model.connected = false
                break
            }
        }
        save()
        if sent {
            model.connected = true
            delivered += 1
        }
    }

    /// Points every waiting change of a phone-made video at the session the Mac made.
    private func rename(_ local: String, to real: String) {
        for i in ops.indices where ops[i].session == local && ops[i].kind != .newSession {
            ops[i].session = real
            for k in ["id", "session"] where ops[i].query[k] == local { ops[i].query[k] = real }
        }
    }

    /// The background session finished a take.
    func uploaded(_ id: UUID, status: Int, error: String?) {
        uploading.remove(id)
        if status == 200 {
            if let op = ops.first(where: { $0.id == id }), let f = op.file {
                try? FileManager.default.removeItem(at: Self.files.appending(path: f))
            }
            ops.removeAll { $0.id == id }
            delivered += 1
        } else if status >= 400 && status != 401 {
            mark(id, refused: error ?? "The Mac answered \(status)")
        }
        // No answer at all: the take stays and goes again with the next flush.
        save()
    }

    /// Takes the background session still sends after a relaunch.
    func inFlight(_ ids: [UUID]) {
        uploading.formUnion(ids)
        ready = true
        Task { await flush() }
    }

    private func mark(_ id: UUID, refused: String) {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        ops[i].refused = refused
    }

    /// Send a refused change again. A text edit goes over the Mac's newer text: The user chose it.
    func retry(_ op: Op) async {
        guard let model, let i = ops.firstIndex(where: { $0.id == op.id }) else { return }
        var o = ops[i]
        if [.script, .post, .postDraft, .side].contains(o.kind), o.string("base") != nil,
           let d = try? await model.api.detail(o.session) {
            var j = o.json
            switch o.kind {
            case .script: j["base"] = d.script
            case .post: j["base"] = d.post?.text ?? ""
            case .side:
                let p = d.sides?.first { $0.file == o.string("file") }
                j["base"] = (o.string("title") != nil ? p?.title : p?.text) ?? j["base"]
            default: j["base"] = d.post?.variants?.first { $0.slug == o.string("slug") }?.text ?? j["base"]
            }
            o.body = try? JSONSerialization.data(withJSONObject: j)
        }
        o.refused = nil
        ops[i] = o
        save()
        await flush()
    }

    func drop(_ op: Op) {
        if let f = op.file { try? FileManager.default.removeItem(at: Self.files.appending(path: f)) }
        ops.removeAll { $0.id == op.id }
        save()
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.dir)
        ops = []
    }
}

// MARK: - The bar and the list

/// A quiet row at the sidebar's foot, only when something waits for the Mac or the Mac said no.
/// Offline alone shows nothing here: the grey dot by the brand says it (2026-10-04: the old
/// banner was "pretty ugly and takes up too much attention").
struct OutboxBar: View {
    @ObservedObject var outbox: Outbox
    @State private var showing = false

    var body: some View {
        let n = outbox.waiting.count, bad = outbox.refused.count
        if n + bad > 0 {
            Button { Brand.select(); showing = true } label: {
                HStack(spacing: 11) {
                    Image(systemName: bad > 0 ? "exclamationmark.circle" : "arrow.up.circle")
                        .font(.system(size: 15)).foregroundStyle(bad > 0 ? Palette.warn : Palette.faint).frame(width: 20)
                    Text(line(n, bad)).font(.inter(.subheadline)).foregroundStyle(bad > 0 ? Palette.warn : Palette.muted).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
            .sheet(isPresented: $showing) { OutboxSheet(outbox: outbox) { showing = false } }
        }
    }

    private func line(_ n: Int, _ bad: Int) -> String {
        if bad > 0 { return bad == 1 ? "1 change needs you" : "\(bad) changes need you" }
        return n == 1 ? "1 change waits for the Mac" : "\(n) changes wait for the Mac"
    }
}

/// What waits on the phone, in the sidebar's own rows.
struct OutboxSheet: View {
    @ObservedObject var outbox: Outbox
    let close: () -> Void

    var body: some View {
        BrandSheet(title: "On the phone", cancel: "Done", close: close) {
            Button("Send now") { Task { await outbox.flush() } }
                .buttonStyle(.pill(.quiet, small: true))
                .disabled(outbox.waiting.isEmpty && outbox.refused.isEmpty)
        } content: {
            if !outbox.refused.isEmpty {
                label("The Mac said no")
                ForEach(outbox.refused) { op in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(op.label).font(.inter(.subheadline, .medium)).foregroundStyle(Palette.ink).lineLimit(2)
                        Text(op.refused ?? "").font(.inter(.footnote)).foregroundStyle(Palette.warn)
                        HStack(spacing: 8) {
                            Button(op.string("base") != nil ? "Use mine" : "Send again") { Task { await outbox.retry(op) } }
                                .buttonStyle(.pill(.quiet, small: true))
                            if let t = op.string("text") {
                                Button("Copy") { UIPasteboard.general.string = t }.buttonStyle(.pill(.quiet, small: true))
                            }
                            Spacer()
                            Button("Drop") { outbox.drop(op) }
                                .font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger)
                        }
                    }
                    .padding(12)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
                }
                Text("Use mine puts your text over the Mac's newer text. The Mac keeps the old one in its history.")
                    .font(.inter(.caption)).foregroundStyle(Palette.faint)
            }
            label("Waiting for the Mac")
            if outbox.waiting.isEmpty {
                Text("Nothing waits.").font(.inter(.subheadline)).foregroundStyle(Palette.faint)
            }
            VStack(spacing: 1) {
                ForEach(outbox.waiting) { op in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(op.label).font(.inter(.subheadline)).foregroundStyle(Palette.ink).lineLimit(2)
                            Text(op.created.formatted(date: .abbreviated, time: .shortened))
                                .font(.inter(.caption)).foregroundStyle(Palette.faint)
                        }
                        Spacer()
                        Button { outbox.drop(op) } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
                                .frame(width: 32, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Drop")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.inter(.footnote, .medium)).foregroundStyle(Palette.faint).padding(.top, 4)
    }
}
