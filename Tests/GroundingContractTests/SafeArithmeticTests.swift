import XCTest
@testable import GroundingContract

final class SafeArithmeticTests: XCTestCase {

    func testAdditionSaturatesInsteadOfTrapping() {
        XCTAssertEqual(Safe.add(Int.max, 1), Int.max)
        XCTAssertEqual(Safe.add(Int.min, -1), Int.min)
        XCTAssertEqual(Safe.add(2, 3), 5)
    }

    func testMultiplicationSaturatesWithCorrectSign() {
        XCTAssertEqual(Safe.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Safe.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(Safe.multiply(-3, -4), 12)
    }

    func testDivisionHandlesZeroAndTheOneOverflowingCase() {
        XCTAssertEqual(Safe.divide(10, 0, fallback: -1), -1)
        // Int.min / -1 overflows: the positive result is one past Int.max.
        XCTAssertEqual(Safe.divide(Int.min, -1, fallback: 7), 7)
        XCTAssertEqual(Safe.divide(9, 2), 4)
    }

    func testRatioIsZeroForDegenerateDenominators() {
        XCTAssertEqual(Safe.ratio(1, 0), 0)
        XCTAssertEqual(Safe.ratio(1, .nan), 0)
        XCTAssertEqual(Safe.ratio(.nan, 1), 0)
        XCTAssertEqual(Safe.ratio(1, .infinity), 0)
        XCTAssertEqual(Safe.ratio(3, 4), 0.75, accuracy: 1e-12)
    }

    func testRatioClampsAboveOne() {
        // Coverage can never exceed 1 even if a custom scorer miscomputes mass.
        XCTAssertEqual(Safe.ratio(5, 2), 1)
    }

    func testClampMapsNaNToZeroRatherThanLettingComparisonsDecide() {
        XCTAssertEqual(Safe.clamp01(.nan), 0)
        XCTAssertEqual(Safe.clamp01(-1), 0)
        XCTAssertEqual(Safe.clamp01(2), 1)
    }

    func testIntConversionSurvivesNaNInfinityAndOutOfRange() {
        XCTAssertEqual(Safe.int(.nan, fallback: 42), 42)
        XCTAssertEqual(Safe.int(-.infinity, fallback: 42), Int.min)
        XCTAssertEqual(Safe.int(.infinity, fallback: 42), Int.max)
        XCTAssertEqual(Safe.int(Double(Int.max) * 4), Int.max)
        XCTAssertEqual(Safe.int(Double(Int.min) * 4), Int.min)
        XCTAssertEqual(Safe.int(3.7), 3)
    }

    func testIntCeilingIsDerivedFromIntMaxNotAHardcodedLiteral() {
        // On a 32-bit `Int` platform (watchOS) `Double(Int.max)` is ~2.1e9.
        // Anything at or above the platform ceiling must saturate, not wrap.
        let justOver = Double(Int.max).nextUp
        XCTAssertEqual(Safe.int(justOver), Int.max)
    }
}
