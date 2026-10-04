import AVFoundation
import Speech
import SwiftUI

// Voice notes in the chat box (2026-10-02). Talk, and the words come into the box while you
// speak. On the Mac only, in English: no audio leaves it.
//
// macOS 26: SpeechAnalyzer. It works with Siri and Dictation turned off; the old recognizer
// does not: it failed at once ("Siri and Dictation are disabled") while the bars still moved,
// and the words were lost (2026-10-03). Older macOS: the old recognizer.

@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var active = false
    /// The words so far. Empty again after cancel.
    @Published private(set) var text = ""
    @Published private(set) var started: Date?
    @Published var problem: String?
    /// The level bars: their own object, so 20 updates a second redraw the bars, not the chat.
    let meter = VoiceMeter()

    private let engine = AVAudioEngine()
    /// Bumped on each start and cancel: a late answer from an old run is dropped.
    private var run = 0
    /// Feeds audio to the recognizer and ends it.
    private var listener: Listener?

    func start() async {
        guard !active else { return }
        problem = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            problem = "Takes needs the microphone: System Settings › Privacy & Security › Microphone."
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { problem = "No microphone found."; return }

        run += 1
        let mine = run
        let heard: @MainActor (String?, String?) -> Void = { [weak self] words, failure in
            guard let self, self.run == mine else { return }
            if let words { self.text = words }
            if let failure, self.text.isEmpty {
                self.problem = "Takes couldn't hear words: \(failure)"
                self.cancel()
            }
        }
        let made: Listener?
        if #available(macOS 26, *) {
            made = await AnalyzerListener.make(input: format, heard: heard, problem: { [weak self] in self?.problem = $0 })
        } else {
            made = await RecognizerListener.make(heard: heard, problem: { [weak self] in self?.problem = $0 })
        }
        guard let listener = made, run == mine else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(listener.feed, meter))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            listener.cancel()
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        self.listener = listener
        text = ""
        meter.reset()
        started = Date()
        active = true
    }

    // The audio calls back on its own thread. Built outside the main actor, so Swift does not
    // expect this closure to run on it.
    nonisolated private static func tap(_ feed: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                                        _ meter: VoiceMeter) -> AVAudioNodeTapBlock {
        var tick = 0
        return { buffer, _ in
            feed(buffer)
            tick += 1
            guard tick % 2 == 0 else { return }  // ~20 bar updates a second is smooth enough
            let level = level(buffer)
            Task { @MainActor in meter.push(level) }
        }
    }

    /// Stops listening and waits for the last words.
    func stop() async {
        guard active else { return }
        endAudio()
        let l = listener
        listener = nil
        await l?.finish()
    }

    /// Stops and throws the words away.
    func cancel() {
        guard active || listener != nil else { return }
        run += 1
        endAudio()
        listener?.cancel()
        listener = nil
        text = ""
    }

    private func endAudio() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        active = false
        started = nil
    }

    /// Loudness of one buffer, 0...1 (-50 dB to -8 dB).
    nonisolated private static func level(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return CGFloat(min(max((db + 50) / 42, 0), 1))
    }
}

/// One way to turn audio into words.
@MainActor
private protocol Listener: AnyObject {
    /// Called on the audio thread.
    var feed: @Sendable (AVAudioPCMBuffer) -> Void { get }
    /// No more audio: wait for the last words.
    func finish() async
    func cancel()
}

/// macOS 26: SpeechAnalyzer, live words as you speak.
@available(macOS 26, *)
@MainActor
private final class AnalyzerListener: Listener {
    let feed: @Sendable (AVAudioPCMBuffer) -> Void
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<Void, Never>

    private init(feed: @escaping @Sendable (AVAudioPCMBuffer) -> Void, analyzer: SpeechAnalyzer,
                 input: AsyncStream<AnalyzerInput>.Continuation, results: Task<Void, Never>) {
        self.feed = feed; self.analyzer = analyzer; self.input = input; self.results = results
    }

    static func make(input format: AVAudioFormat, heard: @escaping @MainActor (String?, String?) -> Void,
                     problem: @escaping @MainActor (String) -> Void) async -> AnalyzerListener? {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        do {
            // The English model, once (a download the first time).
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
        } catch {
            problem("Couldn't get the speech model: \(error.localizedDescription)")
            return nil
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: format, to: target) else {
            problem("Speech recognition can't read this microphone.")
            return nil
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            problem("Couldn't start speech recognition: \(error.localizedDescription)")
            return nil
        }
        let results = Task { @MainActor in
            var done = "", now = ""
            do {
                for try await r in transcriber.results {
                    let words = String(r.text.characters)
                    if r.isFinal { done += words; now = "" } else { now = words }
                    heard((done + now).trimmingCharacters(in: .whitespaces), nil)
                }
            } catch {
                heard(nil, error.localizedDescription)
            }
        }
        let feed = Self.converting(converter, to: target, into: cont)
        return AnalyzerListener(feed: feed, analyzer: analyzer, input: cont, results: results)
    }

