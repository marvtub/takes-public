import AVFoundation
import Speech
import SwiftUI
import UIKit

// Two ways to record a take on the phone:
// - With the script: the camera, the script at the top of the screen near the lens. The script
//   follows the user's voice, or scrolls at a set number of words per minute.
// - With the Camera app: Apple's own camera, for the best quality. No script.
// Both hand back a file; SessionView sends it to the Mac as the next take.
// The take keeps the orientation the phone had when recording started: portrait or landscape.

@MainActor
final class Camera: NSObject, ObservableObject {
    let session = AVCaptureSession()
    // The take is written from the data outputs (TakeWriter), not a movie file output: the
    // speech recognizer gets the same audio the take gets, and a take can pause (2026-10-03).
    // With a movie file output next to an audio data output, the recognizer got no audio
    // while recording, so voice follow never moved.
    private let videoData = AVCaptureVideoDataOutput()
    private let audioData = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "de.marvinaziz.takes.capture")
    private let writer = TakeWriter()
    let voice = VoiceFollow()
    @Published var recording = false
    @Published private(set) var paused = false
    /// A take stopped and is being written: no new take until it is on screen (2026-11-06: a tap
    /// in that gap started take 2, and take 1 then stopped the camera and was lost).
    @Published private(set) var saving = false
    /// Cancel: the take being saved is deleted when the writer hands it back.
    private var discard = false
    @Published var file: URL?
    @Published var problem: String?
    @Published var front = true
    /// Speech recognition hears the take's audio (voice follow).
    @Published private(set) var listening = false
    /// Recorded time before the current stretch, and when the current stretch began.
    private var before: TimeInterval = 0
    private var since: Date?
    private var input: AVCaptureDeviceInput?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var watch: NSKeyValueObservation?
    private var portrait = true
    weak var preview: AVCaptureVideoPreviewLayer? { didSet { follow() } }

    override init() {
        super.init()
        // A call, Home or a camera error ends the take: save what is there, so it is not lost.
        let c = NotificationCenter.default
        c.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.wasInterruptedNotification, object: session)
        c.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.runtimeErrorNotification, object: session)
        c.addObserver(self, selector: #selector(interrupted), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc nonisolated private func interrupted() {
        Task { @MainActor in if self.recording { self.finish() } }
    }

    /// The take's length so far, without the pauses.
    func elapsed(_ now: Date) -> TimeInterval { before + (since.map { now.timeIntervalSince($0) } ?? 0) }

    func start(listen: Bool) async {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        guard video, audio else {
            problem = "Takes needs the camera and the microphone. Allow them in Settings > Takes."
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        configureCamera()
        if let mic = AVCaptureDevice.default(for: .audio), let i = try? AVCaptureDeviceInput(device: mic), session.canAddInput(i) {
            session.addInput(i)
        }
        videoData.alwaysDiscardsLateVideoFrames = false
        if session.canAddOutput(videoData) { session.addOutput(videoData) }
        if session.canAddOutput(audioData) { session.addOutput(audioData) }
        writer.videoOutput = videoData
        writer.voice = voice
        videoData.setSampleBufferDelegate(writer, queue: queue)
        audioData.setSampleBufferDelegate(writer, queue: queue)
        session.commitConfiguration()
        setListening(listen)
        follow()
        let s = session
        await Task.detached { s.startRunning() }.value
    }

    /// Voice follow on or off. Not while recording.
    func setListening(_ on: Bool) {
        guard !recording else { return }
        listening = on
    }

    private func configureCamera() {
        if let input { session.removeInput(input) }
        let pos: AVCaptureDevice.Position = front ? .front : .back
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
              let i = try? AVCaptureDeviceInput(device: cam), session.canAddInput(i) else { return }
        session.addInput(i)
        input = i
    }

    /// Keeps the preview level with the horizon when the phone turns.
    private func follow() {
        guard let input else { return }
        let r = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: preview)
        rotation = r
        watch = r.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] r, _ in
            let a = r.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                guard let c = self?.preview?.connection, c.isVideoRotationAngleSupported(a) else { return }
                c.videoRotationAngle = a
            }
        }
    }

    func flip() {
        guard !recording else { return }
        front.toggle()
        session.beginConfiguration()
        configureCamera()
        session.commitConfiguration()
        follow()
    }

    func toggle() {
        if recording { finish(); return }
        guard !saving else { return }
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        portrait = Int(angle.rounded()) % 180 == 90
        // The data output turns the pixels themselves, so the file needs no rotation flag.
        if let c = videoData.connection(with: .video) {
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false
            }
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "outbox/take-\(UUID().uuidString).mov")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = nil
        problem = nil
        writer.begin(url, video: videoData.recommendedVideoSettingsForAssetWriter(writingTo: .mov),
                     audio: audioData.recommendedAudioSettingsForAssetWriter(writingTo: .mov), listen: listening)
        if listening { voice.start() }
        recording = true
        paused = false
        before = 0
        since = Date()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Pause and go on: the take keeps one file, without the paused part.
    func setPaused(_ p: Bool) {
        guard recording, p != paused else { return }
        paused = p
        writer.setPaused(p)
        if p {
            before = elapsed(Date())
            since = nil
        } else {
            since = Date()
        }
    }

    /// Stops the take and deletes it, also one still being saved.
    func cancel() {
        discard = true
        if recording { finish() }
    }

    private func finish() {
        voice.stop()
        recording = false
        saving = true
        paused = false
        since = nil
        UIApplication.shared.isIdleTimerDisabled = false
        let portrait = portrait
        #if targetEnvironment(simulator)
        // UI tests: the simulator has no camera, so a test video stands in for the take.
        if let fake = ProcessInfo.processInfo.environment["TAKES_FAKE_TAKE"] {
            let url = FileManager.default.temporaryDirectory.appending(path: "outbox/take-\(UUID().uuidString).mov")
            try? FileManager.default.copyItem(at: URL(filePath: fake), to: url)
            if discard { try? FileManager.default.removeItem(at: url) } else { file = url }
            saving = false
            return
        }
        #endif
        // Home or a call can end the take: iOS gives the save a little time in the background.
        // When that time runs out the app is only suspended: the save goes on when it comes back.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        let background = task
        writer.finish { [weak self] url, error in
            Task { @MainActor in
                defer { UIApplication.shared.endBackgroundTask(background) }
                // No recorder shows this take any more (Cancel, or it closed): delete it.
                guard let self, !self.discard else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                guard let url else { self.problem = error ?? "The take could not be saved."; self.saving = false; return }
                let fixed = await Orientation.fix(url, portrait: portrait)
                if self.discard { try? FileManager.default.removeItem(at: fixed); return }
                self.file = fixed
                self.saving = false
            }
        }
    }

    /// The camera rests while a take plays back, so the take's sound plays from the speaker.
    func rest() {
        let s = session
        Task.detached { s.stopRunning() }
    }

    func wake() {
        let s = session
        Task.detached { s.startRunning() }
    }

    func stop() {
        if recording { finish() }
        voice.stop()
        let s = session
        Task.detached { s.stopRunning() }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

/// Writes a take from the camera's video and audio buffers, and hands the audio to voice follow.
/// Everything here runs on the capture queue.
final class TakeWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    weak var videoOutput: AVCaptureVideoDataOutput?
    weak var voice: VoiceFollow?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var videoSettings: [String: Any]?
    private var audioSettings: [String: Any]?
    private var url: URL?
    private var listen = false
    private var paused = false
    /// After a pause, the next buffer moves the clock back by the gap.
    private var resumed = false
    private var offset = CMTime.zero
    private var last = CMTime.invalid

    private func run(_ f: @escaping () -> Void) {
        guard let q = videoOutput?.sampleBufferCallbackQueue else { f(); return }
        q.async(execute: f)
    }

    func begin(_ url: URL, video: [String: Any]?, audio: [String: Any]?, listen: Bool) {
        run {
            self.url = url
            self.videoSettings = video
            self.audioSettings = audio
            self.listen = listen
            self.writer = nil
            self.video = nil
            self.audio = nil
            self.paused = false
            self.resumed = false
            self.offset = .zero
            self.last = .invalid
        }
    }

    func setPaused(_ p: Bool) {
        run {
            if self.paused && !p { self.resumed = true }
            self.paused = p
        }
    }

    func finish(_ done: @escaping (URL?, String?) -> Void) {
        run {
            let w = self.writer
            self.url = nil
            self.writer = nil
            guard let w, w.status == .writing else {
                // A writer that failed mid take (the app went to the background) left its fragments: keep them.
                if let w, w.status == .failed, let n = try? w.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   n > 0 {
                    done(w.outputURL, nil)
                    return
                }
                if let w { try? FileManager.default.removeItem(at: w.outputURL) }
                done(nil, w?.error?.localizedDescription ?? "Nothing was recorded.")
                return
            }
            self.video?.markAsFinished()
            self.audio?.markAsFinished()
            w.finishWriting {
                done(w.status == .completed ? w.outputURL : nil, w.error?.localizedDescription)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        if !isVideo, listen, !paused, url != nil { voice?.append(buffer) }
        guard let url, !paused else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if writer == nil {
            // The first video frame starts the file: its size fixes the video track.
            guard isVideo, start(url, buffer, pts) else { return }
        }
        guard let writer, writer.status == .writing else { return }
        if resumed {
            resumed = false
            if last.isValid { offset = offset + (pts - last) }
        }
        let input = isVideo ? video : audio
        guard let input, input.isReadyForMoreMediaData, let b = shifted(buffer) else { return }
        if input.append(b) {
            let d = CMSampleBufferGetDuration(buffer)
            let end = d.isValid ? pts + d : pts
            if !last.isValid || end > last { last = end }
        }
    }

    private func start(_ url: URL, _ buffer: CMSampleBuffer, _ pts: CMTime) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        // Fragments every second: when iOS takes the encoder (Home during a take), the file up to the
        // last fragment still plays, so the take is kept (2026-11-06).
        w.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        var vs = videoSettings ?? [AVVideoCodecKey: AVVideoCodecType.hevc]
        vs[AVVideoWidthKey] = Int(size.width)
        vs[AVVideoHeightKey] = Int(size.height)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { return false }
        w.add(v)
        if w.canAdd(a) { w.add(a); audio = a }
        guard w.startWriting() else { return false }
        w.startSession(atSourceTime: pts)
        writer = w
        video = v
        return true
    }

    /// The buffer with the paused time taken out.
    private func shifted(_ b: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset != .zero else { return b }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(b, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(b, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        for i in info.indices {
            info[i].presentationTimeStamp = info[i].presentationTimeStamp - offset
            if info[i].decodeTimeStamp.isValid { info[i].decodeTimeStamp = info[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: b, sampleTimingEntryCount: count,
                                              sampleTimingArray: &info, sampleBufferOut: &out)
        return out
    }
}

/// Makes sure a take plays the way it was held. The camera has written upright pixels together
/// with a rotation flag, which then played the take sideways on the Mac.
enum Orientation {
    typealias InsertTrack = (AVMutableCompositionTrack, CMTimeRange, AVAssetTrack) throws -> Void

    static func fix(
        _ url: URL,
        portrait: Bool,
        insertTrack: InsertTrack = { copy, range, source in
            try copy.insertTimeRange(range, of: source, at: .zero)
        }
    ) async -> URL {
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await video.load(.naturalSize, .preferredTransform) else { return url }
        let shown = size.applying(transform)
        if (abs(shown.height) > abs(shown.width)) == portrait { return url }
        let upright: CGAffineTransform
        if (size.height > size.width) == portrait {
            upright = .identity
        } else if portrait {
            upright = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        } else {
            upright = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        }
        guard let duration = try? await asset.load(.duration),
              let tracks = try? await asset.load(.tracks) else { return url }
        let mediaTracks = tracks.filter { $0.mediaType == .video || $0.mediaType == .audio }
        var expected = OrientationTrackCounts()
        for track in mediaTracks {
            if track.mediaType == .video { expected.video += 1 } else { expected.audio += 1 }
        }
        let comp = AVMutableComposition()
        var inserted = OrientationTrackCounts()
        do {
            for track in mediaTracks {
                guard let copy = comp.addMutableTrack(withMediaType: track.mediaType,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return url }
                try insertTrack(copy, CMTimeRange(start: .zero, duration: duration), track)
                if track.mediaType == .video {
                    copy.preferredTransform = upright
                    inserted.video += 1
                } else {
                    inserted.audio += 1
                }
            }
        } catch {
            return url
        }
        let out = url.deletingLastPathComponent().appending(path: "upright-" + url.lastPathComponent)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return url }
        do {
            try await export.export(to: out, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: out)
            return url
        }
        guard let outputTracks = try? await AVURLAsset(url: out).load(.tracks) else {
            try? FileManager.default.removeItem(at: out)
            return url
        }
        var exported = OrientationTrackCounts()
        for track in outputTracks where track.mediaType == .video || track.mediaType == .audio {
            if track.mediaType == .video { exported.video += 1 } else { exported.audio += 1 }
        }
        guard OrientationTrackCounts.canReplaceOriginal(expected: expected, inserted: inserted, exported: exported) else {
            try? FileManager.default.removeItem(at: out)
            return url
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            try? FileManager.default.removeItem(at: out)
            return url
        }
        return out
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: Camera

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = camera.session
        v.preview.videoGravity = .resizeAspectFill
        camera.preview = v.preview
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}
}

// MARK: - Voice follow

/// On-device speech recognition on the take's own audio (TakeWriter hands it over). Hands each new guess of
/// the spoken words to `heard`.
final class VoiceFollow: NSObject, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    var hints: [String] = []
    var heard: (@MainActor ([String]) -> Void)?

    static func allowed() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    var available: Bool { recognizer?.isAvailable == true }

    func start() {
        lock.lock(); defer { lock.unlock() }
        running = true
        begin()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        running = false
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func begin() {
        task?.cancel()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.taskHint = .dictation
        r.contextualStrings = Array(hints.prefix(100))
        if recognizer?.supportsOnDeviceRecognition == true { r.requiresOnDeviceRecognition = true }
        request = r
        task = recognizer?.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let words = result.bestTranscription.segments.map(\.substring)
                let h = self.heard
                Task { @MainActor in h?(words) }
            }
            // A recognition run ends after a long pause or a time limit: start the next one.
            if error != nil || result?.isFinal == true {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); defer { self.lock.unlock() }
                    if self.running, self.task?.state != .running { self.begin() }
                }
            }
        }
    }

    func append(_ buffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.appendAudioSampleBuffer(buffer)
    }
}

