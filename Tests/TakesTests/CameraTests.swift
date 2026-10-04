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
