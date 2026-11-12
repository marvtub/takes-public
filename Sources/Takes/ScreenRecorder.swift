import AppKit
import ScreenCaptureKit

/// One display into its own .mov (HEVC, 60fps, mic included for waveform sync). The pointer is left
/// out and drawn back from the cursor log (CursorLog.swift) when the arrow can be drawn, else kept in.
/// The Takes window itself is excluded, so the script never shows up in the screen file.
final class ScreenRecorder: NSObject, ObservableObject, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput {
    struct Display: Identifiable, Hashable { let id: CGDirectDisplayID; let name: String }
    /// One app window to record instead of a whole display (the screen pill, 2026-10-14).
    struct Window: Identifiable, Hashable { let id: CGWindowID; let app: String; let title: String }

    @Published var displays: [Display] = []
    @Published var displayID: CGDirectDisplayID? {
        didSet { UserDefaults.standard.set(displayID.map { Int($0) }, forKey: "display") }
    }

    /// The windows you can pick, newest list from `refreshWindows`.
    @Published var windows: [Window] = []
    /// Record this window alone; nil records the display. Not saved: windows come and go.
    @Published var windowID: CGWindowID?

    private var stream: SCStream?
    private var startCont: CheckedContinuation<Date, Error>?
    private var stopCont: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    /// The cursor log of the take being recorded (CursorLog.swift).
    private var cursor: CursorLog?
    /// The take being recorded notes shortcuts (the pill's ⌨, KeyLog.swift).
    @Published var keysLive = false
    private let frames = DispatchQueue(label: "takes.screen.frames", qos: .utility)

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

    /// The app windows on screen, for the pill's menu. Takes' own windows are left out.
    @MainActor
    func refreshWindows() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let found = Self.pickable(content.windows).map {
            Window(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "", title: $0.title ?? "")
        }
        if found != windows { windows = found }
        if let w = windowID, !found.contains(where: { $0.id == w }) { windowID = nil }
    }

    /// Normal windows of other apps, big enough to show, with a name to pick them by.
    static func pickable(_ all: [SCWindow]) -> [SCWindow] {
        all.filter { w in
            w.windowLayer == 0 && w.frame.width >= 200 && w.frame.height >= 150
                && w.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                && !(w.owningApplication?.applicationName ?? "").isEmpty
        }
    }

    func startRecording(to url: URL, micID: String?) async throws -> Date {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let area: CGRect, picked: CGWindowID?
        if let id = windowID, let window = content.windows.first(where: { $0.windowID == id }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            area = window.frame; picked = id
        } else {
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
            else { throw RecorderError("No display found.") }
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            area = CGDisplayBounds(display.displayID); picked = nil
        }

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // 2026-10-30: Takes draws the pointer from the cursor log (render_edit, the stage), so the
        // video leaves it out. No arrow to draw it with: the video keeps it, as before.
        let (arrow, keys) = await MainActor.run { (CursorLog.arrow(), KeyLog.on && KeyLog.allowed) }
        config.showsCursor = arrow == nil
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
        // 2026-10-30: the cursor log. The frames come here too, only for the first one's time: the
        // .mov starts at that frame, so the log's clock does too.
        let map = CursorMap(area: area, mainHeight: Double(CGDisplayBounds(CGMainDisplayID()).height),
                            size: CGSize(width: config.width, height: config.height))
        let log = CursorLog(video: url, map: map, source: picked == nil ? "display" : "window",
                            scale: Double(scale), fps: 60, windowID: picked, arrow: arrow, keys: keys)
        log.onKeys = { [weak self] on in self?.keysLive = on }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
        lock.withLock { cursor = log }
        log.start()
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
        let log = lock.withLock { () -> CursorLog? in defer { cursor = nil }; return cursor }
        log?.finish()
        await MainActor.run { keysLive = false }
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

    /// Only the first complete frame matters: its time is 0 in the .mov and in the cursor log.
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let log = lock.withLock({ cursor }) else { return }
        guard let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        log.frame(at: CMSampleBufferGetPresentationTimeStamp(sb).seconds)
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