/// Finds where in the script the user is, from the last words the recognizer heard.
struct ScriptFollower {
    let words: [String]
    let ranges: [NSRange]
    /// The next word to say.
    private(set) var next = 0

    init(_ text: String) {
        var w: [String] = [], r: [NSRange] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { s, range, _, _ in
            let n = Self.norm(s ?? "")
            if !n.isEmpty { w.append(n); r.append(range) }
        }
        words = w
        ranges = r
    }

    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a == b || (a.count >= 4 && b.count >= 4 && a.prefix(4) == b.prefix(4))
    }

    mutating func jump(to word: Int) { next = max(0, min(word, words.count)) }

    /// Moves `next` when the spoken words match the script near the current place.
    /// Returns true when it moved.
    @discardableResult
    mutating func hear(_ spoken: [String]) -> Bool {
        let tail = spoken.suffix(6).map(Self.norm).filter { !$0.isEmpty }
        guard let last = tail.last, !words.isEmpty else { return false }
        let lo = max(0, next - 10), hi = min(words.count - 1, next + 30)
        guard lo <= hi else { return false }
        var best: (score: Int, end: Int)?
        for end in lo...hi where Self.same(words[end], last) {
            let window = Array(words[max(0, end - tail.count - 2)...end])
            let s = Self.lcs(tail, window)
            let better = best.map { s > $0.score || (s == $0.score && abs(end - next) < abs($0.end - next)) } ?? true
            if better { best = (s, end) }
        }
        guard let best else { return false }
        let ahead = best.end + 1 - next
        // One matching word is enough close by; going back or far ahead needs more proof.
        let need = ahead < 0 ? 3 : ahead > 6 ? 2 : 1
        guard best.score >= min(need, tail.count), best.end + 1 != next else { return false }
        next = best.end + 1
        return true
    }

    private static func lcs(_ a: [String], _ b: [String]) -> Int {
        var row = Array(repeating: 0, count: b.count + 1)
        for x in a {
            var prev = 0
            for j in b.indices.map({ $0 + 1 }) {
                let keep = row[j]
                row[j] = same(x, b[j - 1]) ? prev + 1 : max(row[j], row[j - 1])
                prev = keep
            }
        }
        return row[b.count]
    }
}

