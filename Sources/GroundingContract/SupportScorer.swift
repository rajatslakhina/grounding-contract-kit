//
//  SupportScorer.swift
//  GroundingContract
//
//  Scoring one claim against one evidence set.
//

/// Pluggable scoring seam.
///
/// The engine, the policy enforcement and the ledger are all independent of
/// *how* support is measured. A caller with an on-device embedding model drops
/// it in here; the contract, the refusal logic and the calibration harness are
/// unchanged. The default implementation deliberately needs no model, which is
/// why the whole package builds and its behaviour is verified on Linux CI.
public protocol SupportScorer: Sendable {
    /// - Returns: a verdict *before* policy is applied — coverage, citations
    ///   and any unmatched literals. Threshold comparison is the engine's job.
    func score(claim: Claim, against evidence: EvidenceSet, policy: GroundingPolicy) -> SupportMeasurement
}

/// Raw measurement, prior to any threshold decision.
public struct SupportMeasurement: Sendable, Hashable {
    public let coverage: Double
    public let citations: [Citation]
    public let unmatchedLiterals: [String]
    /// Distinct sources among `citations`.
    public let distinctSourceCount: Int
    /// True when every citation was rejected for age.
    public let blockedByStaleEvidence: Bool

    public init(
        coverage: Double,
        citations: [Citation],
        unmatchedLiterals: [String],
        distinctSourceCount: Int,
        blockedByStaleEvidence: Bool = false
    ) {
        self.coverage = Safe.clamp01(coverage)
        self.citations = citations
        self.unmatchedLiterals = unmatchedLiterals
        self.distinctSourceCount = max(0, distinctSourceCount)
        self.blockedByStaleEvidence = blockedByStaleEvidence
    }
}

/// IDF-weighted lexical coverage, vetoed by exact literal matching.
///
/// Two channels, deliberately asymmetric:
///
/// 1. **Prose channel** — the share of the claim's IDF mass that appears in
///    the evidence. Rare words count for more than common ones, so "the" being
///    present proves nothing and "eviction" being present proves a lot.
/// 2. **Literal channel** — every number and identifier in the claim must
///    appear in the evidence that is being credited. This channel can only
///    ever *reduce* the score, never raise it, and it reduces it to zero.
///
/// The asymmetry is the whole point. Channel 1 is a similarity measure and
/// similarity measures cannot see the difference between $4.2M and $3.1M.
/// Channel 2 can see nothing else.
public struct LexicalEntailmentScorer: SupportScorer {

    /// Maximum evidence units credited to a single claim under composition.
    /// Bounded so a large retrieval set cannot produce an unbounded citation
    /// list attached to every sentence.
    public let maximumCitations: Int

    public init(maximumCitations: Int = 3) {
        self.maximumCitations = max(1, maximumCitations)
    }

