import XCTest
@testable import GroundingContract

/// Everything about crediting more than one evidence unit.
///
/// These exist because the rest of the suite could not see any of it: against
/// the single-topic fixture corpus every claim overlaps exactly one unit, so
/// `allowsEvidenceComposition`, `maximumCitations`, union-not-sum and the
/// citation tie-break were all unfalsifiable — and `GroundingPolicy.regulated`
/// was able to ship in a state where it refused every possible answer without
/// a single test noticing.
final class EvidenceCompositionTests: XCTestCase {

    func testCompositionCreditsSeveralUnitsAndDisablingItCreditsExactlyOne() {
        let composed = GroundingContractEngine.evaluate(
            answer: Fixtures.twoHopClaim,
            evidence: Fixtures.splitCorpus,
            policy: GroundingPolicy(unsupportedClaimAction: .annotate)
        ).verdicts.first
        let single = GroundingContractEngine.evaluate(
            answer: Fixtures.twoHopClaim,
            evidence: Fixtures.splitCorpus,
            policy: GroundingPolicy(allowsEvidenceComposition: false, unsupportedClaimAction: .annotate)
        ).verdicts.first

        XCTAssertEqual(composed?.citations.map(\.evidenceID), ["budget", "ordering"])
        XCTAssertEqual(composed?.status, .supported)
        XCTAssertEqual(composed?.coverage ?? -1, 1.0, accuracy: 1e-9)

        // Half the claim's IDF mass lives in each unit, so refusing to compose
        // halves the score and drops the claim below the bar.
        XCTAssertEqual(single?.citations.map(\.evidenceID), ["budget"])
        XCTAssertEqual(single?.status, .weaklySupported)
        XCTAssertEqual(single?.coverage ?? -1, 0.5, accuracy: 1e-9)
    }

    func testMaximumCitationsCapsTheCitationList() {
        let claim = """
        The image cache byte budget is 48 MB, eviction uses least-recently-used \
        ordering, and recency is refreshed on read.
        """
        func citations(max: Int) -> [String] {
            LexicalEntailmentScorer(maximumCitations: max)
                .score(
                    claim: Claim(id: 0, text: claim, start: 0, length: claim.count),
                    against: Fixtures.splitCorpus,
                    policy: GroundingPolicy()
                )
                .citations.map(\.evidenceID)
        }
        XCTAssertEqual(citations(max: 3).count, 3)
        XCTAssertEqual(citations(max: 2).count, 2)
        XCTAssertEqual(citations(max: 1).count, 1)
        // Degenerate input is clamped, not trusted.
        XCTAssertEqual(citations(max: 0).count, 1)
        XCTAssertEqual(citations(max: -4).count, 1)
    }

    func testMatchedTermsAreUnionedAcrossUnitsNotSummed() {
        // Both units contain "eviction"; each adds one term of its own. The
        // claim has four content terms, so the union covers three of four.
        // Summing would pay for "eviction" twice and push coverage to 1.0.
        let evidence = EvidenceSet(units: [
            Fixtures.unit("left", "Eviction throttling engaged.", source: "a"),
            Fixtures.unit("right", "Eviction hysteresis engaged.", source: "b")
        ])
        let verdict = GroundingContractEngine.evaluate(
            answer: "Eviction throttling and hysteresis and prefetching engaged.",
            evidence: evidence,
            policy: .observability
        ).verdicts.first
        XCTAssertEqual(verdict?.citations.count, 2)
        let coverage = verdict?.coverage ?? -1
        let perUnitSum = (verdict?.citations.map(\.coverage) ?? []).reduce(0, +)
        // The discriminating assertion: the two units' individual coverages add
        // up to strictly more than the composed coverage, because "eviction"
        // is in both and is paid for once. Replace the union with a sum and
        // these two become equal.
        XCTAssertGreaterThan(perUnitSum, coverage + 1e-6)
        XCTAssertLessThan(coverage, 1.0, "double-counting a shared term would saturate this")
        XCTAssertGreaterThan(coverage, 0.3)
    }

    func testEqualCoverageCitationsAreOrderedByEvidenceIDNotByInputOrder() {
        // Two byte-identical units score identically. Without the tie-break
        // the citation order would follow whatever order the caller happened
        // to pass, and a published citation list would not be reproducible.
        func order(_ units: [EvidenceUnit]) -> [String] {
            GroundingContractEngine.evaluate(
                answer: Fixtures.groundedCacheClaim,
                evidence: EvidenceSet(units: units),
                policy: .observability
            ).verdicts.first?.citations.map(\.evidenceID) ?? []
        }
        let b = Fixtures.unit("b-unit", Fixtures.cacheText, source: "s1")
        let a = Fixtures.unit("a-unit", Fixtures.cacheText, source: "s2")
        XCTAssertEqual(order([b, a]), ["a-unit", "b-unit"])
        XCTAssertEqual(order([a, b]), ["a-unit", "b-unit"])
    }

    func testRegulatedPolicyIsSatisfiable() {
        // Regression, and a sharp one: `.regulated` shipped with
        // `minimumDistinctSources: 2` AND `allowsEvidenceComposition: false`,
        // which meant exactly one unit was ever credited and the two-source
        // requirement could never be met. It refused every possible answer.
        let result = GroundingContractEngine.evaluate(
            answer: Fixtures.twoHopClaim,
            evidence: Fixtures.splitCorpus,
            policy: .regulated
        )
        XCTAssertEqual(result.outcome, .answered)
        XCTAssertEqual(result.verdicts.first?.status, .supported)
        XCTAssertEqual(Set(result.verdicts.first?.citations.map(\.sourceID) ?? []).count, 2)
    }

    func testRegulatedPolicyStillRefusesASingleSourceAnswer() {
        // The requirement is real, not merely satisfiable.
        let oneSource = EvidenceSet(units: [
            Fixtures.unit("budget", Fixtures.budgetText, source: "only"),
            Fixtures.unit("ordering", Fixtures.orderingText, source: "only")
        ])
        let result = GroundingContractEngine.evaluate(
            answer: Fixtures.twoHopClaim,
            evidence: oneSource,
            policy: .regulated
        )
        XCTAssertEqual(result.outcome, .refused(.unsupportedClaims(1)))
        XCTAssertEqual(result.verdicts.first?.reason, .insufficientDistinctSources)
        XCTAssertEqual(result.verdicts.first?.coverage ?? -1, 1.0, accuracy: 1e-9)
    }

    func testRequiringTwoSourcesForcesCompositionOn() {
        // The initialiser refuses to build the unsatisfiable combination.
        let policy = GroundingPolicy(
            minimumDistinctSources: 2,
            allowsEvidenceComposition: false
        )
        XCTAssertTrue(policy.allowsEvidenceComposition)
        // ...and leaves the caller's choice alone when one source is enough.
        XCTAssertFalse(
            GroundingPolicy(minimumDistinctSources: 1, allowsEvidenceComposition: false)
                .allowsEvidenceComposition
        )
    }
}