// MARK: - Prompter text

/// The script as a UITextView: shows all of it (no "…"), scrolls by hand, and knows where each
/// word is on screen.
@MainActor
final class PrompterText: NSObject, ObservableObject, UITextViewDelegate {
    let view = UITextView()
    var follower = ScriptFollower("")
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var dragging = false
    private var text = ""
    private var size: CGFloat = 0
    /// Auto scroll: on while recording and not paused.
    var scrolling = false
    var wordsPerMinute = 140.0
    /// Voice follow: drag sets the place to go on from.
    var voiceMode = true
    var tapped: (() -> Void)?

    override init() {
        super.init()
        view.isEditable = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.textContainerInset = UIEdgeInsets(top: 14, left: 20, bottom: 400, right: 20)
        view.delegate = self
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    func stopTimer() { link?.invalidate(); link = nil }

    @objc private func tap() { tapped?() }

    func set(_ script: String, size: CGFloat) {
        guard script != text || size != self.size else { return }
        let keep = follower.next
        text = script
        self.size = size
        follower = ScriptFollower(script)
        follower.jump(to: keep)
        paint()
    }

    /// Said words dim, the rest stay bright.
    private func paint() {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.25
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: style,
        ])
        if voiceMode, follower.next > 0, follower.next <= follower.ranges.count {
            let r = follower.ranges[follower.next - 1]
            s.addAttribute(.foregroundColor, value: UIColor.white.withAlphaComponent(0.45),
                           range: NSRange(location: 0, length: r.location + r.length))
        }
        let offset = view.contentOffset
        view.attributedText = s
        view.contentOffset = offset
    }

    func heard(_ spoken: [String]) {
        guard voiceMode, !dragging, follower.hear(spoken) else { return }
        paint()
        show(word: follower.next)
    }

    /// Puts a word on the second line of the visible text.
    func show(word: Int) {
        guard !follower.ranges.isEmpty else { return }
        let r = follower.ranges[min(word, follower.ranges.count - 1)]
        let glyphs = view.layoutManager.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        let rect = view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
        let y = max(0, rect.minY + view.textContainerInset.top - size * 1.6)
        UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.view.contentOffset.y = y
        }
    }

    func toTop() {
        follower.jump(to: 0)
        paint()
        view.setContentOffset(.zero, animated: true)
    }

    @objc private func tick(_ l: CADisplayLink) {
        defer { last = l.timestamp }
        guard scrolling, !voiceMode, !dragging, last > 0, !follower.words.isEmpty else { return }
        let height = view.contentSize.height - view.textContainerInset.bottom
        let perSecond = height / CGFloat(follower.words.count) * CGFloat(wordsPerMinute / 60)
        let maxY = max(0, height - view.bounds.height * 0.5)
        view.contentOffset.y = min(maxY, view.contentOffset.y + perSecond * CGFloat(l.timestamp - last))
    }

    func scrollViewWillBeginDragging(_ s: UIScrollView) { dragging = true }

    func scrollViewDidEndDragging(_ s: UIScrollView, willDecelerate d: Bool) { if !d { settled() } }

    func scrollViewDidEndDecelerating(_ s: UIScrollView) { settled() }

    /// After a drag, voice follow goes on from the word on the second line.
    private func settled() {
        dragging = false
        guard voiceMode else { return }
        let p = CGPoint(x: 30, y: view.contentOffset.y + view.textContainerInset.top + size * 1.6)
        guard let pos = view.closestPosition(to: p) else { return }
        let at = view.offset(from: view.beginningOfDocument, to: pos)
        follower.jump(to: follower.ranges.firstIndex { $0.location + $0.length > at } ?? follower.ranges.count)
        paint()
    }
}

