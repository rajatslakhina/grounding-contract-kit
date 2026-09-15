//
//  Lexicon.swift
//  GroundingContract
//
//  Deterministic, dependency-free text normalisation and IDF weighting.
//

import Foundation

/// A normalised token.
///
/// Only the normalised form is exposed. Character offsets deliberately are
/// not: the tokeniser drops thousands separators, so a token's normalised
/// length no longer matches the span it came from, and publishing an offset
/// that is right most of the time is worse than publishing none. Span
/// tracking lives in `ClaimDecomposer`, which never rewrites characters.
public struct Token: Sendable, Hashable {
    public let normalized: String

    public init(normalized: String) {
        self.normalized = normalized
    }
}

/// Tokenisation and stopword policy.
///
/// Deliberately hand-rolled rather than `NLTokenizer`-backed: this type has to
/// produce byte-identical results on Linux CI, on a Simulator and on a device,
/// because the calibration numbers in the README are only meaningful if the
/// tokeniser that produced them is the tokeniser that ships.
public enum Lexicon {

    /// Closed-class words carrying no evidential weight.
    ///
    /// Kept small on purpose. An over-aggressive stoplist is a silent recall
    /// bug: strip "not" and "no evidence of harm" becomes indistinguishable
    /// from "evidence of harm". Negations are explicitly *not* stopwords.
    public static let stopwords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "with", "by",
        "from", "as", "that", "this", "these", "those", "is", "are", "was",
        "were", "be", "been", "being", "it", "its", "and", "or", "but",
        "we", "they", "he", "she", "you", "i", "our", "their", "your"
    ]

    /// Splits `text` into normalised tokens.
    ///
    /// A character is kept if it is alphanumeric; runs of kept characters
    /// become tokens. Internal `.` and `-` are preserved *inside* a run that
    /// already contains a digit, so `v1.2.3`, `3.5`, `2026-09-15` and
    /// `SKU-4471` survive as single tokens. That is load-bearing: the numeric
    /// guard below depends on figures not being shredded into digits.
    public static func tokenize(_ text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var buffer: [Character] = []
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var trimmed = buffer
            // A trailing separator is punctuation, not part of the token.
            while let last = trimmed.last, last == "." || last == "-" {
                trimmed.removeLast()
            }
            if !trimmed.isEmpty {
                tokens.append(Token(normalized: String(trimmed).lowercased()))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]
            if character.isLetter || character.isNumber {
                buffer.append(character)
            } else if character == "." || character == "-" || character == "," || character == "/" {
                // A separator survives only when it joins two alphanumerics
                // AND at least one side is a digit. That keeps `v1.2.3`,
                // `SKU-4471`, `2026-09-15` and `3.5` whole while still
                // breaking `end.Next` and `state-of-the-art` apart.
                let previous = buffer.last
                let next: Character? = {
                    let candidate = index + 1
                    guard candidate < characters.count else { return nil }
                    return characters[candidate]
                }()
                let previousIsAlphanumeric = previous.map { $0.isLetter || $0.isNumber } ?? false
                let nextIsAlphanumeric = next.map { $0.isLetter || $0.isNumber } ?? false
                let eitherIsDigit = (previous?.isNumber ?? false) || (next?.isNumber ?? false)
                let bothDigits = (previous?.isNumber ?? false) && (next?.isNumber ?? false)

                if character == "," {
                    // A comma is dropped ONLY when it is genuinely a thousands
                    // separator: digits on the left, and exactly three digits
                    // on the right not followed by another digit. Dropping it
                    // on any digit-comma-digit pair fabricates literals that
                    // are not in the text -- "Sections 1,2 and 3" would become
                    // the figure `12`, and a claim could then be vetoed for a
                    // number nobody wrote.
                    if bothDigits, isThousandsGroup(after: index, in: characters) {
                        // drop it
                    } else {
                        flush()
                    }
                } else if previousIsAlphanumeric && nextIsAlphanumeric && eitherIsDigit {
                    buffer.append(character)
                } else {
                    flush()
                }
            } else {
                flush()
            }
            index += 1
        }
        flush()
        return tokens
    }

    /// Whether the three characters after `index` are digits and the fourth is
    /// not, i.e. the comma at `index` separates a thousands group.
    private static func isThousandsGroup(after index: Int, in characters: [Character]) -> Bool {
        var offset = 1
        while offset <= 3 {
            let position = index + offset
            guard position < characters.count, characters[position].isNumber else { return false }
            offset += 1
        }
        let following = index + 4
        guard following < characters.count else { return true }
        return !characters[following].isNumber
    }

    /// Content tokens: tokenised, stopwords removed, single characters dropped
    /// unless they are digits.
    public static func contentTokens(_ text: String) -> [Token] {
        tokenize(text).filter { token in
            if stopwords.contains(token.normalized) { return false }
            if token.normalized.count == 1 {
                return token.normalized.first?.isNumber ?? false
            }
            return true
        }
    }
}

/// Inverse-document-frequency weights computed over one evidence set.
///
/// IDF is computed per call rather than from a global corpus: the question
/// "which words in this claim are the discriminating ones" is only meaningful
/// relative to the evidence actually retrieved for it.
public struct InverseDocumentFrequency: Sendable {
    private let weights: [String: Double]
    private let defaultWeight: Double

    /// - Parameter documents: one entry per evidence unit.
    public init(documents: [String]) {
        let total = documents.count
        guard total > 0 else {
            self.weights = [:]
            // With no evidence at all every token is equally (un)informative.
            self.defaultWeight = 1
            return
        }
        var counts: [String: Int] = [:]
        for document in documents {
            let unique = Set(Lexicon.contentTokens(document).map(\.normalized))
            for term in unique {
                counts[term, default: 0] = Safe.add(counts[term] ?? 0, 1)
            }
        }
        let n = Double(total)
        var computed: [String: Double] = [:]
        computed.reserveCapacity(counts.count)
        for (term, count) in counts {
            // `count` is a document count, so 1 <= df <= n and the
            // denominator is never zero. Okapi-style IDF with +1 inside the
            // log so the value is never negative for a term that appears in
            // more than half the evidence set.
            let df = Double(min(max(count, 1), total))
            let value = log(1 + (n - df + 0.5) / (df + 0.5))
            computed[term] = value.isFinite ? max(value, 0.01) : 0.01
        }
        self.weights = computed
        // A term that appears in *no* evidence document is maximally
        // discriminating, and is exactly the case the verifier must not
        // discount: it is how fabrications look.
        self.defaultWeight = log(n + 1) + 1
    }

    public func weight(for term: String) -> Double {
        let value = weights[term] ?? defaultWeight
        return value.isFinite ? value : defaultWeight
    }
}
