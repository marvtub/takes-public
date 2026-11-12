import Darwin
import Foundation
import QuartzCore

/// For benches: samples the main thread's stack every few ms from another thread, with the time
/// of each sample, so a freeze can be named by what ran in it (`sample` gives no times and, while
/// it runs, makes every framework load wait). Bench code only: it suspends the main thread for a
/// moment per sample and walks its frame pointers into a buffer made beforehand (no allocation
/// while the thread is stopped).
final class MainSampler: @unchecked Sendable {
    private let thread: thread_t
    private let stackTop: UInt
    private let stackBottom: UInt
    private let maxSamples = 4000, maxDepth = 96
    private let pcs: UnsafeMutablePointer<UInt>
    private let depths: UnsafeMutablePointer<Int>
    private let times: UnsafeMutablePointer<Double>
    private var count = 0
    private var stop = false
    private let lock = NSLock()
    let t0: Double

    /// Call on the main thread.
    init(t0: Double) {
        self.t0 = t0
        thread = mach_thread_self()
        let me = pthread_self()
        stackTop = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackBottom = stackTop - UInt(pthread_get_stacksize_np(me))
        pcs = .allocate(capacity: maxSamples * maxDepth)
        depths = .allocate(capacity: maxSamples)
        times = .allocate(capacity: maxSamples)
    }

    func start(every ms: Double = 5) {
        let t = Thread { [self] in
            while !lock.withLock({ stop }) && count < maxSamples {
                take()
                Thread.sleep(forTimeInterval: ms / 1000)
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }

    func finish() { lock.withLock { stop = true } }

    private func take() {
        guard thread_suspend(thread) == KERN_SUCCESS else { return }
        var state = arm_thread_state64_t()
        var n = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let ok = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(n)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &n) }
        } == KERN_SUCCESS
        let base = pcs + count * maxDepth
        var d = 0
        if ok {
            base[d] = UInt(state.__pc) & 0x0000_FFFF_FFFF_FFFF; d += 1
            base[d] = UInt(state.__lr) & 0x0000_FFFF_FFFF_FFFF; d += 1
            var fp = UInt(state.__fp)
            while d < maxDepth, fp >= stackBottom, fp + 16 <= stackTop, fp % 8 == 0 {
                let frame = UnsafePointer<UInt>(bitPattern: fp)!
                let lr = frame[1] & 0x0000_FFFF_FFFF_FFFF
                if lr == 0 { break }
                base[d] = lr; d += 1
                let next = frame[0]
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(thread)
        depths[count] = d
        times[count] = CACurrentMediaTime() - t0
        count += 1
    }

    /// The samples from `from` to `to` (seconds after t0), as their most common frames: "name: n".
    /// `skip` drops frames whose name contains any of these (run loop and SwiftUI plumbing).
    func top(from: Double, to: Double, limit: Int = 12, skip: [String] = []) -> [String] {
        var names: [UInt: String] = [:]
        func name(_ pc: UInt) -> String {
            if let n = names[pc] { return n }
            var info = Dl_info()
            var s = "?"
            if dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0, let c = info.dli_sname {
                s = String(cString: c)
                if let d = demangle(s) { s = d }
                let lib = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "" } ?? ""
                s = "\(s.prefix(110)) [\(lib)]"
            }
            names[pc] = s
            return s
        }
        var counts: [String: Int] = [:]
        var n = 0
        for i in 0..<count where times[i] >= from && times[i] < to {
            n += 1
            var seen = Set<String>()
            for k in 0..<depths[i] {
                let s = name(pcs[i * maxDepth + k])
                if skip.contains(where: { s.contains($0) }) || !seen.insert(s).inserted { continue }
                counts[s, default: 0] += 1
            }
        }
        return ["\(n) samples"] + counts.sorted { $0.value > $1.value }.prefix(limit).map { "\($0.value) \($0.key)" }
    }

    private func demangle(_ s: String) -> String? {
        typealias F = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let h = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        let f = unsafeBitCast(h, to: F.self)
        guard let r = s.withCString({ f($0, strlen($0), nil, nil, 0) }) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}
