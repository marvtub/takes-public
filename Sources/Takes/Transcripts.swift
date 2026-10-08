import AVFoundation
import Foundation
import Speech

// Every take gets a transcript with word times (2026-10-08). On the Mac only: Apple's speech model
// (SpeechAnalyzer, macOS 26), no key and no upload. It sits next to the video as
// <stem>.words.json, the same file the MCP server, ⌘K search, get_comments and fix_words read:
//
//   {"words": [{"word": "Hello", "start": 0.42, "end": 0.71}, ...], "source": "apple en_US"}
//
// A new take is transcribed when it is saved. After launch, and every 10 minutes, a sweep finds
// older takes without one, newest session first. Nothing runs while a take records.

struct Word: Codable, Equatable {
    var word: String
    var start: Double
    var end: Double
}

enum Transcript {
    static let suffix = ".words.json"

    /// <stem>.words.json next to the video.
    static func file(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("words.json")
    }

    static func exists(for video: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(for: video).path)
    }

    /// The words of a video, from its .words.json (ours, Whisper's or ElevenLabs'). Nil = none yet.
    static func words(for video: URL) -> [Word]? {
        guard let data = try? Data(contentsOf: file(for: video)),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var raw: [Any] = []
        if let d = json as? [String: Any] {
            raw = d["words"] as? [Any] ?? []
            for seg in d["segments"] as? [[String: Any]] ?? [] { raw += seg["words"] as? [Any] ?? [] }
        } else if let l = json as? [Any] {
            raw = l
        }
        return raw.compactMap { w in
            if let d = w as? [String: Any] {
                let t = ((d["word"] ?? d["text"]) as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, let s = (d["start"] as? NSNumber)?.doubleValue else { return nil }
                return Word(word: t, start: s, end: (d["end"] as? NSNumber)?.doubleValue ?? s)
            }
            if let l = w as? [Any], l.count >= 2, let t = l[0] as? String, let s = (l[1] as? NSNumber)?.doubleValue {
                return Word(word: t, start: s, end: (l.count > 2 ? (l[2] as? NSNumber)?.doubleValue : nil) ?? s)
            }
            return nil
        }
    }

    static func text(for video: URL) -> String? {
        words(for: video).map { $0.map(\.word).joined(separator: " ") }
    }

    static func write(_ words: [Word], source: String, for video: URL) throws {
        struct Doc: Encodable { var words: [Word]; var source: String }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(Doc(words: words.map { Word(word: $0.word, start: round3($0.start), end: round3($0.end)) },
                         source: source)).write(to: file(for: video), options: .atomic)
    }

    private static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// Speech runs into words: a run that does not start with a space goes on the word before it.
    /// A run with several words shares its time between them.
    static func words(from runs: [(text: String, start: Double, end: Double)]) -> [Word] {
        var out: [Word] = []
        var open = false  // the last word may still grow
        for r in runs {
            let parts = r.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !parts.isEmpty else { open = false; continue }
            let joins = open && !(r.text.first?.isWhitespace ?? true)
            let step = (r.end - r.start) / Double(parts.count)
            for (i, p) in parts.enumerated() {
                let s = r.start + step * Double(i), e = r.start + step * Double(i + 1)
                if i == 0 && joins, var last = out.popLast() {
                    last.word += p; last.end = e; out.append(last)
                } else {
                    out.append(Word(word: p, start: s, end: e))
                }
            }
            open = !(r.text.last?.isWhitespace ?? true)
        }
        return out
    }
}

@MainActor
@Observable
final class Transcripts {
    static let shared = Transcripts()

    /// Bumped each time a transcript is written, so rows that show one read it again.
    private(set) var version = 0
    /// The video being transcribed now.
    private(set) var current: URL?
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var failed: Set<URL> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored var root: () -> URL? = { nil }
    @ObservationIgnored var paused: () -> Bool = { false }

