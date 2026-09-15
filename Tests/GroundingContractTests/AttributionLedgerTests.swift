import XCTest
@testable import GroundingContract

final class AttributionLedgerTests: XCTestCase {

    private func sampleAnswer() -> VerifiedAnswer {
        GroundingContractEngine.evaluate(
            answer: Fixtures.fabricatedFigureClaim,
            evidence: Fixtures.corpus,
            policy: .observability
        )
    }

    func testRecordsTheUncorroboratedFigureNotJustAPassFail() async {
        let ledger = AttributionLedger()
        let entry = await ledger.record(question: "budget?", answer: sampleAnswer())
        XCTAssertEqual(entry.unmatchedLiterals, ["64"])
        XCTAssertEqual(entry.unsupportedCount, 1)
        XCTAssertEqual(entry.outcome, "annotated(1)")
    }

    func testCountBudgetEvictsOldestFirst() async {
        let ledger = AttributionLedger(maximumEntries: 3)
        for index in 0 ..< 10 {
            await ledger.record(question: "q\(index)", answer: sampleAnswer())
        }
        let entries = await ledger.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.question), ["q7", "q8", "q9"])
        let evicted = await ledger.evictedEntryCount()
        XCTAssertEqual(evicted, 7)
    }

    func testByteBudgetEvictsEvenWhenTheCountBudgetIsNotReached() async {
        let ledger = AttributionLedger(maximumEntries: 1_000, maximumBytes: 400)
        for index in 0 ..< 20 {
            await ledger.record(question: String(repeating: "q", count: 100) + "\(index)", answer: sampleAnswer())
        }
        let entries = await ledger.entries()
        let bytes = await ledger.retainedByteCount()
        XCTAssertLessThan(entries.count, 20)
        XCTAssertLessThanOrEqual(bytes, 400)
        XCTAssertGreaterThan(entries.count, 0)
    }

    func testASingleOversizedEntryIsRetainedRatherThanLoopingForever() async {
        let ledger = AttributionLedger(maximumEntries: 8, maximumBytes: 1)
        await ledger.record(question: String(repeating: "x", count: 5_000), answer: sampleAnswer())
        let entries = await ledger.entries()
        // The byte budget cannot be met by evicting the only entry there is,
        // so the loop must terminate on the count budget instead of spinning.
        XCTAssertEqual(entries.count, 1)
    }

    func testRecentIsBoundsCheckedAtBothEnds() async {
        let ledger = AttributionLedger()
        for index in 0 ..< 3 {
            await ledger.record(question: "q\(index)", answer: sampleAnswer())
        }
        let none = await ledger.recent(0)
        let negative = await ledger.recent(-5)
        let all = await ledger.recent(99)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(negative.isEmpty)
        XCTAssertEqual(all.count, 3)
    }

    func testConcurrentWritersProduceUniqueIdsAndARespectedBound() async {
        let ledger = AttributionLedger(maximumEntries: 50)
        let writers = 200
        // Built once, outside the group: the contention under test is on the
        // ledger actor, not on the (pure) verification path.
        let answer = sampleAnswer()
        var issuedIDs: [Int] = []
        await withTaskGroup(of: Int.self) { group in
            for index in 0 ..< writers {
                group.addTask { [ledger, answer] in
                    await ledger.record(question: "q\(index)", answer: answer).id
                }
            }
            for await id in group { issuedIDs.append(id) }
        }
        // Uniqueness across every id the ledger ever issued, not merely across
        // the 50 that happen to survive eviction.
        XCTAssertEqual(issuedIDs.count, writers)
        XCTAssertEqual(Set(issuedIDs).count, writers, "ids collided under contention")
        XCTAssertEqual(issuedIDs.min(), 0)
        XCTAssertEqual(issuedIDs.max(), writers - 1)

        let entries = await ledger.entries()
        let evicted = await ledger.evictedEntryCount()
        XCTAssertEqual(entries.count, 50)
        XCTAssertEqual(evicted, writers - 50)
        // Ids must still be monotonically increasing in storage order.
        for (previous, next) in zip(entries, entries.dropFirst()) {
            XCTAssertLessThan(previous.id, next.id)
        }
    }

    func testOutcomeDescriptionsCoverEveryCase() {
        XCTAssertEqual(AttributionLedger.describe(.answered), "answered")
        XCTAssertEqual(AttributionLedger.describe(.annotated(unsupportedClaims: 2)), "annotated(2)")
        XCTAssertEqual(
            AttributionLedger.describe(.redacted(removedClaims: 1, removedCharacterRatio: 0.2)),
            "redacted(1)"
        )
        XCTAssertEqual(
            AttributionLedger.describe(.refused(.unsupportedClaims(3))),
            "refused.unsupportedClaims(3)"
        )
        XCTAssertEqual(
            AttributionLedger.describe(.refused(.redactionExceededBudget(attemptedRatio: 0.9))),
            "refused.redactionExceededBudget"
        )
        XCTAssertEqual(
            AttributionLedger.describe(.refused(.nothingSurvivedRedaction)),
            "refused.nothingSurvivedRedaction"
        )
        XCTAssertEqual(AttributionLedger.describe(.refused(.noEvidence)), "refused.noEvidence")
    }
}