struct PrompterTextView: UIViewRepresentable {
    let text: PrompterText
    func makeUIView(context: Context) -> UITextView { text.view }
    func updateUIView(_ v: UITextView, context: Context) {}
}

// MARK: - Recorder screen

/// The screen shows only the script, the time and the buttons to record (2026-10-03: less on
/// screen). Scroll mode, speed and text size sit behind the settings button. With no script there
/// is no prompter: only the camera (2026-10-08).
struct PrompterRecorder: View {
    let script: String
    /// Prompts about a take go to this session's chat.
    let sessionID: String
    /// Sends a take to the Mac as the session's next take.
    let send: (URL) -> Bool
    let close: () -> Void
    /// Closes the recorder and opens the chat.
    let toChat: () -> Void
    @StateObject private var camera = Camera()
    @StateObject private var prompter = PrompterText()
    @AppStorage("prompterFollowVoice") private var followVoice = true
    @AppStorage("prompterWPM") private var wpm = 140.0
    @AppStorage("prompterSize") private var size = 26.0
    @State private var note: String?
    @State private var settings = false
    /// The take on screen went to the Mac already.
    @State private var sent = false

    private var hasScript: Bool { !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        GeometryReader { g in
            let landscape = g.size.width > g.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(camera: camera).ignoresSafeArea()
                #if targetEnvironment(simulator)
                if let fake = ProcessInfo.processInfo.environment["TAKES_FAKE_TAKE"] {
                    ClipLoop(url: URL(filePath: fake)).ignoresSafeArea()
                }
                #endif
                if hasScript {
                    island(g, landscape: landscape)
                        .padding(.top, landscape ? 8 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: landscape ? .top : [.top, .horizontal])
                }
                VStack(spacing: 0) {
                    Spacer()
                    controls
                }
                if let file = camera.file, !camera.recording { review(file).transition(.opacity) }
                if let p = camera.problem ?? note {
                    Text(p).padding().background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white).padding()
                        .onTapGesture { camera.problem = nil; note = nil }
                }
            }
            .animation(Brand.spring, value: camera.file)
        }
        .statusBarHidden()
        .sheet(isPresented: $settings) { settingsSheet }
        .task { await setUp() }
        .onDisappear {
            camera.stop()
            prompter.stopTimer()
            // A copy went to the Mac; this one only played here.
            if sent, let f = camera.file { try? FileManager.default.removeItem(at: f) }
        }
        .onChange(of: size) { _, s in prompter.set(script, size: s) }
        .onChange(of: wpm) { _, w in prompter.wordsPerMinute = w }
        .onChange(of: followVoice) { _, on in Task { await setVoice(on) } }
        .onChange(of: camera.recording) { _, on in prompter.scrolling = on && !camera.paused }
        .onChange(of: camera.paused) { _, p in prompter.scrolling = camera.recording && !p }
        .onChange(of: camera.file) { _, f in if f != nil { camera.rest() } }
    }

    /// The script in a black panel that grows out of the Dynamic Island, as the Mac's grows out of
    /// the notch (2026-10-08): the eyes stay next to the lens. The text starts under the island.
    /// Upright it fills the top edge to edge, with no gap beside or above it, and lets the camera
    /// show through a little (2026-10-10, as the Mac's notch since 148d209).
    private func island(_ g: GeometryProxy, landscape: Bool) -> some View {
        let under = landscape ? 10 : max(10, g.safeAreaInsets.top - 14)
        return PrompterTextView(text: prompter)
            // The last line fades out instead of being cut.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .padding(.top, under)
            .padding(.horizontal, landscape ? 0 : 8)
            .frame(width: landscape ? g.size.width * 0.62 : g.size.width + g.safeAreaInsets.leading + g.safeAreaInsets.trailing,
                   height: g.size.height * (landscape ? 0.42 : 0.22) + under)
            .background(.black.opacity(0.82), in: UnevenRoundedRectangle(
                topLeadingRadius: landscape ? 28 : 0, bottomLeadingRadius: 28,
                bottomTrailingRadius: 28, topTrailingRadius: landscape ? 28 : 0, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if !camera.recording {
                    Button { settings = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30).background(.white.opacity(0.14), in: Circle())
                    }
                    .foregroundStyle(.white.opacity(0.85)).padding(10)
                    .accessibilityLabel("Prompter settings")
                }
            }
    }

    private func setUp() async {
        prompter.set(script, size: size)
        prompter.wordsPerMinute = wpm
        // A tap on the script pauses the take and goes on again.
        prompter.tapped = { [weak camera] in
            guard let camera, camera.recording else { return }
            camera.setPaused(!camera.paused)
        }
        camera.voice.hints = Array(Set(prompter.follower.words.filter { $0.count > 3 }))
        camera.voice.heard = { [weak prompter] words in prompter?.heard(words) }
        // No script: nothing to follow, so no speech recognition.
        guard hasScript else { await camera.start(listen: false); return }
        let voice = followVoice ? await VoiceFollow.allowed() : false
        if followVoice && !voice {
            followVoice = false
            note = "Speech recognition is off for Takes. Using auto scroll. Allow it in Settings > Takes."
        }
        prompter.voiceMode = followVoice
        await camera.start(listen: followVoice)
    }

    private func setVoice(_ on: Bool) async {
        if on, !(await VoiceFollow.allowed()) {
            followVoice = false
            note = "Allow speech recognition in Settings > Takes to follow your voice."
            return
        }
        note = nil
        prompter.voiceMode = on
        prompter.set(script, size: size)
        camera.setListening(on)
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Prompter").font(.nunito(size: 22, heavy: true, relativeTo: .title3))
                Spacer()
                Button("Done") { settings = false }.buttonStyle(.pill(small: true))
            }
            Segments(items: [true, false], selection: $followVoice) { $0 ? "Follow my voice" : "Auto scroll" }
            if !followVoice {
                StepRow(label: "\(Int(wpm)) words a minute", value: $wpm, range: 60...240, step: 10)
            }
            StepRow(label: "Text size \(Int(size))", value: $size, range: 16...48, step: 2)
            Button { prompter.toTop(); settings = false } label: { Label("Back to the start", systemImage: "arrow.up.to.line") }
                .buttonStyle(.pill(.soft, small: true))
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Palette.canvas.ignoresSafeArea())
        .presentationDetents([.height(followVoice ? 260 : 320)])
        .presentationCornerRadius(28)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            if camera.recording {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 5) {
                        if camera.paused { Image(systemName: "pause.fill") }
                        Text(Duration.seconds(camera.elapsed(ctx.date)).formatted(.time(pattern: .minuteSecond)))
                    }
                    .font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(camera.paused ? Palette.warn : Palette.danger, in: Capsule())
                }
            }
            HStack {
                Button("Cancel") { camera.cancel(); close() }
                    .font(.inter(.callout, .semibold)).foregroundStyle(.white).frame(width: 80)
                    .buttonStyle(.press)
                Spacer()
                Button { Brand.tap(.medium); camera.toggle() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                        RoundedRectangle(cornerRadius: camera.recording ? 8 : 31, style: .continuous)
                            .fill(Palette.danger).frame(width: camera.recording ? 30 : 62, height: camera.recording ? 30 : 62)
                    }
                    .animation(Brand.spring, value: camera.recording)
                }
                .buttonStyle(Pressable(scale: 0.92, haptic: false))
                .disabled(camera.saving)
                .accessibilityLabel(camera.recording ? "Stop" : "Record")
                Spacer()
                Group {
                    if camera.recording {
                        Button { camera.setPaused(!camera.paused) } label: {
                            Image(systemName: camera.paused ? "play.fill" : "pause.fill").font(.nunito(.title2))
                                .frame(width: 52, height: 52).background(.white.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.press)
                        .accessibilityLabel(camera.paused ? "Go on" : "Pause")
                    } else {
                        Button { camera.flip() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 20, weight: .semibold))
                                .frame(width: 52, height: 52).background(.white.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.press)
                            .accessibilityLabel("Flip camera")
                    }
                }
                .foregroundStyle(.white).frame(width: 80)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 20).padding(.top, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
    }

    /// After a take it plays at once, with sound. The main thing to do is ask Takes about it; a
    /// record button starts the next take; sending it to the Mac is small, at the top (2026-10-08:
    /// "Retake / Send to the Mac" asked for a choice before the user had seen the take).
    private func review(_ file: URL) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ClipLoop(url: file, sound: true, gravity: .resizeAspect).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    if !sent {
                        Button { next(file) } label: {
                            Image(systemName: "trash").font(.system(size: 16, weight: .semibold))
                                .frame(width: 40, height: 40).background(.black.opacity(0.45), in: Circle())
                        }
                        .accessibilityLabel("Delete this take")
                    }
                    Spacer()
                    Button { if keep(file) { close() } } label: {
                        Label(sent ? "Done" : "Send to Mac", systemImage: sent ? "checkmark" : "arrow.up")
                            .font(.inter(.footnote, .semibold))
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                .foregroundStyle(.white).buttonStyle(.press)
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
                QuickSay(sessionID: sessionID, toChat: toChat, from: "Record", placeholder: "Ask Takes about this take…",
                         wrap: { "About the take I just recorded on my phone (the newest take in this session; it may still be uploading): " + $0 },
                         before: { _ = keep(file) })
                    .environment(\.colorScheme, .dark)
                Button { Brand.tap(.medium); if keep(file) { next(file) } } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 58, height: 58)
                        Circle().fill(Palette.danger).frame(width: 46, height: 46)
                    }
                }
                .buttonStyle(Pressable(scale: 0.92, haptic: false))
                .accessibilityLabel("Record another take")
                .padding(.top, 10).padding(.bottom, 12)
            }
        }
    }

    /// Sends the take on screen to the Mac, once. A copy goes (a clone, no extra space): the
    /// outbox moves its file, and this one keeps playing.
    private func keep(_ file: URL) -> Bool {
        guard !sent else { return true }
        let copy = file.deletingLastPathComponent().appending(path: "send-" + file.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        sent = send((try? FileManager.default.copyItem(at: file, to: copy)) != nil ? copy : file)
        if !sent { try? FileManager.default.removeItem(at: copy) }
        return sent
    }

    /// Back to the camera for the next take. A take not sent is deleted.
    private func next(_ file: URL) {
        camera.file = nil
        sent = false
        try? FileManager.default.removeItem(at: file)
        prompter.toTop()
        camera.wake()
    }
}

