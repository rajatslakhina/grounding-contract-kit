import GroundingContract

/// Shared corpus. Deliberately small and readable: every expected value in
/// these tests can be re-derived by hand from this text.
enum Fixtures {

    static func unit(
        _ id: String,
        _ text: String,
        source: String = "spotlight.local",
        name: String? = nil,
        ageSeconds: Double = 0
    ) -> EvidenceUnit {
        EvidenceUnit(
            id: id,
            text: text,
            provenance: Provenance(
                sourceID: source,
                displayName: name ?? id,
                ageSeconds: ageSeconds
            )
        )
    }

    static let cacheText = """
    The image cache evicts entries under a 48 MB byte budget using \
    least-recently-used ordering, and refreshes recency on read.
    """

    static let latencyText = """
    Checkout p95 latency measured 420 ms in the September release, and the \
    staged rollout covered 30 percent of devices.
    """

    static let incidentText = """
    Incident INC-9114 was resolved in 37 minutes after the retry storm was \
    rate limited at the client.
    """

    static var corpus: EvidenceSet {
        EvidenceSet(units: [
            unit("cache", cacheText, name: "Caching notes"),
            unit("latency", latencyText, source: "wiki.remote", name: "Release notes"),
            unit("incident", incidentText, name: "Incident log")
        ])
    }

    /// Supported by `cache`.
    static let groundedCacheClaim =
        "The image cache evicts entries using least-recently-used ordering."

    /// Identical prose to `groundedCacheClaim` plus a figure the corpus
    /// contradicts: the corpus says 48 MB.
    static let fabricatedFigureClaim =
        "The image cache evicts entries under a 64 MB byte budget."

    /// Correct figure, same shape as above.
    static let correctFigureClaim =
        "The image cache evicts entries under a 48 MB byte budget."

    /// Half the sentence is in the corpus, half is invented.
    static let partiallyGroundedClaim =
        "The image cache evicts entries using a segmented admission filter."

    /// Shares almost no vocabulary with the corpus.
    static let ungroundedClaim =
        "Kubernetes autoscaling was disabled for the nightly worker pool."
}

/// A verifier with its brain removed: everything is fully supported, always.
///
/// Used to prove that the calibration harness actually detects a gutted
/// verifier. If the harness reported this implementation as good, every
/// calibration number in the README would be meaningless.
struct AlwaysSupportsScorer: SupportScorer {
    func score(
        claim: Claim,
        against evidence: EvidenceSet,
        policy: GroundingPolicy
    ) -> SupportMeasurement {
        SupportMeasurement(
            coverage: 1,
            citations: evidence.units.prefix(1).map {
                Citation(
                    evidenceID: $0.id,
                    sourceID: $0.provenance.sourceID,
                    displayName: $0.provenance.displayName,
                    coverage: 1
                )
            },
            unmatchedLiterals: [],
            distinctSourceCount: max(1, evidence.distinctSourceIDs.count)
        )
    }
}

/// The opposite failure: refuses everything.
struct NeverSupportsScorer: SupportScorer {
    func score(
        claim: Claim,
        against evidence: EvidenceSet,
        policy: GroundingPolicy
    ) -> SupportMeasurement {
        SupportMeasurement(coverage: 0, citations: [], unmatchedLiterals: [], distinctSourceCount: 0)
    }
}
