import Foundation

// Runs without UIKit:
// swiftc TakesPhone/LatestRefresh.swift tests/LatestRefreshTests.swift -o /tmp/latest-refresh-tests

private actor FakeAPI {
    private var waiters: [Int: CheckedContinuation<Int, Never>] = [:]

    func value(for request: Int) async -> Int {
        await withCheckedContinuation { waiters[request] = $0 }
    }

    func waiting(for request: Int) -> Bool { waiters[request] != nil }

    func finish(_ request: Int, with value: Int) {
        waiters.removeValue(forKey: request)?.resume(returning: value)
    }
}

enum Cache {
    private static let lock = NSLock()
    private static var values: [Int] = []

    static func save<T: Encodable>(_ value: T, _ key: String) {}

    static func saveData(_ data: Data, _ key: String) {
        lock.lock()
        values.append(Int(data.first!))
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        values = []
        lock.unlock()
    }

    static var saved: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
private final class Loader {
    private var refreshes = LatestRefresh()
    private(set) var value: Int?
    private let key: String

    init(key: String = "screen") { self.key = key }

    func load(_ request: Int, from api: FakeAPI) async {
        let generation = refreshes.begin()
        let fresh = await api.value(for: request)
        guard refreshes.accepts(generation) else { return }
        value = fresh
        await CacheWrites.shared.saveData(Data([UInt8(fresh)]), key, generation: generation)
    }
}

private struct Prefetcher {
    func load(_ request: Int, from api: FakeAPI) async {
        let generation = CacheWrites.begin()
        let fresh = await api.value(for: request)
        await CacheWrites.shared.saveData(Data([UInt8(fresh)]), "session-prefetch", generation: generation)
    }
}

private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        precondition(Date() < deadline, "Timed out waiting for asynchronous test state")
        await Task.yield()
    }
}

@main
struct LatestRefreshTests {
    static func main() async {
        generationsIncreaseAcrossRefreshOwners()
        await olderResponseCannotReplaceNewerStateOrCache()
        await olderPrefetchCannotReplaceNewerScreenCache()
        await outOfOrderOlderCacheWriteIsRejected()
        print("Latest refresh: all checks passed")
    }

    private static func generationsIncreaseAcrossRefreshOwners() {
        var first = LatestRefresh()
        var second = LatestRefresh()
        let earlier = first.begin()
        precondition(second.begin() > earlier, "A recreated screen reused an older generation")
    }

    @MainActor
    private static func olderResponseCannotReplaceNewerStateOrCache() async {
        Cache.reset()
        let api = FakeAPI()
        let loader = Loader()
        let old = Task { await loader.load(1, from: api) }
        await waitUntil { await api.waiting(for: 1) }
        let new = Task { await loader.load(2, from: api) }
        await waitUntil { await api.waiting(for: 2) }

        await api.finish(2, with: 2)
        await new.value
        await api.finish(1, with: 1)
        await old.value

        precondition(loader.value == 2, "The older response replaced the current screen")
        precondition(Cache.saved == [2], "The older response replaced the current cache")
    }

    @MainActor
    private static func olderPrefetchCannotReplaceNewerScreenCache() async {
        Cache.reset()
        let api = FakeAPI()
        let prefetch = Task { await Prefetcher().load(1, from: api) }
        await waitUntil { await api.waiting(for: 1) }
        let loader = Loader(key: "session-prefetch")
        let screen = Task { await loader.load(2, from: api) }
        await waitUntil { await api.waiting(for: 2) }

        await api.finish(2, with: 2)
        await screen.value
        await api.finish(1, with: 1)
        await prefetch.value

        precondition(Cache.saved == [2], "An older prefetch replaced the newer screen cache")
    }

    private static func outOfOrderOlderCacheWriteIsRejected() async {
        Cache.reset()
        await CacheWrites.shared.saveData(Data([2]), "out-of-order", generation: 2)
        await CacheWrites.shared.saveData(Data([1]), "out-of-order", generation: 1)

        precondition(Cache.saved == [2], "An older actor job replaced the newer cache")
    }
}
