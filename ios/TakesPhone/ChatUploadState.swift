/// Chat files stay with their draft while another session is on screen.
struct ChatUploadState {
    private var owners: [Int: String] = [:]
    private var waitingBySession: [String: Set<Int>] = [:]
    private var attachedBySession: [String: [String]] = [:]

    func waiting(in session: String) -> Set<Int> { waitingBySession[session] ?? [] }
    func attachments(in session: String) -> [String] { attachedBySession[session] ?? [] }

    mutating func begin(_ id: Int, in session: String) {
        owners[id] = session
        waitingBySession[session, default: []].insert(id)
    }

    /// Returns false when the upload was already sent with its message or completed before.
    @discardableResult
    mutating func complete(_ id: Int, path: String) -> Bool {
        guard let session = owners.removeValue(forKey: id),
              waitingBySession[session]?.remove(id) != nil else { return false }
        if waitingBySession[session]?.isEmpty == true { waitingBySession[session] = nil }
        attachedBySession[session, default: []].append(path)
        return true
    }

    mutating func remove(_ path: String, from session: String) {
        attachedBySession[session]?.removeAll { $0 == path }
        if attachedBySession[session]?.isEmpty == true { attachedBySession[session] = nil }
    }

    /// Clears one draft and returns the uploads that should follow its message when they finish.
    mutating func sent(in session: String) -> Set<Int> {
        let waiting = waitingBySession.removeValue(forKey: session) ?? []
        for id in waiting { owners[id] = nil }
        attachedBySession[session] = nil
        return waiting
    }
}
