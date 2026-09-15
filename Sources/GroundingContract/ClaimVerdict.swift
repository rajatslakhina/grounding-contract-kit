//
//  ClaimVerdict.swift
//  GroundingContract
//
//  The result types. Everything the engine decides is inspectable.
//

/// Why a claim failed the contract.
public enum UnsupportedReason: String, Sendable, Hashable, CaseIterable {
    /// No evidence was supplied at all.
    case noEvidence
    /// Prose coverage fell below `weakSupportThreshold`.
    case insufficientCoverage
    /// A number or identifier in the claim appears in no supporting evidence.
    case numericMismatch
    /// The only supporting evidence is older than the policy allows.
    case staleEvidence
    /// Supported, but by fewer distinct sources than the policy requires.
    case insufficientDistinctSources
}

/// A citation: one evidence unit, and how much of the claim it covered.
public struct Citation: Sendable, Hashable {
    public let evidenceID: String
    public let sourceID: String
    public let displayName: String
    /// Share of the claim's IDF mass this unit alone accounts for, in `0...1`.
    public let coverage: Double

    public init(evidenceID: String, sourceID: String, displayName: String, coverage: Double) {
        self.evidenceID = evidenceID
        self.sourceID = sourceID
        self.displayName = displayName
        self.coverage = Safe.clamp01(coverage)
    }
}

/// The verdict on a single claim.
public struct ClaimVerdict: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Hashable {
        case supported
        case weaklySupported
        case unsupported
    }

    public var id: Int { claim.id }
    public let claim: Claim
    public let status: Status
    /// Total coverage in `0...1` after composition and the numeric veto.
    public let coverage: Double
    /// Evidence units backing this claim, best first. Empty when unsupported.
    public let citations: [Citation]
    public let reason: UnsupportedReason?
    /// Literals in the claim that no supporting evidence corroborates.
    public let unmatchedLiterals: [String]

    public init(
        claim: Claim,
        status: Status,
        coverage: Double,
        citations: [Citation],
        reason: UnsupportedReason?,
        unmatchedLiterals: [String] = []
    ) {
        self.claim = claim
        self.status = status
        self.coverage = Safe.clamp01(coverage)
        self.citations = citations
        self.reason = reason
        self.unmatchedLiterals = unmatchedLiterals
    }

    public var isAcceptable: Bool { status == .supported }
}

/// What the engine decided to do with the answer as a whole.
public enum ContractOutcome: Sendable, Hashable {
    /// Every claim cleared the bar; `text` is the original answer.
    case answered
    /// Unsupported claims were left in place and merely flagged.
    case annotated(unsupportedClaims: Int)
    /// Unsupported claims were excised.
    case redacted(removedClaims: Int, removedCharacterRatio: Double)
    /// Nothing is returned to the user.
    case refused(RefusalCause)

    public enum RefusalCause: Sendable, Hashable {
        /// Policy is `.refuse` and at least one claim failed.
        case unsupportedClaims(Int)
        /// Redaction would have removed more of the answer than
        /// `maximumRedactionRatio` allows.
        case redactionExceededBudget(attemptedRatio: Double)
        /// Redaction removed every assertive claim.
        case nothingSurvivedRedaction
        /// The evidence set was empty, so nothing could ever be grounded.
        case noEvidence
    }
}

/// The engine's complete output.
public struct VerifiedAnswer: Sendable {
    /// Text safe to show the user. Empty for a refusal.
    public let text: String
    /// The answer exactly as the model produced it, always preserved so the
    /// decision can be audited after the fact.
    public let originalText: String
    public let verdicts: [ClaimVerdict]
    public let outcome: ContractOutcome
    public let policy: GroundingPolicy

    public init(
        text: String,
        originalText: String,
        verdicts: [ClaimVerdict],
        outcome: ContractOutcome,
        policy: GroundingPolicy
    ) {
        self.text = text
        self.originalText = originalText
        self.verdicts = verdicts
        self.outcome = outcome
        self.policy = policy
    }

    public var isRefusal: Bool {
        if case .refused = outcome { return true }
        return false
    }

    public var unsupportedCount: Int {
        verdicts.reduce(0) { $0 + ($1.status == .unsupported ? 1 : 0) }
    }

    /// Distinct evidence units cited anywhere in the surviving answer.
    public var citedEvidenceIDs: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for verdict in verdicts where verdict.status != .unsupported {
            for citation in verdict.citations where seen.insert(citation.evidenceID).inserted {
                ordered.append(citation.evidenceID)
            }
        }
        return ordered
    }
}
