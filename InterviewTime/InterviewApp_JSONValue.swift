//
//  JSONValue.swift
//  Interviewer
//
//  Tipe JSON dinamis ringan — pengganti `dict`/`Any` Python supaya kita bisa
//  membaca hasil JSON dari LLM (jd_analysis, summary, deep_feedback, dst.)
//  tanpa harus mendefinisikan struct Codable yang kaku untuk setiap bentuk.
//

import Foundation

enum JSONValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    // MARK: - Convenience accessors (mirip safe_get() di Python)

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        if case .string(let s) = self { return Double(s) }
        return nil
    }

    var isEmptyLike: Bool {
        switch self {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .object(let o): return o.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Daftar string praktis untuk field semacam `["string", ...]`.
    func stringArray() -> [String] {
        arrayValue?.compactMap { $0.stringValue } ?? []
    }

    // MARK: - Konversi dari/ke Foundation Any (hasil JSONSerialization)

    static func from(_ any: Any) -> JSONValue {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            // NSNumber bisa bool atau number — bedakan via objCType.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let b as Bool: return .bool(b)
        case let arr as [Any]: return .array(arr.map(JSONValue.from))
        case let dict as [String: Any]:
            var obj = [String: JSONValue]()
            for (k, v) in dict { obj[k] = JSONValue.from(v) }
            return .object(obj)
        case is NSNull: return .null
        default: return .null
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue.from(obj)
    }

    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(data)
    }

    /// Balik ke Any biasa, dipakai saat menulis ulang ke JSONSerialization (misalnya simpan sesi).
    func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o):
            var dict = [String: Any]()
            for (k, v) in o { dict[k] = v.toAny() }
            return dict
        case .null: return NSNull()
        }
    }

    func prettyPrinted() -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: toAny(),
            options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// ============================================================
// UTIL TEKS — strip <think>...</think> & ekstraksi JSON robust
// (port langsung dari strip_think() / extract_json() di interviewer.py)
// ============================================================
enum TextUtils {
    private static let thinkRegex = try? NSRegularExpression(
        pattern: "<think>.*?</think>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    static func stripThink(_ text: String) -> String {
        guard !text.isEmpty, let regex = thinkRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Coba parse JSON dari output model secara robust (object ATAU array),
    /// termasuk dari dalam ```json fence atau teks bebas yang menyelipkan JSON.
    static func extractJSON(_ raw: String) -> JSONValue? {
        let text = stripThink(raw)

        if let v = JSONValue.parse(text) { return v }

        if let fenced = firstMatch(in: text, pattern: "```(?:json)?\\s*([\\s\\S]*?)```"),
           let v = JSONValue.parse(fenced.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return v
        }
        if let obj = firstMatch(in: text, pattern: "\\{[\\s\\S]*\\}"),
           let v = JSONValue.parse(obj) {
            return v
        }
        if let arr = firstMatch(in: text, pattern: "\\[[\\s\\S]*\\]"),
           let v = JSONValue.parse(arr) {
            return v
        }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        let groupIndex = m.numberOfRanges > 1 ? 1 : 0
        guard let r = Range(m.range(at: groupIndex), in: text) else { return nil }
        return String(text[r])
    }
}
