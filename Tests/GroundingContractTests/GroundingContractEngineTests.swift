import XCTest
@testable import GroundingContract

final class GroundingContractEngineTests: XCTestCase {

    private func verify(
        _ answer: String,
        policy: GroundingPolicy = GroundingPolicy(),
        evidence: EvidenceSet = Fixtures.corpus
    ) -> VerifiedAnswer {
        GroundingContractEngine.evaluate(answer: answer, evidence: evidence, policy: policy)
    }

    func testAGroundedClaimIsSupportedAndCitesTheRightUnit() {
        let result = verify(Fixtures.groundedCacheClaim)
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertEqual(result.verdicts.first?.status, .supported)
        XCTAssertEqual(result.verdicts.first?.citations.first?.evidenceID, "cache")
        XCTAssertEqual(result.outcome, .answered)
    }

    func testAnUngroundedClaimIsRejectedOnCoverage() {
        let result = verify(Fixtures.ungroundedClaim, policy: .observability)
        XCTAssertEqual(result.verdicts.first?.status, .unsupported)
        XCTAssertEqual(result.verdicts.first?.reason, .insufficientCoverage)
    }

    func testFabricatedFigureIsRejectedDespiteNearIdenticalProse() {
        // The point of the package. Same sentence, one wrong number.
        let fabricated = verify(Fixtures.fabricatedFigureClaim, policy: .observability)
        let correct = verify(Fixtures.correctFigureClaim, policy: .observability)

        XCTAssertEqual(correct.verdicts.first?.status, .supported)
        XCTAssertEqual(fabricated.verdicts.first?.status, .unsupported)
        XCTAssertEqual(fabricated.verdicts.first?.reason, .numericMismatch)
        XCTAssertEqual(fabricated.verdicts.first?.unmatchedLiterals, ["64"])
    }

    func testNumericGuardIsLoadBearingNotDecorative() {
        // Mutation proof: turning the literal channel off must change the
        // verdict. If the guard were deleted from the scorer, the first
        // assertion would fail rather than silently still passing.
        let guarded = verify(
            Fixtures.fabricatedFigureClaim,
            policy: GroundingPolicy(enforcesNumericLiterals: true, unsupportedClaimAction: .annotate)
        )
        let unguarded = verify(
            Fixtures.fabricatedFigureClaim,
            policy: GroundingPolicy(enforcesNumericLiterals: false, unsupportedClaimAction: .annotate)
        )
        XCTAssertEqual(guarded.verdicts.first?.status, .unsupported)
        XCTAssertEqual(unguarded.verdicts.first?.status, .supported)
    }

