import Foundation

/// Snap near-miss spellings to known terms ("Kameleon" → "Kameleoon").
///
/// Whisper can be biased with a prompt; Parakeet (a transducer) can't, so its
/// output is corrected afterwards against the same vocabulary Wispr Flow sends
/// as `dictionary` (personal dictionary, the user's name, words on screen).
public enum VocabularyCorrection {
    /// - Parameters:
    ///   - minLength: shorter terms are too easy to confuse with ordinary words.
    ///   - minSimilarity: 1 - editDistance / max(length), on lowercased letters.
    public static func apply(to text: String, vocabulary: [String],
                             minLength: Int = 5, minSimilarity: Double = 0.8) -> String {
        let terms = vocabulary.filter { $0.count >= minLength && !$0.contains(" ") }
        guard !terms.isEmpty else { return text }
        var out = ""
        var word = ""
        func flush() {
            out += correct(word, terms: terms, minSimilarity: minSimilarity)
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { word.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    private static func correct(_ word: String, terms: [String], minSimilarity: Double) -> String {
        guard word.count >= 4 else { return word }
        let lw = word.lowercased()
        var best: (term: String, score: Double)?
        for term in terms {
            let lt = term.lowercased()
            if lt == lw { return term } // exact match: adopt the term's casing
            guard abs(lt.count - lw.count) <= 3 else { continue }
            let score = 1 - Double(editDistance(lw, lt)) / Double(max(lw.count, lt.count))
            if score >= minSimilarity, score > (best?.score ?? 0) { best = (term, score) }
        }
        return best?.term ?? word
    }

    /// Optimal-string-alignment distance: Levenshtein plus adjacent transpositions
    /// ("Texiera" → "Texeira" is 1 edit), a common transcription slip.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
