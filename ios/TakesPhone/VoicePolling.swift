import Foundation

/// Polls Clean Voice without starting another request after its sheet closes.
@MainActor
enum VoicePolling {
    static func run(
        while isRunning: () -> Bool,
        delay: () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
        load: () async throws -> Void
    ) async rethrows {
        while !Task.isCancelled && isRunning() {
            try await delay()
            guard !Task.isCancelled else { return }
            try await load()
        }
    }
}
