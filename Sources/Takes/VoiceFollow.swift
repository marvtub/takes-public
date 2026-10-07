import AVFoundation
import Speech

extension Notification.Name {
    /// Voice follow found a new place in the script: every prompter that follows moves to it.
    static let takesFollowMoved = Notification.Name("takesFollowMoved")
}

/// Voice follow (2026-10-07): while the prompter plays, Takes listens and keeps your place in the
/// script. One listener for the whole app: the prompter, the notch and the prompter window all
/// read `next`. It hears the Mac's default microphone, on the Mac, in the script's language.
@MainActor
@Observable
final class VoiceFollow {
    /// The next word to say: an index into `ScriptFollower(text).words`.
    private(set) var next = 0
    private(set) var listening = false
    /// Voice follow can't run now (no permission, no model for the language). The prompters
    /// scroll at the set speed instead.
    private(set) var failed = false
    /// The language it listens in ("German").
    private(set) var language: String?
    /// The script as the prompters show it.
    @ObservationIgnored var source: () -> String = { "" }
    @ObservationIgnored var problem: (String) -> Void = { _ in }

    @ObservationIgnored private var follower = ScriptFollower("")
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var listener: Listener?
    @ObservationIgnored private let feed = FeedBox()
    /// Bumped on each start and stop: a late answer from an old run is dropped.
    @ObservationIgnored private var run = 0
    /// Bumped on each restart of the listener: a cancelled one's last call does nothing.
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var restarts: [Date] = []

    func start() {
        guard !wanted else { return }
        wanted = true
        failed = false
        run += 1
        let mine = run
        Task { await begin(mine) }
    }

    func stop() {
        guard wanted || engine != nil else { return }
        wanted = false
        run += 1
        feed.set(nil)
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        listener?.cancel()
        listener = nil
        listening = false
    }

    /// A hand scroll or "back to top": go on from this word.
    func jump(to word: Int) {
        sync()
        follower.jump(to: word)
        guard follower.next != next else { return }
        next = follower.next
        NotificationCenter.default.post(name: .takesFollowMoved, object: nil)
    }

    // MARK: Listening

    private func begin(_ mine: Int) async {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return fail(mine, "Voice follow needs the microphone: System Settings › Privacy & Security › Microphone.")
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return fail(mine, "Voice follow found no microphone.") }
        guard let locale = await Self.locale(for: source()) else {
            let code = ScriptLanguage.code(of: source()) ?? "en"
            return fail(mine, "Voice follow can't hear \(ScriptLanguage.name(code)) on this Mac yet. The script scrolls at the set speed.")
        }
        if #available(macOS 26, *), !(await SpeechTranscriber.installedLocales).contains(where: { $0.identifier == locale.identifier }) {
            // The first time in a language, macOS downloads its model: say why nothing moves yet.
            problem("Getting the \(ScriptLanguage.name(locale.language.languageCode?.identifier ?? "")) speech model. Voice follow starts in a moment.")
        }
        guard let made = await listen(mine, locale: locale, format: format) else { return }
        guard run == mine, wanted else { made.cancel(); return }
        feed.set(made.feed)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(feed))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            made.cancel()
            return fail(mine, "Voice follow couldn't start the microphone: \(error.localizedDescription)")
        }
        self.engine = engine
        listener = made
        language = Locale(identifier: "en").localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "")
        listening = true
    }

    private func listen(_ mine: Int, locale: Locale, format: AVAudioFormat) async -> Listener? {
        let hints = Self.hints(source())
        gen += 1
        let myGen = gen
        let heard: @MainActor (String?, String?) -> Void = { [weak self] words, failure in
            guard let self, self.run == mine, self.gen == myGen else { return }
            if let words { self.heard(words) }
            // The old recognizer ends a run after a pause or about a minute; a new one goes on.
            let ended = failure != nil || (self.listener as? RecognizerListener)?.done == true
            if ended { self.relisten(mine, locale: locale, format: format) }
        }
        let report: @MainActor (String) -> Void = { [weak self] why in
            guard let self, self.gen == myGen else { return }
            self.fail(mine, why)
        }
        if #available(macOS 26, *) {
            return await AnalyzerListener.make(input: format, locale: locale, hints: hints, heard: heard, problem: report)
        }
        return await RecognizerListener.make(locale: locale, hints: hints, heard: heard, problem: report)
    }

    private func relisten(_ mine: Int, locale: Locale, format: AVAudioFormat) {
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 20 } + [now]
        // A recognizer that fails at once would restart forever: three times in 20 seconds is enough.
        guard restarts.count <= 3 else { return fail(mine, "Voice follow stopped hearing words. The script scrolls at the set speed.") }
        gen += 1
        listener?.cancel()
        listener = nil
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard run == mine, wanted, let made = await listen(mine, locale: locale, format: format) else { return }
            guard run == mine, wanted else { made.cancel(); return }
            listener = made
            feed.set(made.feed)
        }
    }

    private func fail(_ mine: Int, _ why: String) {
        guard run == mine else { return }
        stop()
        failed = true
        problem(why)
    }

    private func heard(_ words: String) {
        sync()
        let tail = ScriptFollower.tokens(String(words.suffix(200)))
        guard follower.hear(tail) else { return }
        next = follower.next
        NotificationCenter.default.post(name: .takesFollowMoved, object: nil)
    }

    /// The script changed (an edit, another variant): keep the place.
    private func sync() {
        let text = source()
        guard text != follower.text else { return }
        let keep = follower.next
        follower = ScriptFollower(text)
        follower.jump(to: keep)
        next = follower.next
    }

    // MARK: Helpers

    static func locale(for script: String) async -> Locale? {
        let code = ScriptLanguage.code(of: script) ?? Locale.current.language.languageCode?.identifier ?? "en"
        let preferred = [Locale.current] + Locale.preferredLanguages.map { Locale(identifier: $0) }
        if #available(macOS 26, *) {
            return ScriptLanguage.pick(code, from: await SpeechTranscriber.supportedLocales, preferred: preferred)
        }
        return ScriptLanguage.pick(code, from: Array(SFSpeechRecognizer.supportedLocales()), preferred: preferred)
    }

    /// Names and long words from the script, so the recognizer expects them.
    static func hints(_ script: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        script.enumerateSubstrings(in: script.startIndex..., options: .byWords) { w, _, _, _ in
            guard let w, w.count >= 7 || (w.first?.isUppercase == true && w.count >= 3),
                  seen.insert(w.lowercased()).inserted else { return }
            out.append(w)
        }
        return Array(out.prefix(100))
    }

    // The audio calls back on its own thread. Built outside the main actor, so Swift does not
    // expect this closure to run on it.
    nonisolated private static func tap(_ feed: FeedBox) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.send(buffer) }
    }
}

/// Where the audio thread sends each buffer: the listener of the moment (it changes on a restart).
final class FeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var feed: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func set(_ f: (@Sendable (AVAudioPCMBuffer) -> Void)?) { lock.lock(); feed = f; lock.unlock() }

    func send(_ b: AVAudioPCMBuffer) {
        lock.lock(); let f = feed; lock.unlock()
        f?(b)
    }
}