    /// The Mac can transcribe (macOS 26).
    static var supported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    func start(root: @escaping () -> URL?, paused: @escaping () -> Bool) {
        guard !started, Self.supported else { return }
        started = true
        self.root = root
        self.paused = paused
        Task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await sweep()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func waiting(_ video: URL) -> Bool {
        let v = video.standardizedFileURL
        return current == v || queue.contains(v)
    }

    /// A new take: before the old ones.
    func add(_ video: URL) {
        guard Self.supported else { return }
        let v = video.standardizedFileURL
        guard current != v, !Transcript.exists(for: v) else { return }
        queue.removeAll { $0 == v }
        queue.insert(v, at: 0)
        failed.remove(v)
        run()
    }

    /// Takes with no transcript, newest session first. Camera files carry the voice; a screen file
    /// only when its take has no camera file.
    func sweep() async {
        guard let root = root() else { return }
        let found = await Task.detached(priority: .utility) { Self.missing(in: root) }.value
        for v in found where !queue.contains(v) && current != v && !failed.contains(v) { queue.append(v) }
        run()
    }

    nonisolated static func missing(in root: URL) -> [URL] {
        let fm = FileManager.default
        var sessions: [(URL, Date)] = []
        for p in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where !p.lastPathComponent.hasPrefix("_") && !p.lastPathComponent.hasPrefix(".") {
            for s in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil)) ?? [] {
                if let meta = Store.readMeta(s) { sessions.append((s, meta.createdAt)) }
            }
        }
        var out: [URL] = []
        for (s, _) in sessions.sorted(by: { $0.1 > $1.1 }) {
            guard let meta = Store.readMeta(s) else { continue }
            for t in voiceTakes(meta.takes).sorted(by: { $0.number > $1.number }) {
                let v = s.appending(path: t.file).standardizedFileURL
                if fm.fileExists(atPath: v.path), !Transcript.exists(for: v) { out.append(v) }
            }
        }
        return out
    }

    /// One file per take: the camera file, or the screen file of a screen-only take.
    nonisolated static func voiceTakes(_ takes: [Take]) -> [Take] {
        Dictionary(grouping: takes, by: \.number).values.compactMap { g in
            g.first { $0.kind == .camera } ?? g.first
        }
    }

    private func run() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.nextItem() {
                if self.paused() {
                    self.queue.insert(next, at: 0)
                    try? await Task.sleep(for: .seconds(15))
                    continue
                }
                self.current = next
                let ok = await Self.transcribe(next)
                self.current = nil
                if ok { self.version += 1 } else { self.failed.insert(next) }
            }
            self?.worker = nil
        }
    }

    private func nextItem() -> URL? {
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if FileManager.default.fileExists(atPath: v.path), !Transcript.exists(for: v) { return v }
        }
        return nil
    }

    /// Transcribes one video and writes its .words.json. The language comes from the session's
    /// script; names in the script help the model spell them.
    static func transcribe(_ video: URL) async -> Bool {
        guard #available(macOS 26, *) else { return false }
        let script = (try? String(contentsOf: video.deletingLastPathComponent().appending(path: "script.md"), encoding: .utf8)) ?? ""
        var found = await VoiceFollow.locale(for: script)
        if found == nil { found = await VoiceFollow.locale(for: "") }
        guard let locale = found else { return false }
        do {
            let words = try await SpeechFile.words(of: video, locale: locale, hints: VoiceFollow.hints(script))
            // Renamed or trashed while it ran: the next sweep finds it under its new name.
            guard FileManager.default.fileExists(atPath: video.path) else { return true }
            try Transcript.write(words, source: "apple \(locale.identifier)", for: video)
            return true
        } catch {
            NSLog("Takes transcript failed for \(video.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}

/// A whole file through SpeechAnalyzer, with the time of each word.
@available(macOS 26, *)
enum SpeechFile {
    static func words(of video: URL, locale: Locale, hints: [String] = []) async throws -> [Word] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechFileError.unreadable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(hints.prefix(100))
            try? await analyzer.setContext(context)
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let collect = Task { () -> [(text: String, start: Double, end: Double)] in
            var runs: [(text: String, start: Double, end: Double)] = []
            for try await r in transcriber.results where r.isFinal {
                for run in r.text.runs {
                    guard let t = run.audioTimeRange else { continue }
                    runs.append((String(r.text[run.range].characters), t.start.seconds, t.end.seconds))
                }
            }
            return runs
        }
        try await analyzer.start(inputSequence: stream)
        do {
            try await AudioReader.feed(video, as: target) { input.yield(AnalyzerInput(buffer: $0)) }
        } catch {
            input.finish()
            await analyzer.cancelAndFinishNow()
            collect.cancel()
            throw error
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let runs = try await collect.value
        return Transcript.words(from: runs.sorted { $0.start < $1.start })
    }
}

/// Reads the sound of a video or audio file as PCM buffers in a given format.
enum AudioReader {
    static func feed(_ url: URL, as target: AVAudioFormat, _ send: (AVAudioPCMBuffer) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SpeechFileError.noAudio
        }
        let reader = try AVAssetReader(asset: asset)
        // Mono float at the target rate; the converter makes the target's sample type.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: target.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading(),
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target.sampleRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw SpeechFileError.unreadable
        }
        while let sample = output.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { continue }
            buf.frameLength = frames
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                               into: buf.mutableAudioBufferList) == noErr else { continue }
            if source == target { send(buf); continue }
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames + 32) else { continue }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buf
            }
            if error == nil, out.frameLength > 0 { send(out) }
        }
        if reader.status == .failed { throw reader.error ?? SpeechFileError.unreadable }
    }
}

enum SpeechFileError: LocalizedError {
    case noAudio, unreadable
    var errorDescription: String? {
        switch self {
        case .noAudio: return "The file has no sound."
        case .unreadable: return "Couldn't read the sound."
        }
    }
}
