//
//  Config.swift
//  STTInterview
//
//  All "knobs": Whisper settings, thresholds, weights, filler lexicons,
//  technical context (contextual biasing) and homophone corrections.
//  Mirrors the configuration in STT_Interview.ipynb / engine.py.
//

import Foundation

enum Config {

    // MARK: - Whisper (WhisperKit menjalankan model OpenAI Whisper yang sama, on-device)
    /// Preferensi model. "turbo" = model OpenAI large-v3-turbo (sama seperti notebook).
    /// Nama turbo yang valid dicari otomatis dari repo (lihat WhisperService), jadi
    /// tidak perlu khawatir salah nama. Alternatif: "large-v3" | "small" | "base".
    static let model = "large-v3"
    /// Bahasa decoding. "id" = paksa basis Indonesia (disarankan untuk campur ID/EN:
    /// mencegah hasil melompat jadi full English & membuat filler Indonesia ikut tertulis).
    /// nil = auto-detect (sering memilih English saja, filler dirapikan). "en" = paksa Inggris.
    static let language: String? = "id"
    /// true = verbatim transcript (fillers kept). Mematikan suppression + pakai prompt.
    static let verbatim = true
    /// Seed Whisper dengan konteks teknis + contoh filler lewat promptTokens.
    /// DIMATIKAN. Bug: pada panggilan transcribe PERTAMA, pipe.tokenizer masih nil
    /// (baru selesai prewarm) sehingga blok prompt di-skip dan transkrip berhasil.
    /// Pada panggilan KEDUA dst, tokenizer sudah ada → promptTokens disuntik →
    /// decoder ter-bias dan keluar kosong (wordCount=0) walau audio valid.
    /// Dikonfirmasi via test: file yang sama berhasil ditranskrip whisper CLI
    /// tapi kosong di app saat biasing prompt aktif.
    /// Koreksi istilah teknis tetap jalan lewat Config.applyCorrections (post-processing).
    static let useBiasingPrompt = false

    // MARK: - Assessment thresholds
    static let pauseMin: Double = 0.3       // gap between words (s) counted as a pause
    static let longPause: Double = 1.0      // "long pause" threshold
    static let wpmLow: Double = 100         // comfortable tempo lower bound (words/min)
    static let wpmHigh: Double = 160        // comfortable tempo upper bound
    static let pitchFMin: Double = 75       // pitch search range (Hz)
    static let pitchFMax: Double = 400

    // MARK: - Final score weights (sum = 1.0)
    static let weights: [(key: String, value: Double)] = [
        ("delivery", 0.15),
        ("fluency", 0.20),
        ("clarity", 0.20),
        ("paralinguistic", 0.20),
        ("interview", 0.25),
    ]

    // MARK: - Interview question (content assessment)
    static let question = "Coba ceritakan pengalaman kerja Anda."

    // MARK: - Contextual biasing
    static let fillerPrompt =
        "Ummm, ehhh, eee, mmm, anu, hmmm, ya, kayak, gini, gitu, jadi, terus, apa ya... " +
        "uh, um, er, like, you know, I mean, so, well."

    static let techContext =
        "Konteks: wawancara kerja teknologi. Istilah teknis: " +
        "JSON, YAML, XML, API, REST, GraphQL, SQL, Python, JavaScript, TypeScript, Java, Golang, " +
        "React, Node.js, Django, FastAPI, PyTorch, TensorFlow, machine learning, deep learning, " +
        "Docker, Kubernetes, AWS, GCP, Git, GitHub, CI/CD, microservices, backend, frontend, " +
        "full stack, database, PostgreSQL, MongoDB, Redis."

    static var initialPrompt: String { techContext + " " + fillerPrompt }

    // MARK: - Homophone corrections (post-transcript)
    // (pattern, replacement). $1 keeps captured group.
    static let commonFixes: [(pattern: String, replacement: String)] = [
        ("\\bjason\\b(\\s+(?:file|format|object|data|payload|schema|array|response|body|string))", "JSON$1"),
        ("\\bp(?:y|ie?)\\s*torch\\b", "PyTorch"),
        ("\\btensor\\s*flow\\b", "TensorFlow"),
        ("\\bnode\\s*js\\b", "Node.js"),
        ("\\bjava\\s*script\\b", "JavaScript"),
        ("\\btype\\s*script\\b", "TypeScript"),
        ("\\bgit\\s*hub\\b", "GitHub"),
        ("\\breact\\s*js\\b", "React"),
        ("\\bk8s\\b", "Kubernetes"),
        ("\\bpost\\s*gres(?:ql)?\\b", "PostgreSQL"),
    ]

    static func applyCorrections(_ text: String) -> String {
        var out = text
        for fix in commonFixes {
            if let re = try? NSRegularExpression(pattern: fix.pattern, options: [.caseInsensitive]) {
                let range = NSRange(out.startIndex..., in: out)
                out = re.stringByReplacingMatches(in: out, options: [], range: range,
                                                  withTemplate: fix.replacement)
            }
        }
        return out
    }

    // MARK: - Filler lexicon (ID + English)
    static let fillerNonLexical: Set<String> = [
        "uh","uhm","um","umm","uhh","er","err","erm","ah","ahh","eh","oh","hm","hmm","hmmm",
        "mm","mmm","mhm","huh","e","ee","eee","em","emm","he","hee","anu","aa","aaa","ng","nng","ehm",
    ]
    static let fillerLexicalID: Set<String> = [
        "anu","apa","gini","begini","gitu","begitu","kayak","kaya","kek","kayaknya",
        "jadi","terus","trus","lalu","nah","kan","sih","deh","dong","lah","kok","ya","yah",
        "pokoknya","intinya","maksudnya","soalnya","masa","loh","lho","nih","tuh","itu","ini",
    ]
    static let fillerLexicalEN: Set<String> = [
        "like","well","so","okay","ok","right","now","actually","basically","literally",
        "honestly","seriously","kinda","sorta","anyway","anyways","whatever","stuff","dunno","see",
    ]
    static let fillerPhrases: [String] = [
        "apa ya","apa namanya","apa sih","itu loh","gitu loh","ya kan","ya udah","tau gak","tau kan",
        "you know","y'know","i mean","i guess","i think","kind of","sort of","you see",
        "or something","or whatever","the thing is","to be honest","let me think",
    ]
}
