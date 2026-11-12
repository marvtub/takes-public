import Foundation

/// Keeps a search response tied to the controls that produced it. A failed or superseded
/// request must never leave another search's rows on screen.
struct SearchRequest: Hashable {
    var query: String
    var filter: String
    var project: String?
    var sort: String
}

struct SearchRequestState<Value> {
    private(set) var request: SearchRequest?
    private var value: Value?
    private var failed = false

    func value(for request: SearchRequest) -> Value? {
        self.request == request ? value : nil
    }

    func didFail(_ request: SearchRequest) -> Bool {
        self.request == request && failed
    }

    mutating func begin(_ request: SearchRequest) {
        self.request = request
        value = nil
        failed = false
    }

    mutating func succeed(_ value: Value, for request: SearchRequest) {
        guard self.request == request else { return }
        self.value = value
        failed = false
    }

    mutating func fail(_ request: SearchRequest) {
        guard self.request == request else { return }
        value = nil
        failed = true
    }
}