    nonisolated private static func converting(_ converter: AVAudioConverter, to target: AVAudioFormat,
                                               into cont: AsyncStream<AnalyzerInput>.Continuation)
        -> @Sendable (AVAudioPCMBuffer) -> Void {
        nonisolated(unsafe) let converter = converter
        return { buffer in
            let ratio = target.sampleRate / buffer.format.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            nonisolated(unsafe) var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
        }
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results.value
    }

    func cancel() {
        input.finish()
        results.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Older macOS: SFSpeechRecognizer. Needs Siri and Dictation turned on.
@MainActor
private final class RecognizerListener: Listener {
    let feed: @Sendable (AVAudioPCMBuffer) -> Void
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private var done = false

    private init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
        nonisolated(unsafe) let r = request
        feed = { r.append($0) }
    }

    static func make(heard: @escaping @MainActor (String?, String?) -> Void,
                     problem: @escaping @MainActor (String) -> Void) async -> RecognizerListener? {
        let allowed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard allowed else {
            problem("Takes needs speech recognition: System Settings › Privacy & Security.")
            return nil
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            problem("Speech recognition isn't available right now.")
            return nil
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let me = RecognizerListener(request: request)
        me.task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak me] words, failure, final in
            if final || failure != nil { me?.done = true }
            heard(words, failure)
        })
        return me
    }

    nonisolated private static func handler(_ then: @escaping @MainActor (String?, String?, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in then(words.flatMap { $0.isEmpty ? nil : $0 }, failure, final) }
        }
    }

    func finish() async {
        request.endAudio()
        for _ in 0..<15 where !done { try? await Task.sleep(for: .milliseconds(100)) }
        task?.cancel()
    }

    func cancel() { task?.cancel() }
}

@MainActor
final class VoiceMeter: ObservableObject {
    static let count = 26
    @Published private(set) var levels = Array(repeating: CGFloat(0), count: VoiceMeter.count)

    func push(_ level: CGFloat) {
        // One change per buffer, not two (removeFirst and append each redrew the bars).
        var next = levels
        next.removeFirst()
        next.append(level)
        levels = next
    }

    func reset() { levels = Array(repeating: 0, count: Self.count) }
}

/// The voice note while you talk: a red dot, bars that follow your voice (newest on the right),
/// the time, and a tick to finish.
struct VoiceNote: View {
    @ObservedObject var dictation: Dictation
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel the voice note (Esc)")
            LayerPulse(color: Theme.danger, low: 0.35, duration: 0.7).frame(width: 7, height: 7)
            VoiceBars(meter: dictation.meter).frame(minWidth: 36, maxWidth: 84).frame(height: 20)
            if let started = dictation.started {
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(started)))
                    Text("\(s / 60):\(String(format: "%02d", s % 60))")
                        .font(Theme.sans(11.5, .medium)).monospacedDigit().foregroundStyle(Theme.muted)
                }
            }
            Button(action: done) {
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Theme.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help("Done: keep the words in the box")
        }
        .padding(.leading, 4).padding(.trailing, 3).padding(.vertical, 3)
        .background(Theme.accentSoft, in: Capsule())
        .transition(.scale(scale: 0.85, anchor: .trailing).combined(with: .opacity))
    }
}

private struct VoiceBars: View {
    @ObservedObject var meter: VoiceMeter

    var body: some View {
        GeometryReader { g in
            let n = CGFloat(VoiceMeter.count)
            let w = g.size.width / n
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(meter.levels.enumerated()), id: \.offset) { i, level in
                    // Older bars fade a little, so the sound reads as moving left.
                    Capsule()
                        .fill(Theme.accent.opacity(0.45 + 0.55 * Double(i) / Double(n)))
                        .frame(width: max(2, w * 0.55), height: max(3, g.size.height * level))
                        .frame(width: w)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.09), value: meter.levels)
        }
    }
}

