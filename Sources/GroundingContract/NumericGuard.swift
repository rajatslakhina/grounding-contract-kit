//
//  NumericGuard.swift
//  GroundingContract
//
//  The part of the verifier that paraphrase similarity cannot do.
//
//  A hallucinated figure is the highest-cost, lowest-detectability failure a
//  grounded answer has. "Revenue grew to $4.2M in Q3" and "Revenue grew to
//  $3.1M in Q3" are ~95% lexically identical: any cosine, any BM25 overlap,
//  any n-gram similarity scores the fabricated one as supported. Numbers and
//  identifiers therefore get a *separate, exact* channel that can veto a
//  claim no matter how high its prose score is.
//

/// A number or identifier extracted from text, in canonical form.
public struct NumericLiteral: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A bare quantity: `4200`, `3.5`, `12`.
        case number
        /// A mixed alphanumeric token: `SKU-4471`, `v1.2.3`, `APP5-328`,
        /// `2026-09-15`.
        case identifier
    }

    /// Normalised form used for matching.
    public let canonical: String
    /// The token exactly as it appeared, for error messages.
    public let raw: String
    public let kind: Kind
    /// Parsed magnitude, when `canonical` fits a `Double`. `nil` for
    /// identifiers and for numbers too large to represent.
    public let value: Double?

    init(canonical: String, raw: String, kind: Kind) {
        self.canonical = canonical
        self.raw = raw
        self.kind = kind
        if kind == .number, let parsed = Double(canonical), parsed.isFinite {
            self.value = parsed
        } else {
            self.value = nil
        }
    }
}

/// Extraction and exact matching of quantities and identifiers.
public enum NumericGuard {

    /// Canonical literals present in `text`, for fast set membership.
    public static func literals(in text: String) -> Set<String> {
        Set(literalDetails(in: text).map(\.canonical))
    }

    /// Every literal in `text`, in order of appearance, de-duplicated by
    /// canonical form.
    public static func literalDetails(in text: String) -> [NumericLiteral] {
        var results: [NumericLiteral] = []
        var seen: Set<String> = []
        for token in Lexicon.tokenize(text) {
            guard let literal = classify(token.normalized) else { continue }
            if seen.insert(literal.canonical).inserted {
                results.append(literal)
            }
        }
        return results
    }

    /// Classifies a single normalised token, or returns `nil` if it carries no
    /// quantity or identity.
    static func classify(_ normalized: String) -> NumericLiteral? {
        guard !normalized.isEmpty else { return nil }
        let hasDigit = normalized.contains { $0.isNumber }
        guard hasDigit else { return nil }
        let hasLetter = normalized.contains { $0.isLetter }
        let hasSeparator = normalized.contains("-") || normalized.contains("/")

        if hasLetter || hasSeparator {
            // Mixed token or a dash/slash-joined form such as a date or a SKU.
            return NumericLiteral(canonical: normalized, raw: normalized, kind: .identifier)
        }
        if let canonical = canonicalNumber(normalized) {
            return NumericLiteral(canonical: canonical, raw: normalized, kind: .number)
        }
        // A digit-bearing token that is not a single quantity -- a dotted
        // version like `1.2.3`. It must NOT fall through as "no literal here":
        // that would let "version 1.2.4" pass unvetoed against a corpus saying
        // 1.2.3, which is exactly the failure this type exists to stop. It has
        // no magnitude, so it is matched exactly, as an identifier.
        return NumericLiteral(canonical: normalized, raw: normalized, kind: .identifier)
    }

    /// Canonicalises a pure-digit token purely as a string: no `Double` round
    /// trip, so `10000000000000000001` and `1e19` never collide and nothing
    /// depends on float formatting being stable across platforms.
    ///
    /// - Strips leading zeros in the integer part (keeping one digit).
    /// - Strips trailing zeros in the fractional part, and a bare trailing dot.
    static func canonicalNumber(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        guard let integerPart = parts.first else { return nil }
        guard !integerPart.isEmpty || parts.count == 2 else { return nil }
        guard token.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }

        var integer = String(integerPart.drop(while: { $0 == "0" }))
        if integer.isEmpty { integer = "0" }

        guard parts.count == 2 else { return integer }
        var fraction = String(parts[1])
        while fraction.last == "0" { fraction.removeLast() }
        if fraction.isEmpty { return integer }
        return integer + "." + fraction
    }

    /// Whether `claimLiteral` is corroborated by `evidenceLiterals`.
    ///
    /// Identifiers require an exact canonical match. Numbers may match within
    /// a *relative* tolerance, which defaults to zero: a figure quoted from a
    /// document should be the figure in the document. Tolerance exists for
    /// callers whose model legitimately rounds ("about 4.2 million" against
    /// "4,215,000"), and is a deliberate, opt-in loosening of the contract.
    static func isSatisfied(
        _ claimLiteral: NumericLiteral,
        by evidenceLiterals: Set<String>,
        relativeTolerance: Double
    ) -> Bool {
        if evidenceLiterals.contains(claimLiteral.canonical) { return true }
        guard claimLiteral.kind == .number else { return false }
        guard relativeTolerance > 0, relativeTolerance.isFinite else { return false }
        guard let claimValue = claimLiteral.value else { return false }

        for candidate in evidenceLiterals {
            guard let candidateValue = Double(candidate), candidateValue.isFinite else { continue }
            let scale = max(abs(claimValue), abs(candidateValue), 1)
            let difference = abs(claimValue - candidateValue)
            guard difference.isFinite else { continue }
            if difference <= relativeTolerance * scale { return true }
        }
        return false
    }
}
