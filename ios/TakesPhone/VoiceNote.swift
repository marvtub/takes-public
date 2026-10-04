import AVFoundation
import Speech
import SwiftUI

/// Dictation for the chat (the same as Hive's composer): records from the microphone, shows how loud it is as a row of
/// bars, and hands back what was said as text. Agents read text, not audio, so the words go
/// into the message box for the user to check before sending.
@MainActor @Observable
final class VoiceNote {
    init() {}

    static let barCount = 26

    private(set) var recording = false
    private(set) var started: Date?
    /// The newest last, each 0...1.
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: VoiceNote.barCount)
    var error: String?

    private var capture: Capture?
    private var transcript = ""
    private var finished = false
    private var waiting: CheckedContinuation<Void, Never>?

    func start() async {
        guard !recording else { return }
        error = nil
        guard await Self.allowed() else {
            error = "Allow the microphone and speech recognition for Takes in Settings to record voice notes."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            error = "Speech recognition isn't available right now."
            return
        }
        transcript = ""
        finished = false
        levels = Array(repeating: 0, count: Self.barCount)
        let capture = Capture()
        do {
            try capture.start(recognizer: recognizer,
                              level: { [weak self] level in Task { @MainActor in self?.push(level) } },
                              heard: { [weak self] text, final in Task { @MainActor in self?.heard(text, final: final) } })
        } catch {
            capture.stop()
            self.error = "Couldn't start recording: \(error.localizedDescription)"
            return
        }
        self.capture = capture
        recording = true
        started = Date()
    }

    /// Stops recording and returns what was said, waiting briefly for the final words.
    func stop() async -> String {
        guard recording, let capture else { return "" }
        recording = false
        started = nil
        capture.finish()
        if !finished {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiting = c
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    self.resume()
                }
            }
        }
        capture.stop()
        self.capture = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops and throws the recording away.
    func cancel() {
        capture?.stop()
        capture = nil
        recording = false
        started = nil
        transcript = ""
    }

    private func push(_ level: CGFloat) {
        guard recording else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func heard(_ text: String, final: Bool) {
        if !text.isEmpty { transcript = text }
        if final {
            finished = true
            resume()
        }
    }

    private func resume() {
        waiting?.resume()
        waiting = nil
    }

    static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}

/// The audio side, which runs on the audio thread: the engine, the tap, and the recognizer.
private final class Capture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(recognizer: SFSpeechRecognizer,
               level: @escaping @Sendable (CGFloat) -> Void,
               heard: @escaping @Sendable (String, Bool) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { result, error in
            heard(result?.bestTranscription.formattedString ?? "", result?.isFinal == true || error != nil)
        }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
            level(Capture.loudness(buffer))
        }
        engine.prepare()
        try engine.start()
    }

    /// No more audio; the recognizer finishes what it heard.
    func finish() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }

    func stop() {
        if engine.isRunning { finish() }
        task?.cancel()
        task = nil
        request = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Speech sits roughly between -50 and -10 dB; map that onto 0...1.
    static func loudness(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 0.000_01))
        return CGFloat(min(max((db + 50) / 40, 0), 1))
    }
}

/// The recording indicator: rounded bars in the text colour, newest on the right.
struct VoiceBars: View {
    var levels: [CGFloat]
    init(levels: [CGFloat]) { self.levels = levels }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: 4 + 18 * levels[i])
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityLabel("Recording")
    }
}
