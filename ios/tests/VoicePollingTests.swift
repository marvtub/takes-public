import Foundation

// Runs without UIKit: swiftc TakesPhone/VoicePolling.swift tests/VoicePollingTests.swift.
@main
@MainActor
struct VoicePollingTests {
    final class Probe {
        var checks = 0
        var loads = 0

        func isRunning() -> Bool {
            checks += 1
            return checks <= 3
        }
    }

    static func main() async {
        let probe = Probe()
        let polling = Task {
            try? await VoicePolling.run(
                while: probe.isRunning,
                delay: { try await Task.sleep(for: .seconds(60)) },
                load: { probe.loads += 1 }
            )
        }

        while probe.checks == 0 { await Task.yield() }
        polling.cancel()
        await polling.value

        precondition(probe.loads == 0, "Cancelling polling must not load again")
        print("Voice polling: cancellation stopped all further loads")
    }
}
