import XCTest
@testable import GroundingContract

final class NumericGuardTests: XCTestCase {

    func testCanonicalNumberStripsLeadingAndTrailingZerosWithoutFloatRoundTrip() {
        XCTAssertEqual(NumericGuard.canonicalNumber("007"), "7")
        XCTAssertEqual(NumericGuard.canonicalNumber("4.50"), "4.5")
        XCTAssertEqual(NumericGuard.canonicalNumber("4.000"), "4")
        XCTAssertEqual(NumericGuard.canonicalNumber("0"), "0")
        XCTAssertEqual(NumericGuard.canonicalNumber("000"), "0")
    }

    func testHugeIntegersAreNotCollapsedByFloatingPointPrecision() {
        // A `Double` round trip would map both of these to 1e19 and declare a
        // fabricated figure "supported".
        let a = NumericGuard.canonicalNumber("10000000000000000001")
        let b = NumericGuard.canonicalNumber("10000000000000000002")
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
    }

    func testMixedTokensAreIdentifiersAndPureDigitsAreNumbers() {
        XCTAssertEqual(NumericGuard.classify("inc-9114")?.kind, .identifier)
        XCTAssertEqual(NumericGuard.classify("v1.2.3")?.kind, .identifier)
        XCTAssertEqual(NumericGuard.classify("2026-09-15")?.kind, .identifier)
        XCTAssertEqual(NumericGuard.classify("420")?.kind, .number)
        XCTAssertNil(NumericGuard.classify("cache"))
    }

    func testLiteralExtractionFindsFiguresAndIdentifiersInProse() {
        let literals = NumericGuard.literals(in: Fixtures.incidentText)
        XCTAssertTrue(literals.contains("inc-9114"))
        XCTAssertTrue(literals.contains("37"))
        XCTAssertFalse(literals.contains("incident"))
    }

    func testExactMatchIsRequiredWhenToleranceIsZero() {
        guard let claim = NumericGuard.classify("64") else { return XCTFail("not classified") }
        XCTAssertFalse(
            NumericGuard.isSatisfied(claim, by: ["48", "420"], relativeTolerance: 0)
        )
        XCTAssertTrue(
            NumericGuard.isSatisfied(claim, by: ["64"], relativeTolerance: 0)
        )
    }

    func testToleranceIsRelativeAndOptIn() {
        guard let claim = NumericGuard.classify("100") else { return XCTFail("not classified") }
        // 5% of 102 is 5.1, so 100 is inside the band.
        XCTAssertTrue(NumericGuard.isSatisfied(claim, by: ["102"], relativeTolerance: 0.05))
        XCTAssertFalse(NumericGuard.isSatisfied(claim, by: ["102"], relativeTolerance: 0.01))
    }

    func testIdentifiersNeverBenefitFromNumericTolerance() {
        // INC-9114 and INC-9115 are different incidents, not a rounding error.
        guard let claim = NumericGuard.classify("inc-9114") else { return XCTFail("not classified") }
        XCTAssertFalse(
            NumericGuard.isSatisfied(claim, by: ["inc-9115"], relativeTolerance: 0.9)
        )
    }

    func testNonFiniteToleranceIsTreatedAsZero() {
        guard let claim = NumericGuard.classify("100") else { return XCTFail("not classified") }
        XCTAssertFalse(NumericGuard.isSatisfied(claim, by: ["999"], relativeTolerance: .nan))
        XCTAssertFalse(NumericGuard.isSatisfied(claim, by: ["999"], relativeTolerance: .infinity))
    }

    func testThousandsSeparatedAndPlainFiguresAreTheSameLiteral() {
        // Both sides pinned to a literal expectation, not merely to each
        // other: a `literals(in:)` stubbed to return `[]` would satisfy an
        // equality-only assertion.
        XCTAssertEqual(NumericGuard.literals(in: "the budget was 4,200 units"), ["4200"])
        XCTAssertEqual(NumericGuard.literals(in: "the budget was 4200 units"), ["4200"])
    }

    func testCommasThatAreNotThousandsSeparatorsDoNotFabricateFigures() {
        // "Sections 1,2 and 3" must not produce the figure 12 -- a number
        // nobody wrote, which the guard would then demand the evidence
        // corroborate, rejecting a true claim.
        XCTAssertEqual(NumericGuard.literals(in: "Sections 1,2 and 3 were updated"), ["1", "2", "3"])
        XCTAssertEqual(NumericGuard.literals(in: "Rows 10,11 changed"), ["10", "11"])
        // Four digits after the comma is not a thousands group either.
        XCTAssertEqual(NumericGuard.literals(in: "ids 4,20003"), ["4", "20003"])
        // A real thousands group still collapses, including a chained one.
        XCTAssertEqual(NumericGuard.literals(in: "1,234,567 records"), ["1234567"])
    }

    func testToleranceDoesNotPretendToUnderstandScaleWords() {
        // The documented limitation, pinned: "4.2 million" is the literal 4.2,
        // and no sane tolerance matches it against 4215000.
        guard let claim = NumericGuard.classify("4.2") else { return XCTFail("not classified") }
        XCTAssertFalse(NumericGuard.isSatisfied(claim, by: ["4215000"], relativeTolerance: 0.5))
        // The case tolerance *is* for: same order of magnitude, model rounded.
        guard let rounded = NumericGuard.classify("420") else { return XCTFail("not classified") }
        XCTAssertTrue(NumericGuard.isSatisfied(rounded, by: ["418"], relativeTolerance: 0.01))
    }

    func testDottedVersionTokensAreClassifiedAsIdentifiers() {
        XCTAssertEqual(NumericGuard.classify("1.2.3")?.kind, .identifier)
        XCTAssertEqual(NumericGuard.classify("1.2.3")?.canonical, "1.2.3")
    }
}
