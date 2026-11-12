import Foundation

/// Writes a changed queue before exposing it to the rest of the app.
enum OutboxStore {
    static func write<Value: Encodable>(_ value: Value, to file: URL,
                                         options: Data.WritingOptions = .atomic) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: options)
    }

    static func change<Value>(_ current: inout Value, persist: (Value) throws -> Void,
                              _ edit: (inout Value) -> Void) throws {
        var next = current
        edit(&next)
        try persist(next)
        current = next
    }
}

/// Keeps optimistic controls honest when their outbox write fails.
enum OutboxAcknowledgement {
    struct Reply: Equatable {
        var draft: String
        var editing: Bool
        var accepted: Bool
    }

    static func reply(sent: Bool, draft: String) -> Reply {
        sent ? Reply(draft: "", editing: false, accepted: true)
             : Reply(draft: draft, editing: true, accepted: false)
    }

    static func keeper(sent: Bool, previous: Bool, optimistic: Bool) -> Bool {
        sent ? optimistic : previous
    }

    static func dismissRecording(kept: Bool) -> Bool { kept }
}

/// Recorder files nobody shows any more: a take that Cancel or a closed recorder left in
/// tmp/outbox, or its upright copy. The outbox keeps its takes in its own folder (Outbox.dir), and
/// background uploads name theirs "<uuid>-<name>", so no queued change points at these.
enum RecorderLeftovers {
    static func remove(in dir: URL, now: Date = Date(), olderThan age: TimeInterval = 24 * 3600) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? [] {
            let name = f.lastPathComponent
            guard name.hasPrefix("take-") || name.hasPrefix("upright-"),
                  let changed = try? f.resourceValues(forKeys: keys).contentModificationDate,
                  now.timeIntervalSince(changed) > age else { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }
}