/// Apple's camera, video only, front camera first.
struct CameraPicker: UIViewControllerRepresentable {
    let done: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.mediaTypes = ["public.movie"]
        if p.sourceType == .camera {
            p.cameraCaptureMode = .video
            p.videoQuality = .typeHigh
            if UIImagePickerController.isCameraDeviceAvailable(.front) { p.cameraDevice = .front }
        }
        p.videoMaximumDuration = 60 * 30
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (URL?) -> Void
        init(done: @escaping (URL?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let url = info[.mediaURL] as? URL else { done(nil); return }
            let keep = FileManager.default.temporaryDirectory.appending(path: "outbox/take-\(UUID().uuidString).\(url.pathExtension)")
            try? FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            done((try? FileManager.default.moveItem(at: url, to: keep)) != nil ? keep : url)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// A label with − and + on the right, in place of a grey Stepper.
struct StepRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack {
            Text(label).font(.inter(.callout, .medium)).monospacedDigit()
            Spacer()
            HStack(spacing: 0) {
                button("minus", value - step >= range.lowerBound) { value = max(range.lowerBound, value - step) }
                Rectangle().fill(Palette.border).frame(width: 1, height: 18)
                button("plus", value + step <= range.upperBound) { value = min(range.upperBound, value + step) }
            }
            .background(Palette.well, in: Capsule())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func button(_ icon: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Brand.select(); action() } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                .frame(width: 44, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.9, haptic: false))
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }
}
