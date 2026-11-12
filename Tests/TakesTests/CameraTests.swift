import AVFoundation
import Testing
@testable import Takes

// The camera writes HEVC at a set bitrate (CameraRecorder.swift).
struct CameraBitrateTests {
    @Test func bitrateScalesWithPixels() {
        #expect(CameraRecorder.bitrate(CMVideoDimensions(width: 1080, height: 1920)) == 20_000_000)
        #expect(CameraRecorder.bitrate(CMVideoDimensions(width: 1920, height: 1080)) == 20_000_000)
        #expect(CameraRecorder.bitrate(CMVideoDimensions(width: 3840, height: 2160)) == 80_000_000)
    }
}

// Looking for cameras loads AVFoundation's device plugins: 120–230 ms on the main thread, the
// second freeze after each launch (2026-11-06). The look runs on its own queue now.
@MainActor
struct CameraDiscoveryTests {
    @Test func devicesAreFoundOffTheMainThread() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var onMain: [Bool] = []
        let old = CameraRecorder.look
        defer { CameraRecorder.look = old }
        CameraRecorder.look = {
            lock.withLock { onMain.append(Thread.isMainThread) }
            return CameraRecorder.Devices(defaultVideo: "fake-camera", defaultAudio: "fake-mic")
        }
        let camera = CameraRecorder()
        camera.refreshDevices()
        // Wait for the state, not for a time.
        for _ in 0..<500 where camera.videoID == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(camera.videoID == "fake-camera")
        #expect(!lock.withLock { onMain }.isEmpty)
        #expect(lock.withLock { onMain }.allSatisfy { !$0 })
    }
}
