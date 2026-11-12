import Foundation

private final class RefreshGenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt = 0

    func next() -> UInt {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

/// Keeps an older request from replacing a newer screen snapshot.
struct LatestRefresh {
    private var generation: UInt = 0

    mutating func begin() -> UInt {
        generation = CacheWrites.begin()
        return generation
    }

    func accepts(_ request: UInt) -> Bool { request == generation }
}

/// Rejects an older accepted response when actor jobs reach the cache out of order.
actor CacheWrites {
    static let shared = CacheWrites()
    private static let counter = RefreshGenerationCounter()
    private var generations: [String: UInt] = [:]

    /// Reserve the write's place before its request starts, not when its response arrives.
    static func begin() -> UInt { counter.next() }

    func save<T: Encodable>(_ value: T, _ key: String, generation: UInt) {
        guard accepts(generation, for: key) else { return }
        Cache.save(value, key)
    }

    func saveData(_ data: Data, _ key: String, generation: UInt) {
        guard accepts(generation, for: key) else { return }
        Cache.saveData(data, key)
    }

    private func accepts(_ generation: UInt, for key: String) -> Bool {
        guard generation >= generations[key, default: 0] else { return false }
        generations[key] = generation
        return true
    }
}
