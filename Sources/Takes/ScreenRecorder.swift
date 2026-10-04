import AppKit
import ScreenCaptureKit

/// One display into its own .mov (HEVC, 60fps, cursor on, mic included for waveform sync).
/// The Takes window itself is excluded, so the script never shows up in the screen file.
final class ScreenRecorder: NSObject, ObservableObject, SCStreamDelegate, SCRecordingOutputDelegate {
    struct Display: Identifiable, Hashable { let id: CGDirectDisplayID; let name: String }

    @Published var displays: [Display] = []
    @Published var displayID: CGDirectDisplayID? {
        didSet { UserDefaults.standard.set(displayID.map { Int($0) }, forKey: "display") }
    }

    private var stream: SCStream?
    private var startCont: CheckedContinuation<Date, Error>?
    private var stopCont: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    override init() {
        super.init()
        let saved = UserDefaults.standard.integer(forKey: "display")
        displayID = saved == 0 ? nil : CGDirectDisplayID(saved)
    }

    @MainActor
    func refreshDisplays() {
        let found = NSScreen.screens.compactMap { s -> Display? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: CGDirectDisplayID(n.uint32Value), name: s.localizedName)
        }
        // Runs on every ⌘-Tab back: an equal list must not redraw the stage.
        if found != displays { displays = found }
        if !displays.contains(where: { $0.id == displayID }) { displayID = displays.first?.id }
    }

    func startRecording(to url: URL, micID: String?) async throws -> Date {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
        else { throw RecorderError("No display found.") }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = false
        if let micID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = micID
        }

        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mov
        rc.videoCodecType = .hevc
        let recording = SCRecordingOutput(configuration: rc, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(recording)
        self.stream = stream
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { startCont = cont }
            stream.startCapture { [weak self] error in
                if let error { self?.resumeStart(.failure(error)); return }
                // Safety net in case the recording callback never arrives.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self?.resumeStart(.success(Date())) }
            }
        }
    }

    func stopRecording() async {
        guard let stream else { return }
        await withCheckedContinuation { cont in
            lock.withLock { stopCont = cont }
            stream.stopCapture { [weak self] error in
                if error != nil { self?.resumeStop(); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { self?.resumeStop() }
            }
        }
        self.stream = nil
    }

    /// Gives up on a start that has not begun yet (Record pressed again while "Starting…").
    func cancelStart() { resumeStart(.failure(CancellationError())) }

    private func resumeStart(_ r: Result<Date, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<Date, Error>? in defer { startCont = nil }; return startCont }
        c?.resume(with: r)
    }

    private func resumeStop() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { stopCont = nil }; return stopCont }
        c?.resume()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { resumeStart(.success(Date())) }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { resumeStop() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        resumeStart(.failure(error)); resumeStop()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        resumeStart(.failure(error)); resumeStop()
    }
}
