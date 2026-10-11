//
//  FillerDetector.swift
//  STTInterview
//
//  Port of detect_fillers() from the notebook: catches ID + English fillers,
//  including elongated sounds ("ummmm", "ehhhh") and multi-word phrases.
//

import Foundation

enum FillerDetector {

    private static let punctuation = CharacterSet(charactersIn:
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~…—–")

    private static let fillerSound = try! NSRegularExpression(
        pattern: "^(?:u+[hm]+|e+h+|e+m+|e+r+|e{2,}|a+h+|a{2,}|h+m+|m{2,}|m+h+m+|n+g+|h+u+h+)$")

    /// Lowercase + strip surrounding punctuation/whitespace.
    private static func norm(_ token: String) -> String {
        token.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: punctuation)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Collapse runs of repeated characters: "ehhhh" -> "eh", "jadii" -> "jadi".
    private static func canon(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        var last: Character? = nil
        for ch in s {
            if ch != last { out.append(ch); last = ch }
        }
        return out
    }

    private static func matchesSound(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return fillerSound.firstMatch(in: s, options: [], range: range) != nil
    }

    static func detect(_ result: STTResult) -> FillerAnalysis {
        let words = result.words
        let n = words.count
        let norms = words.map { norm($0.text) }
        let canons = norms.map { canon($0) }
        var used = [Bool](repeating: false, count: n)

        var singles: [FillerHit] = []
        var phrases: [FillerPhraseHit] = []
        var perWord: [String: Int] = [:]

        // Phrases first (avoid double-counting their constituent words).
        for ph in Config.fillerPhrases {
            let parts = ph.split(separator: " ").map(String.init)
            let L = parts.count
            guard L > 0, n >= L else { continue }
            for i in 0...(n - L) {
                let slice = Array(norms[i..<(i + L)])
                let usedSlice = used[i..<(i + L)].contains(true)
                if slice == parts && !usedSlice {
                    for k in i..<(i + L) { used[k] = true }
                    phrases.append(FillerPhraseHit(phrase: ph,
                                                   start: (words[i].start * 100).rounded() / 100))
                    perWord[ph, default: 0] += 1
                }
            }
        }

        // Single-word fillers.
        for i in 0..<n {
            if used[i] { continue }
            let normTok = norms[i]
            if normTok.isEmpty { continue }
            let can = canons[i]
            var type: String? = nil
            var key = normTok

            if Config.fillerNonLexical.contains(normTok) || matchesSound(normTok) {
                type = "non-leksikal"; key = can
            } else if Config.fillerLexicalID.contains(normTok) || Config.fillerLexicalID.contains(can)
                        || Config.fillerLexicalEN.contains(normTok) || Config.fillerLexicalEN.contains(can) {
                let isID = Config.fillerLexicalID.contains(normTok) || Config.fillerLexicalID.contains(can)
                type = isID ? "leksikal-id" : "leksikal-en"; key = can
            }

            if let type {
                let start = (words[i].start * 100).rounded() / 100
                singles.append(FillerHit(word: words[i].text, start: start, norm: key, type: type))
                perWord[key, default: 0] += 1
            }
        }

        let totalWords = norms.filter { !$0.isEmpty }.count
        let count = singles.count + phrases.count
        let ratio = totalWords > 0 ? (Double(count) / Double(totalWords) * 1000).rounded() / 10 : 0

        var marked = Set<Double>()
        for s in singles { marked.insert(s.start) }
        for p in phrases { marked.insert(p.start) }

        return FillerAnalysis(totalWords: totalWords,
                              fillerCount: count,
                              fillerRatioPercent: ratio,
                              perWord: perWord,
                              singles: singles.sorted { $0.start < $1.start },
                              phrases: phrases.sorted { $0.start < $1.start },
                              markedStarts: marked)
    }
}