/// The small "what should change?" box (comment feedback, decline notes, storyboard notes), in the
/// chat box's style: type or talk, Return sends, Shift-Return a new line, Esc cancels.
struct AskBox: View {
    @Environment(AppModel.self) private var app
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    /// No send: the box only holds a note that another button uses.
    var send: (() -> Void)?
    let cancel: () -> Void
    /// Take the keyboard when the box opens, so typed or pasted words (Handy) land here.
    var autofocus = true
    /// False for a box that is always there (a storyboard shot's note): Esc still clears it.
    var cancellable = true
    /// One row, like a message field: the words and the send arrow, no Voice button (a storyboard
    /// shot's note, 2026-10-04: the two-row box with a Voice pill looked sloppy there).
    var inline = false
    @StateObject private var dictation = Dictation()
    /// What was in the box before the voice note: the spoken words go after it.
    @State private var before = ""

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // The words get the full width; the buttons sit on a row under them, so a narrow box
    // (a storyboard shot) never squeezes the text into one letter a line (2026-10-03).
    var body: some View {
        Group { if inline { inlineBody } else { boxBody } }
            .animation(Theme.motion, value: focus.wrappedValue)
            .animation(Theme.spring, value: dictation.active)
            .onChange(of: dictation.text) { _, words in text = before + words }
            .onChange(of: dictation.problem) { _, why in if let why { app.show(toast: why) } }
            .onDisappear { dictation.cancel() }
            // Ask again once the box is in the window: a request made while it is still being
            // inserted can fail, and the words then go nowhere (2026-10-03).
            .onAppear {
                guard autofocus else { return }
                focus.wrappedValue = true
                DispatchQueue.main.async { focus.wrappedValue = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focus.wrappedValue = true }
            }
    }

    private var field: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.sans(13))
            .lineLimit(1...8)
            .focused(focus)
            .onSubmit(submit)
            .onKeyPress(.escape) {
                if dictation.active { dictation.cancel() } else { cancel() }
                return .handled
            }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift),
                      let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                editor.insertNewlineIgnoringFieldEditor(nil)
                return .handled
            }
    }

    private var inlineBody: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if dictation.active {
                VoiceNote(dictation: dictation, done: { Task { await dictation.stop() } },
                          cancel: { dictation.cancel() })
                    .frame(minHeight: 28)
                Spacer(minLength: 0)
            } else {
                field.padding(.vertical, 5)
                Button(action: listen) {
                    Image(systemName: "mic").font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(Theme.muted)
                .disabled(app.isRecording)
                .help(app.isRecording ? "Not while recording a take" : "Voice note: talk, and the words come into the box")
            }
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSend || dictation.active ? Theme.paper : Theme.faint)
                    .frame(width: 28, height: 28)
                    .background(canSend || dictation.active ? Theme.ink : Theme.hover, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .disabled(!canSend && !dictation.active)
            .help("Send (Return)")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .strokeBorder(dictation.active ? Theme.accent.opacity(0.6) : focus.wrappedValue ? Theme.accent.opacity(0.5) : Theme.border,
                          lineWidth: focus.wrappedValue || dictation.active ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture { focus.wrappedValue = true }
    }

    private var boxBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            field
                .padding(.horizontal, 4).padding(.top, 4)
            HStack(spacing: 4) {
                if dictation.active {
                    VoiceNote(dictation: dictation, done: { Task { await dictation.stop() } },
                              cancel: { dictation.cancel() })
                } else {
                    Button(action: listen) {
                        Label("Voice", systemImage: "mic").font(Theme.sans(12, .medium))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(Theme.hover, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .foregroundStyle(Theme.muted)
                    .disabled(app.isRecording)
                    .help(app.isRecording ? "Not while recording a take" : "Voice note: talk, and the words come into the box")
                    .transition(.opacity)
                }
                Spacer(minLength: 4)
                if !dictation.active && cancellable {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.plain).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .help("Cancel (Esc)")
                }
                if send != nil {
                    Button(action: submit) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.paper)
                            .frame(width: 26, height: 26)
                            .background(canSend || dictation.active ? Theme.ink : Theme.border, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!canSend && !dictation.active)
                    .help("Send (Return)")
                }
            }
        }
        .padding(8)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(dictation.active ? Theme.accent.opacity(0.6) : focus.wrappedValue ? Theme.muted.opacity(0.5) : Theme.border,
                          lineWidth: dictation.active ? 1 : 0.5))
    }

    private func listen() {
        let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
        before = kept.isEmpty ? "" : kept + " "
        focus.wrappedValue = true
        Task { await dictation.start() }
    }

    /// Return or the arrow. During a voice note: wait for the last words, then send.
    private func submit() {
        guard let send else { return }
        guard dictation.active else { if canSend { send() }; return }
        Task {
            await dictation.stop()
            if canSend { send() } else { app.show(toast: "No words came through. Talk again or type.") }
        }
    }
}