    public func score(
        claim: Claim,
        against evidence: EvidenceSet,
        policy: GroundingPolicy
    ) -> SupportMeasurement {
        let claimTerms = Lexicon.contentTokens(claim.text).map(\.normalized)
        guard !claimTerms.isEmpty, !evidence.isEmpty else {
            return SupportMeasurement(
                coverage: 0,
                citations: [],
                unmatchedLiterals: [],
                distinctSourceCount: 0
            )
        }

        // Unique terms, each weighted once: repeating a word in the claim
        // must not inflate the mass it can earn.
        var weightByTerm: [String: Double] = [:]
        for term in claimTerms where weightByTerm[term] == nil {
            weightByTerm[term] = evidence.idf.weight(for: term)
        }
        // Summation order is fixed by sorting the keys. Floating-point
        // addition is not associative and Swift's `Hasher` is seeded per
        // process, so summing over a `Dictionary` or a `Set` would vary the
        // last ULP of `coverage` between runs -- enough to flip a claim sitting
        // exactly on a threshold. The determinism this package claims has to be
        // real, not nearly real.
        let orderedTerms = weightByTerm.keys.sorted()
        var totalMass: Double = 0
        for term in orderedTerms { totalMass += weightByTerm[term] ?? 0 }
        guard totalMass.isFinite, totalMass > 0 else {
            return SupportMeasurement(
                coverage: 0,
                citations: [],
                unmatchedLiterals: [],
                distinctSourceCount: 0
            )
        }

        let claimLiterals = policy.enforcesNumericLiterals
            ? NumericGuard.literalDetails(in: claim.text)
            : []

        // Per-unit coverage, plus the age filter.
        struct Scored {
            let index: Int
            let coverage: Double
            let matchedTerms: Set<String>
        }
        var scored: [Scored] = []
        var sawFreshCandidate = false
        var sawStaleCandidate = false

        for index in evidence.units.indices {
            guard let unit = evidence.unit(at: index) else { continue }
            let unitTerms = evidence.terms(at: index)
            var matched: Set<String> = []
            var mass: Double = 0
            for term in orderedTerms where unitTerms.contains(term) {
                matched.insert(term)
                mass += weightByTerm[term] ?? 0
            }
            guard mass > 0 else { continue }

            if let horizon = policy.staleEvidenceHorizonSeconds,
               unit.provenance.ageSeconds > horizon {
                sawStaleCandidate = true
                continue
            }
            sawFreshCandidate = true
            scored.append(
                Scored(
                    index: index,
                    coverage: Safe.ratio(mass, totalMass),
                    matchedTerms: matched
                )
            )
        }

        guard !scored.isEmpty else {
            // Nothing was credited, so nothing was *checked*. Reporting every
            // literal in the claim as "uncorroborated" here would be a lie
            // twice over: it mislabels a stale-evidence block and a
            // zero-overlap claim as numeric fabrications, and it poisons the
            // one ledger metric this package tells callers to alert on. The
            // honest answer is that the literal channel had no opinion.
            return SupportMeasurement(
                coverage: 0,
                citations: [],
                unmatchedLiterals: [],
                distinctSourceCount: 0,
                blockedByStaleEvidence: sawStaleCandidate && !sawFreshCandidate
            )
        }

        // Deterministic ordering: coverage desc, then evidence id asc so two
        // units with identical coverage never swap between runs.
        scored.sort { lhs, rhs in
            if lhs.coverage != rhs.coverage { return lhs.coverage > rhs.coverage }
            let leftID = evidence.unit(at: lhs.index)?.id ?? ""
            let rightID = evidence.unit(at: rhs.index)?.id ?? ""
            return leftID < rightID
        }

        let creditedCount = policy.allowsEvidenceComposition
            ? min(maximumCitations, scored.count)
            : 1
        let credited = Array(scored.prefix(creditedCount))

        // Union of matched terms across credited units. Union, not sum: two
        // units both containing "eviction" must not be paid for it twice.
        var unionTerms: Set<String> = []
        for entry in credited { unionTerms.formUnion(entry.matchedTerms) }
        var unionMass: Double = 0
        for term in orderedTerms where unionTerms.contains(term) {
            unionMass += weightByTerm[term] ?? 0
        }
        var coverage = Safe.ratio(unionMass, totalMass)

        // Literal channel. A literal counts as corroborated only by evidence
        // actually being credited for this claim — finding "$4.2M" in some
        // unrelated retrieved chunk is not a citation.
        var creditedLiterals: Set<String> = []
        for entry in credited {
            creditedLiterals.formUnion(evidence.literals(at: entry.index))
        }
        var unmatched: [String] = []
        for literal in claimLiterals
        where !NumericGuard.isSatisfied(
            literal,
            by: creditedLiterals,
            relativeTolerance: policy.numericTolerance
        ) {
            unmatched.append(literal.raw)
        }
        if !unmatched.isEmpty {
            coverage = 0
        }

        var citations: [Citation] = []
        var sources: Set<String> = []
        for entry in credited {
            guard let unit = evidence.unit(at: entry.index) else { continue }
            sources.insert(unit.provenance.sourceID)
            citations.append(
                Citation(
                    evidenceID: unit.id,
                    sourceID: unit.provenance.sourceID,
                    displayName: unit.provenance.displayName,
                    coverage: entry.coverage
                )
            )
        }

        return SupportMeasurement(
            coverage: coverage,
            citations: citations,
            unmatchedLiterals: unmatched,
            distinctSourceCount: sources.count,
            blockedByStaleEvidence: false
        )
    }
}
