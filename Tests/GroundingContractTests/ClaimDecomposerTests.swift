import XCTest
@testable import GroundingContract

final class ClaimDecomposerTests: XCTestCase {

    private let decomposer = SentenceClaimDecomposer()

    func testSplitsOnSentenceTerminators() {
        let claims = decomposer.decompose("The cache is warm. The queue is empty. Retries stopped.")
        XCTAssertEqual(claims.count, 3)
        XCTAssertEqual(claims.map(\.text), [
            "The cache is warm.",
            "The queue is empty.",
            "Retries stopped."
        ])
    }

    func testDecimalPointsDoNotEndASentence() {
        let claims = decomposer.decompose("Latency was 3.5 ms at p95. That is within budget.")
        XCTAssertEqual(claims.count, 2)
        XCTAssertTrue(claims[0].text.contains("3.5"))
    }

    func testKnownAbbreviationsDoNotEndASentence() {
        let claims = decomposer.decompose("Use a cap, e.g. 48 MB, on disk. Then evict.")
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims[0].text, "Use a cap, e.g. 48 MB, on disk.")
    }

    func testDotsInsideBacktickedCodeDoNotEndASentence() {
        let claims = decomposer.decompose("Call `store.evict.now()` first. Then read.")
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims[0].text, "Call `store.evict.now()` first.")
    }

    func testBlankLinesBreakClaimsEvenWithoutPunctuation() {
        let claims = decomposer.decompose("Cache budget 48 MB\n\nRollout 30 percent")
        XCTAssertEqual(claims.count, 2)
    }

    func testNonAssertiveFragmentsAreDroppedAndIdsStayContiguous() {
        let claims = decomposer.decompose("The. A. The cache evicts entries.")
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims[0].id, 0)
    }

    func testEmptyAndWhitespaceOnlyAnswersProduceNoClaims() {
        XCTAssertTrue(decomposer.decompose("").isEmpty)
        XCTAssertTrue(decomposer.decompose("   \n\n  ").isEmpty)
    }

    func testRecordedSpansAddressTheOriginalStringExactly() {
        // The whole redaction design rests on these offsets being real. If a
        // span were off by one, redaction would splice out the wrong
        // characters — which no status assertion anywhere else would catch.
        let answer = "The cache is warm.  Latency was 3.5 ms. Retries stopped.\n\nDone here."
        let characters = Array(answer)
        for claim in decomposer.decompose(answer) {
            XCTAssertLessThanOrEqual(claim.range.upperBound, characters.count)
            let slice = String(characters[claim.range])
            XCTAssertEqual(slice, claim.text)
        }
    }

    func testClaimsAreInAscendingNonOverlappingOrder() {
        let claims = decomposer.decompose("One thing here. Two things there. Three things beyond.")
        for (previous, next) in zip(claims, claims.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.range.upperBound, next.range.lowerBound)
        }
    }

    func testSingleLetterInitialsDoNotSplit() {
        let claims = decomposer.decompose("Reviewed by J. Doe for the release. Shipped.")
        XCTAssertEqual(claims.count, 2)
    }
}