    func testEmptyEvidenceRefusesRatherThanPassingByDefault() {
        let result = verify(Fixtures.groundedCacheClaim, evidence: EvidenceSet(units: []))
        XCTAssertEqual(result.outcome, .refused(.noEvidence))
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.verdicts.first?.reason, .noEvidence)
    }

    func testEmptyEvidenceUnderObservabilityPolicyAnnotatesInstead() {
        let result = verify(
            Fixtures.groundedCacheClaim,
            policy: .observability,
            evidence: EvidenceSet(units: [])
        )
        XCTAssertEqual(result.outcome, .annotated(unsupportedClaims: 1))
        XCTAssertEqual(result.text, Fixtures.groundedCacheClaim)
    }

    func testAnswerWithNoAssertiveClaimsIsPassedThroughUnchanged() {
        let result = verify("...")
        XCTAssertEqual(result.outcome, .answered)
        XCTAssertTrue(result.verdicts.isEmpty)
    }

    func testRedactionRemovesOnlyTheUnsupportedClaim() {
        let answer = "\(Fixtures.groundedCacheClaim) \(Fixtures.ungroundedClaim)"
        let result = verify(answer, policy: GroundingPolicy(unsupportedClaimAction: .redact))
        guard case .redacted(let removed, _) = result.outcome else {
            return XCTFail("expected redaction, got \(result.outcome)")
        }
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(result.text.contains("least-recently-used"))
        XCTAssertFalse(result.text.contains("Kubernetes"))
    }

    func testRedactionNeverInventsWordsTheModelDidNotWrite() {
        let answer = "\(Fixtures.groundedCacheClaim) \(Fixtures.ungroundedClaim)"
        let result = verify(answer, policy: GroundingPolicy(unsupportedClaimAction: .redact))

        // Subsequence alone is a weak property -- returning "" satisfies it --
        // so pin the exact surviving text first, then the ordering property.
        XCTAssertEqual(result.text, Fixtures.groundedCacheClaim)
        XCTAssertFalse(result.text.isEmpty)

        var origin = Array(answer)[...]
        for character in result.text where character != " " {
            guard let index = origin.firstIndex(of: character) else {
                return XCTFail("redacted text introduced '\(character)'")
            }
            origin = origin[(index + 1)...]
        }
    }

    func testRedactionEscalatesToRefusalWhenItWouldGutTheAnswer() {
        // Two unsupported claims against one supported one is well past 50%.
        let answer = """
        \(Fixtures.groundedCacheClaim) \(Fixtures.ungroundedClaim) \
        Terraform drift was reconciled by the nightly planner job.
        """
        let result = verify(answer, policy: GroundingPolicy(unsupportedClaimAction: .redact))
        guard case .refused(.redactionExceededBudget(let ratio)) = result.outcome else {
            return XCTFail("expected budget refusal, got \(result.outcome)")
        }
        XCTAssertGreaterThan(ratio, 0.5)
        XCTAssertEqual(result.text, "")
    }

    func testRefusePolicyRejectsTheWholeAnswerOnASingleFailure() {
        let answer = "\(Fixtures.groundedCacheClaim) \(Fixtures.ungroundedClaim)"
        let result = verify(answer, policy: GroundingPolicy(unsupportedClaimAction: .refuse))
        XCTAssertEqual(result.outcome, .refused(.unsupportedClaims(1)))
        XCTAssertEqual(result.originalText, answer)
    }

    func testStaleEvidenceCannotSupportAClaim() {
        let stale = EvidenceSet(units: [
            Fixtures.unit("cache", Fixtures.cacheText, ageSeconds: 10_000)
        ])
        let fresh = EvidenceSet(units: [
            Fixtures.unit("cache", Fixtures.cacheText, ageSeconds: 10)
        ])
        let policy = GroundingPolicy(
            staleEvidenceHorizonSeconds: 3_600,
            unsupportedClaimAction: .annotate
        )
        XCTAssertEqual(
            GroundingContractEngine
                .evaluate(answer: Fixtures.groundedCacheClaim, evidence: stale, policy: policy)
                .verdicts.first?.reason,
            .staleEvidence
        )
        XCTAssertEqual(
            GroundingContractEngine
                .evaluate(answer: Fixtures.groundedCacheClaim, evidence: fresh, policy: policy)
                .verdicts.first?.status,
            .supported
        )
    }

    func testMinimumDistinctSourcesIsEnforcedSeparatelyFromCoverage() {
        // High coverage from one source is still a single-source answer.
        let policy = GroundingPolicy(
            minimumDistinctSources: 2,
            unsupportedClaimAction: .annotate
        )
        let single = EvidenceSet(units: [Fixtures.unit("cache", Fixtures.cacheText)])
        let verdict = GroundingContractEngine
            .evaluate(answer: Fixtures.groundedCacheClaim, evidence: single, policy: policy)
            .verdicts.first
        XCTAssertEqual(verdict?.status, .unsupported)
        XCTAssertEqual(verdict?.reason, .insufficientDistinctSources)
        XCTAssertGreaterThan(verdict?.coverage ?? 0, 0.5)
    }

    func testWeakSupportIsReportedButStillNotShippable() {
        // Real partial overlap at the default thresholds (0.35 / 0.60): the
        // corpus backs "image cache evicts entries" but says nothing about a
        // segmented admission filter.
        let result = verify(Fixtures.partiallyGroundedClaim, policy: .observability)
        XCTAssertEqual(result.verdicts.first?.status, .weaklySupported)
        XCTAssertEqual(result.verdicts.first?.reason, .insufficientCoverage)
        // Weak is *not* shippable: it still counts against the contract.
        XCTAssertEqual(result.outcome, .annotated(unsupportedClaims: 1))
    }

    func testAnIdentifierFabricationIsCaughtLikeANumericOne() {
        // INC-9115 does not exist; INC-9114 does. Every other word matches.
        let result = verify("Incident INC-9115 was resolved in 37 minutes.", policy: .observability)
        XCTAssertEqual(result.verdicts.first?.status, .unsupported)
        XCTAssertEqual(result.verdicts.first?.reason, .numericMismatch)
        XCTAssertEqual(result.verdicts.first?.unmatchedLiterals, ["inc-9115"])
    }

    func testDuplicateEvidenceIdsAreCollapsedSoCitationsStayUnambiguous() {
        let set = EvidenceSet(units: [
            Fixtures.unit("cache", Fixtures.cacheText),
            Fixtures.unit("cache", "a completely different body of text")
        ])
        XCTAssertEqual(set.units.count, 1)
        XCTAssertEqual(set.units.first?.text, Fixtures.cacheText)
    }

    func testEngineAppliesItsDefaultPolicyAndWritesToTheAttachedLedger() async {
        // The actor path adds two things the static path does not: it falls
        // back to `defaultPolicy` when the caller passes none, and it records
        // the decision. Both are observed here; comparing the two paths'
        // verdicts would not be -- they call the same pure function.
        let ledger = AttributionLedger()
        let engine = GroundingContractEngine(policy: .regulated, ledger: ledger)

        let result = await engine.verify(
            answer: Fixtures.groundedCacheClaim,
            evidence: Fixtures.corpus,
            question: "what is the cache budget?"
        )

        // `.regulated` requires two distinct sources and refuses; the default
        // policy would have called this same claim `supported`.
        XCTAssertEqual(result.outcome, .refused(.unsupportedClaims(1)))
        XCTAssertEqual(result.verdicts.first?.reason, .insufficientDistinctSources)

        let entries = await ledger.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.question, "what is the cache budget?")
        XCTAssertEqual(entries.first?.outcome, "refused.unsupportedClaims(1)")
    }

    func testAnEngineWithNoLedgerStillVerifies() async {
        let engine = GroundingContractEngine(policy: .observability)
        let result = await engine.verify(
            answer: Fixtures.fabricatedFigureClaim,
            evidence: Fixtures.corpus
        )
        XCTAssertEqual(result.verdicts.first?.reason, .numericMismatch)
    }

    func testPublishedCoverageFiguresAreGuardedByAnAssertion() {
        // The README prints these numbers as measurements. Unasserted numbers
        // in a README are decoration: a regression moving 0.407 to 0.55 would
        // otherwise fail nothing. Tolerance is 5e-4 because the README quotes
        // three decimal places.
        func coverage(_ answer: String) -> Double {
            verify(answer, policy: .observability).verdicts.first?.coverage ?? -1
        }
        XCTAssertEqual(coverage(Fixtures.groundedCacheClaim), 1.000, accuracy: 5e-4)
        XCTAssertEqual(coverage(Fixtures.correctFigureClaim), 1.000, accuracy: 5e-4)
        XCTAssertEqual(coverage(Fixtures.fabricatedFigureClaim), 0.000, accuracy: 5e-4)
        XCTAssertEqual(
            coverage("Checkout p95 latency measured 420 ms in the September release."),
            1.000,
            accuracy: 5e-4
        )
        XCTAssertEqual(coverage(Fixtures.partiallyGroundedClaim), 0.407, accuracy: 5e-4)
        XCTAssertEqual(coverage(Fixtures.ungroundedClaim), 0.000, accuracy: 5e-4)
        XCTAssertEqual(
            coverage("Incident INC-9115 was resolved in 37 minutes."),
            0.000,
            accuracy: 5e-4
        )
    }

    func testCitationOrderDoesNotDependOnEvidenceInsertionOrder() {
        // Ranking must be a function of the evidence, not of the order the
        // caller happened to hand it over. (Summation order is fixed by
        // sorting keys in the scorer; that is a source-level property no
        // single-process test can falsify, and the README says so rather than
        // claiming a test proves it.)
        let forwards = Fixtures.corpus
        let backwards = EvidenceSet(units: Fixtures.corpus.units.reversed())
        func citations(_ set: EvidenceSet) -> [String] {
            GroundingContractEngine
                .evaluate(answer: Fixtures.partiallyGroundedClaim, evidence: set, policy: .observability)
                .verdicts.first?.citations.map(\.evidenceID) ?? []
        }
        XCTAssertEqual(citations(forwards), ["cache"])
        XCTAssertEqual(citations(backwards), ["cache"])
    }

    func testStaleEvidenceIsNotReportedAsAFabricatedFigure() {
        // Regression: the no-credited-evidence path used to dump every literal
        // in the claim into `unmatchedLiterals`, so a staleness block looked
        // identical to a hallucinated number in the ledger -- the single metric
        // the package tells callers to alert on.
        let stale = EvidenceSet(units: [
            Fixtures.unit("cache", Fixtures.cacheText, ageSeconds: 10_000)
        ])
        let verdict = GroundingContractEngine.evaluate(
            answer: Fixtures.correctFigureClaim,
            evidence: stale,
            policy: GroundingPolicy(
                staleEvidenceHorizonSeconds: 3_600,
                unsupportedClaimAction: .annotate
            )
        ).verdicts.first
        XCTAssertEqual(verdict?.reason, .staleEvidence)
        XCTAssertEqual(verdict?.unmatchedLiterals, [], "48 is in the evidence; it is not uncorroborated")
    }

    func testAZeroOverlapClaimIsInsufficientCoverageNotNumericMismatch() {
        // A claim sharing no vocabulary with the corpus was being reported as
        // a numeric fabrication purely because it contained a digit.
        let verdict = verify(
            "Terraform drift reconciled 9999 pods overnight.",
            policy: .observability
        ).verdicts.first
        XCTAssertEqual(verdict?.reason, .insufficientCoverage)
        XCTAssertEqual(verdict?.unmatchedLiterals, [])
    }

    func testNothingSurvivedRedactionIsReachableAtAFullRedactionBudget() {
        // At `maximumRedactionRatio == 1` the budget check cannot fire, so the
        // "everything was cut" branch is the one that reports. Below 1 the
        // budget always wins, because removing every claim is by definition a
        // ratio of 1 -- which is why the demo app never shows this cause.
        let result = verify(
            Fixtures.ungroundedClaim,
            policy: GroundingPolicy(unsupportedClaimAction: .redact, maximumRedactionRatio: 1)
        )
        XCTAssertEqual(result.outcome, .refused(.nothingSurvivedRedaction))
        XCTAssertEqual(result.text, "")
    }

    func testDottedVersionNumbersAreVetoedRatherThanIgnored() {
        // `1.2.3` is neither a plain quantity nor a letter-bearing identifier.
        // Before it was routed to the identifier channel it fell through the
        // guard entirely, so "version 1.2.4" passed unvetoed against a corpus
        // saying 1.2.3 -- a silent hole in the package's headline promise.
        let evidence = EvidenceSet(units: [
            Fixtures.unit("release", "The cache rewrite shipped in build 1.2.3 of the client.")
        ])
        let wrong = GroundingContractEngine.evaluate(
            answer: "The cache rewrite shipped in build 1.2.4 of the client.",
            evidence: evidence,
            policy: .observability
        )
        let right = GroundingContractEngine.evaluate(
            answer: "The cache rewrite shipped in build 1.2.3 of the client.",
            evidence: evidence,
            policy: .observability
        )
        XCTAssertEqual(wrong.verdicts.first?.status, .unsupported)
        XCTAssertEqual(wrong.verdicts.first?.reason, .numericMismatch)
        XCTAssertEqual(wrong.verdicts.first?.unmatchedLiterals, ["1.2.4"])
        XCTAssertEqual(right.verdicts.first?.status, .supported)
    }

    func testNegativeAndNonFiniteEvidenceAgeIsNormalisedNotTrusted() {
        let provenance = Provenance(sourceID: "s", displayName: "s", ageSeconds: -5)
        XCTAssertEqual(provenance.ageSeconds, 0)
        XCTAssertEqual(Provenance(sourceID: "s", displayName: "s", ageSeconds: .nan).ageSeconds, 0)
    }

    func testPolicyNormalisesContradictoryThresholds() {
        let policy = GroundingPolicy(supportThreshold: 0.3, weakSupportThreshold: 0.9)
        XCTAssertLessThanOrEqual(policy.weakSupportThreshold, policy.supportThreshold)
        XCTAssertEqual(GroundingPolicy(supportThreshold: .nan).supportThreshold, 0)
        XCTAssertEqual(GroundingPolicy(maximumRedactionRatio: 5).maximumRedactionRatio, 1)
        XCTAssertEqual(GroundingPolicy(minimumDistinctSources: -3).minimumDistinctSources, 1)
    }
}
