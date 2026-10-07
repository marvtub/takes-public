import Foundation
import NaturalLanguage

// Voice follow on the Mac (2026-10-07). The matcher is the iPhone's (`ios/TakesPhone/Recorder.swift`).
// The phone builds from a mirror of `ios/` only, so the two files cannot be one: fix both together.

/// Finds where in the script you are, from the last words the recognizer heard.
struct ScriptFollower {
    let text: String
    let words: [String]
    let ranges: [NSRange]
    /// The next word to say.
    private(set) var next = 0

    init(_ text: String) {
        self.text = text
        let all = Self.split(text)
        words = all.map(\.0)
        ranges = all.map(\.1)
    }

    /// The words of any text, cut the same way as the script (also Chinese and Japanese, which
    /// have no spaces).
    static func tokens(_ text: String) -> [String] { split(text).map(\.0) }

    private static func split(_ text: String) -> [(String, NSRange)] {
        var out: [(String, NSRange)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { s, range, _, _ in
            let n = norm(s ?? "")
            if !n.isEmpty { out.append((n, range)) }
        }
        return out
    }

    static func norm(_ s: String) -> String {
        // "Café" and "cafe" are the same word: recognizers drop or add accents.
        let plain = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(plain.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
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

    /// The index of the first word that ends after a character offset (for a hand scroll).
    func word(at offset: Int) -> Int {
        ranges.firstIndex { $0.location + $0.length > offset } ?? ranges.count
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

/// Which language to listen in: the script's own (2026-10-07: The user asked for the common languages
/// that cost little, so every language the Mac's recognizer has, picked from the script's text).
enum ScriptLanguage {
    /// The script's language code ("en", "de", "zh"), or nil for too little text.
    static func code(of text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(4000)))
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        return Locale(identifier: lang.rawValue).language.languageCode?.identifier
    }

    /// The recognizer locale for a language: the region you use when it matches, then the
    /// language's home region, then any.
    static func pick(_ code: String, from supported: [Locale], preferred: [Locale]) -> Locale? {
        let same = supported.filter { $0.language.languageCode?.identifier == code }
        guard !same.isEmpty else { return nil }
        for p in preferred where p.language.languageCode?.identifier == code {
            if let r = p.region?.identifier, let hit = same.first(where: { $0.region?.identifier == r }) { return hit }
        }
        if let home = home[code], let hit = same.first(where: { $0.region?.identifier == home }) { return hit }
        return same.sorted { $0.identifier < $1.identifier }.first
    }

    /// The region most speakers of a language use, for a pick with no other hint.
    private static let home = ["en": "US", "es": "ES", "fr": "FR", "de": "DE", "it": "IT", "pt": "BR", "nl": "NL",
                               "ja": "JP", "zh": "CN", "ko": "KR", "ru": "RU", "sv": "SE", "da": "DK", "nb": "NO",
                               "fi": "FI", "pl": "PL", "tr": "TR", "ar": "SA", "hi": "IN", "yue": "CN"]

    /// The language's name in the app's language, for a note ("German").
    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
