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
        // Every surviving character must appear, in order, in the original.
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

    func testEngineActorPathMatchesThePureStaticPath() async {
        let engine = GroundingContractEngine(policy: .observability)
        let viaActor = await engine.verify(
            answer: Fixtures.fabricatedFigureClaim,
            evidence: Fixtures.corpus,
            question: "what is the cache budget?"
        )
        let viaStatic = verify(Fixtures.fabricatedFigureClaim, policy: .observability)
        XCTAssertEqual(viaActor.verdicts.first?.status, viaStatic.verdicts.first?.status)
        XCTAssertEqual(viaActor.verdicts.first?.reason, viaStatic.verdicts.first?.reason)
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
