//
//  GroundingContractEngine.swift
//  GroundingContract
//
//  decompose -> attribute -> score -> enforce -> record
//

/// Enforces a `GroundingPolicy` over a generated answer.
///
/// The engine is an `actor` because the ledger it writes to is shared mutable
/// state and a real app verifies several answers at once (a streamed answer
/// re-verified per chunk, plus background pre-verification of suggestions).
/// Note what it deliberately does *not* do: there is no `await` inside the
/// verification pipeline, so there is no suspension point at which a second
/// call could interleave and observe a half-built verdict list. Verification
/// is pure and synchronous; only the ledger write crosses an actor boundary.
public actor GroundingContractEngine {

    private let decomposer: any ClaimDecomposer
    private let scorer: any SupportScorer
    private let ledger: AttributionLedger?

    public let defaultPolicy: GroundingPolicy

    public init(
        policy: GroundingPolicy = GroundingPolicy(),
        decomposer: any ClaimDecomposer = SentenceClaimDecomposer(),
        scorer: any SupportScorer = LexicalEntailmentScorer(),
        ledger: AttributionLedger? = nil
    ) {
        self.defaultPolicy = policy
        self.decomposer = decomposer
        self.scorer = scorer
        self.ledger = ledger
    }

    /// Verifies `answer` against `evidence` and applies the contract.
    ///
    /// - Parameter question: recorded in the ledger only; it does not affect
    ///   the verdict. Grounding is a property of the answer and the evidence.
    public func verify(
        answer: String,
        evidence: EvidenceSet,
        question: String = "",
        policy: GroundingPolicy? = nil
    ) async -> VerifiedAnswer {
        let effectivePolicy = policy ?? defaultPolicy
        let result = Self.evaluate(
            answer: answer,
            evidence: evidence,
            policy: effectivePolicy,
            decomposer: decomposer,
            scorer: scorer
        )
        if let ledger {
            await ledger.record(question: question, answer: result)
        }
        return result
    }

    /// Pure, synchronous verification. Exposed as a `nonisolated static` so a
    /// caller that does not want the actor hop (a SwiftUI preview, a unit
    /// test, a `#Preview`) can run exactly the shipping logic.
    public nonisolated static func evaluate(
        answer: String,
        evidence: EvidenceSet,
        policy: GroundingPolicy,
        decomposer: any ClaimDecomposer = SentenceClaimDecomposer(),
        scorer: any SupportScorer = LexicalEntailmentScorer()
    ) -> VerifiedAnswer {
        let claims = decomposer.decompose(answer)

        guard !claims.isEmpty else {
            // Nothing assertive was said, so nothing is ungrounded.
            return VerifiedAnswer(
                text: answer,
                originalText: answer,
                verdicts: [],
                outcome: .answered,
                policy: policy
            )
        }

        guard !evidence.isEmpty else {
            let verdicts = claims.map { claim in
                ClaimVerdict(
                    claim: claim,
                    status: .unsupported,
                    coverage: 0,
                    citations: [],
                    reason: .noEvidence
                )
            }
            if policy.unsupportedClaimAction == .annotate {
                return VerifiedAnswer(
                    text: answer,
                    originalText: answer,
                    verdicts: verdicts,
                    outcome: .annotated(unsupportedClaims: verdicts.count),
                    policy: policy
                )
            }
            return VerifiedAnswer(
                text: "",
                originalText: answer,
                verdicts: verdicts,
                outcome: .refused(.noEvidence),
                policy: policy
            )
        }

        let verdicts = claims.map { claim in
            verdict(for: claim, evidence: evidence, policy: policy, scorer: scorer)
        }
        return enforce(policy: policy, on: answer, verdicts: verdicts)
    }

    private nonisolated static func verdict(
        for claim: Claim,
        evidence: EvidenceSet,
        policy: GroundingPolicy,
        scorer: any SupportScorer
    ) -> ClaimVerdict {
        let measurement = scorer.score(claim: claim, against: evidence, policy: policy)

        if measurement.blockedByStaleEvidence {
            return ClaimVerdict(
                claim: claim,
                status: .unsupported,
                coverage: 0,
                citations: [],
                reason: .staleEvidence,
                unmatchedLiterals: measurement.unmatchedLiterals
            )
        }

        if !measurement.unmatchedLiterals.isEmpty {
            // The literal veto outranks every other outcome, including a high
            // prose score. This ordering is the contract's sharpest edge.
            return ClaimVerdict(
                claim: claim,
                status: .unsupported,
                coverage: 0,
                citations: measurement.citations,
                reason: .numericMismatch,
                unmatchedLiterals: measurement.unmatchedLiterals
            )
        }

        if measurement.coverage >= policy.supportThreshold {
            guard measurement.distinctSourceCount >= policy.minimumDistinctSources else {
                return ClaimVerdict(
                    claim: claim,
                    status: .unsupported,
                    coverage: measurement.coverage,
                    citations: measurement.citations,
                    reason: .insufficientDistinctSources
                )
            }
            return ClaimVerdict(
                claim: claim,
                status: .supported,
                coverage: measurement.coverage,
                citations: measurement.citations,
                reason: nil
            )
        }

        if measurement.coverage >= policy.weakSupportThreshold, measurement.coverage > 0 {
            return ClaimVerdict(
                claim: claim,
                status: .weaklySupported,
                coverage: measurement.coverage,
                citations: measurement.citations,
                reason: .insufficientCoverage
            )
        }

        return ClaimVerdict(
            claim: claim,
            status: .unsupported,
            coverage: measurement.coverage,
            citations: measurement.citations,
            reason: .insufficientCoverage
        )
    }

    private nonisolated static func enforce(
        policy: GroundingPolicy,
        on answer: String,
        verdicts: [ClaimVerdict]
    ) -> VerifiedAnswer {
        // `weaklySupported` is below the bar: it is reported separately so a
        // dashboard can see near-misses, but it is not shippable.
        let failing = verdicts.filter { $0.status != .supported }
        guard !failing.isEmpty else {
            return VerifiedAnswer(
                text: answer,
                originalText: answer,
                verdicts: verdicts,
                outcome: .answered,
                policy: policy
            )
        }

        switch policy.unsupportedClaimAction {
        case .annotate:
            return VerifiedAnswer(
                text: answer,
                originalText: answer,
                verdicts: verdicts,
                outcome: .annotated(unsupportedClaims: failing.count),
                policy: policy
            )

        case .refuse:
            return VerifiedAnswer(
                text: "",
                originalText: answer,
                verdicts: verdicts,
                outcome: .refused(.unsupportedClaims(failing.count)),
                policy: policy
            )

        case .redact:
            let assertiveCharacters = verdicts.reduce(0) { Safe.add($0, $1.claim.length) }
            let removedCharacters = failing.reduce(0) { Safe.add($0, $1.claim.length) }
            let ratio = Safe.ratio(Double(removedCharacters), Double(assertiveCharacters))

            if ratio > policy.maximumRedactionRatio {
                return VerifiedAnswer(
                    text: "",
                    originalText: answer,
                    verdicts: verdicts,
                    outcome: .refused(.redactionExceededBudget(attemptedRatio: ratio)),
                    policy: policy
                )
            }

            let surviving = verdicts.filter { $0.status == .supported }
            guard !surviving.isEmpty else {
                return VerifiedAnswer(
                    text: "",
                    originalText: answer,
                    verdicts: verdicts,
                    outcome: .refused(.nothingSurvivedRedaction),
                    policy: policy
                )
            }

            let redacted = redact(answer: answer, keeping: surviving)
            return VerifiedAnswer(
                text: redacted,
                originalText: answer,
                verdicts: verdicts,
                outcome: .redacted(
                    removedClaims: failing.count,
                    removedCharacterRatio: ratio
                ),
                policy: policy
            )
        }
    }

    /// Rebuilds the answer from the surviving claims' original character
    /// ranges. The model's own words are never paraphrased or re-generated —
    /// a redaction step that rewrites text would reintroduce exactly the
    /// ungrounded-generation problem it exists to remove.
    private nonisolated static func redact(answer: String, keeping verdicts: [ClaimVerdict]) -> String {
        let characters = Array(answer)
        var pieces: [String] = []
        for verdict in verdicts.sorted(by: { $0.claim.start < $1.claim.start }) {
            let start = min(max(0, verdict.claim.start), characters.count)
            let end = min(Safe.add(start, verdict.claim.length), characters.count)
            guard start < end else { continue }
            pieces.append(String(characters[start ..< end]))
        }
        return pieces.joined(separator: " ")
    }
}
