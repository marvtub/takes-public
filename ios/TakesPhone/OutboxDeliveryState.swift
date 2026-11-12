import Foundation

/// One delivery lane for changes sent at once and changes already in the outbox.
struct OutboxDeliveryState {
    enum Active: Equatable {
        case immediate(UUID)
        case flush
    }

    private(set) var active: Active?

    mutating func begin(_ next: Active) -> Bool {
        guard active == nil else { return false }
        active = next
        return true
    }

    mutating func finish(_ current: Active) {
        precondition(active == current)
        active = nil
    }
}
