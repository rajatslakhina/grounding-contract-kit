//
//  Claim.swift
//  GroundingContract
//
//  Turning an answer string into the set of assertions it is making.
//

/// One atomic assertion carved out of a generated answer.
public struct Claim: Sendable, Hashable, Identifiable {
    /// Position of this claim in the answer, starting at 0.
    public let id: Int
    /// The claim text, exactly as it appeared — never rewritten, so redaction
    /// can splice the original string back together losslessly.
    public let text: String
    /// Character offset of `text` in the source answer.
    public let start: Int
    /// Character length of `text` in the source answer.
    public let length: Int

    public init(id: Int, text: String, start: Int, length: Int) {
        self.id = id
        self.text = text
        self.start = max(0, start)
        self.length = max(0, length)
    }

    /// Half-open character range this claim occupies.
    public var range: Range<Int> { start ..< Safe.add(start, length) }

    /// A claim with no content tokens asserts nothing and is exempt from the
    /// contract — "Here is what I found:" is not a factual claim.
    public var isAssertive: Bool {
        !Lexicon.contentTokens(text).isEmpty
    }
}

/// Splits an answer into claims.
public protocol ClaimDecomposer: Sendable {
    func decompose(_ answer: String) -> [Claim]
}

/// Sentence-level decomposition with abbreviation and code-span handling.
///
/// Sentence granularity is a deliberate ceiling, not an approximation of
/// something better. Finer granularity (proposition extraction) needs a model,
/// and a verifier that needs a model to decide what to verify has a
/// circularity problem: the component whose output you distrust is now inside
/// the component you trust. Sentences are computable exactly, and a sentence
/// is also the unit a reader can actually be shown a citation for.
public struct SentenceClaimDecomposer: ClaimDecomposer {

    /// Tokens that end in `.` without ending a sentence.
    public static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "approx.", "cf.", "al.", "fig.",
        "no.", "inc.", "ltd.", "co.", "dr.", "mr.", "mrs.", "ms.", "st.",
        "jr.", "sr.", "ca.", "ibid."
    ]

    public init() {}

    public func decompose(_ answer: String) -> [Claim] {
        let characters = Array(answer)
        guard !characters.isEmpty else { return [] }

        var claims: [Claim] = []
        var sentenceStart = 0
        var index = 0
        var backtickDepth = 0
        var parenthesisDepth = 0

        while index < characters.count {
            let character = characters[index]

            if character == "`" {
                backtickDepth = backtickDepth == 0 ? 1 : 0
            } else if character == "(" || character == "[" {
                parenthesisDepth = Safe.add(parenthesisDepth, 1)
            } else if character == ")" || character == "]" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            }

            let isTerminator = character == "." || character == "!" || character == "?"
            if isTerminator, backtickDepth == 0, parenthesisDepth == 0,
               !isDecimalPoint(at: index, in: characters),
               !endsAbbreviation(at: index, in: characters) {

                // Absorb a run of terminators and any closing quote, so
                // `"...done." ` yields one sentence rather than a stray tail.
                var end = index + 1
                while end < characters.count,
                      characters[end] == "." || characters[end] == "!"
                        || characters[end] == "?" || characters[end] == "\""
                        || characters[end] == "\u{201D}" {
                    end += 1
                }
                appendClaim(from: sentenceStart, to: end, in: characters, into: &claims)
                // Skip the whitespace that separates sentences.
                var next = end
                while next < characters.count, characters[next].isWhitespace {
                    next += 1
                }
                sentenceStart = next
                index = next
                continue
            }

            // A blank line is a hard sentence break even without punctuation:
            // bullet lists and headings otherwise fuse into one giant claim.
            if character == "\n", index + 1 < characters.count, characters[index + 1] == "\n" {
                appendClaim(from: sentenceStart, to: index, in: characters, into: &claims)
                var next = index
                while next < characters.count, characters[next].isWhitespace {
                    next += 1
                }
                sentenceStart = next
                index = next
                continue
            }

            index += 1
        }

        appendClaim(from: sentenceStart, to: characters.count, in: characters, into: &claims)
        return claims
    }

    private func appendClaim(
        from start: Int,
        to end: Int,
        in characters: [Character],
        into claims: inout [Claim]
    ) {
        guard start >= 0, end <= characters.count, start < end else { return }
        let slice = characters[start ..< end]
        // Trim only whitespace, and record how much was trimmed so the stored
        // offset still points at the real first character.
        var leading = 0
        while leading < slice.count, slice[slice.startIndex + leading].isWhitespace {
            leading += 1
        }
        var trailing = 0
        while trailing < slice.count - leading,
              slice[slice.startIndex + slice.count - 1 - trailing].isWhitespace {
            trailing += 1
        }
        let trimmedCount = slice.count - leading - trailing
        guard trimmedCount > 0 else { return }
        let trimmedStart = slice.startIndex + leading
        let text = String(slice[trimmedStart ..< (trimmedStart + trimmedCount)])
        let claim = Claim(
            id: claims.count,
            text: text,
            start: Safe.add(start, leading),
            length: trimmedCount
        )
        // Non-assertive fragments ("Here is what I found:") are dropped
        // rather than kept and excused, so claim ids stay contiguous.
        guard claim.isAssertive else { return }
        claims.append(claim)
    }

    private func isDecimalPoint(at index: Int, in characters: [Character]) -> Bool {
        guard characters[index] == "." else { return false }
        guard index > 0, index + 1 < characters.count else { return false }
        return characters[index - 1].isNumber && characters[index + 1].isNumber
    }

    private func endsAbbreviation(at index: Int, in characters: [Character]) -> Bool {
        guard characters[index] == "." else { return false }
        // Walk back over the word (and any embedded dots) preceding this one.
        var start = index
        var scanned = 0
        while start > 0, scanned < 12 {
            let previous = characters[start - 1]
            guard previous.isLetter || previous == "." else { break }
            start -= 1
            scanned += 1
        }
        guard start < index else { return false }
        let candidate = String(characters[start ... index]).lowercased()
        if Self.abbreviations.contains(candidate) { return true }
        // A single capital letter followed by a dot is an initial: "J. Doe".
        let word = String(characters[start ..< index])
        return word.count == 1 && (word.first?.isLetter ?? false)
    }
}
