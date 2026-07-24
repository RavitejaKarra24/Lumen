import Foundation
import NaturalLanguage

enum TopicExtractor {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "have", "has", "was", "were",
        "are", "you", "your", "our", "their", "about", "into", "over", "under", "after",
        "before", "when", "what", "which", "while", "where", "who", "whom", "why", "how",
        "not", "but", "can", "could", "should", "would", "will", "just", "like", "also",
        "than", "then", "them", "they", "been", "being", "some", "such", "only", "other",
        "more", "most", "very", "much", "many", "http", "https", "www", "com", "org", "net",
        "app", "mac", "ios", "using", "used", "use", "via", "new", "old", "page", "home",
        "untitled", "space", "tab", "window", "google", "search", "chrome", "safari", "browser",
        "github", "issue", "pull", "request", "docs", "documentation", "readme", "index",
    ]

    /// Extract ranked topics from free text (titles, notes, page bodies).
    static func extract(from texts: [String], limit: Int = 8) -> [String] {
        var scores: [String: Double] = [:]

        for text in texts {
            let cleaned = text
                .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"[^\p{L}\p{N}\s\-+#./]"#, with: " ", options: .regularExpression)

            // Prefer NL tagger lemmas / nouns when available.
            let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
            tagger.string = cleaned
            let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther, .joinNames]
            tagger.enumerateTags(in: cleaned.startIndex..<cleaned.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
                defer { }
                let raw = String(cleaned[range])
                let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? raw
                let token = normalize(lemma)
                guard token.count >= 3, !stopwords.contains(token), !token.allSatisfy(\.isNumber) else {
                    return true
                }

                var weight = 1.0
                switch tag {
                case .noun, .personalName, .placeName, .organizationName: weight = 2.2
                case .verb: weight = 1.1
                case .adjective: weight = 1.3
                default: weight = 0.8
                }
                // CamelCase / code-ish tokens get a boost.
                if raw.contains(where: \.isUppercase), raw.contains(where: \.isLowercase) {
                    weight += 0.6
                }
                if raw.contains("-") || raw.contains(".") || raw.contains("/") {
                    weight += 0.4
                }
                scores[token, default: 0] += weight
                return true
            }

            // Multi-word phrases (bigrams) from title-like short strings.
            if cleaned.count < 120 {
                let words = cleaned
                    .split { $0.isWhitespace || $0.isNewline }
                    .map { normalize(String($0)) }
                    .filter { $0.count >= 3 && !stopwords.contains($0) }
                if words.count >= 2 {
                    for i in 0..<(words.count - 1) {
                        let phrase = "\(words[i]) \(words[i + 1])"
                        scores[phrase, default: 0] += 2.5
                    }
                }
            }
        }

        return scores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .map(\.key)
    }

    static func extract(from text: String, limit: Int = 8) -> [String] {
        extract(from: [text], limit: limit)
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_./#"))
    }
}
