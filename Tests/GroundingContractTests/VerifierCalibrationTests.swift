import XCTest
@testable import GroundingContract

final class VerifierCalibrationTests: XCTestCase {

    /// Golden set: three genuinely grounded claims, three fabrications.
    private var goldenSet: [LabelledClaim] {
        let corpus = Fixtures.corpus
        return [
            LabelledClaim(text: Fixtures.groundedCacheClaim, evidence: corpus, isGrounded: true),
            LabelledClaim(text: Fixtures.correctFigureClaim, evidence: corpus, isGrounded: true),
            LabelledClaim(
                text: "Checkout p95 latency measured 420 ms in the September release.",
                evidence: corpus,
                isGrounded: true
            ),
            LabelledClaim(text: Fixtures.fabricatedFigureClaim, evidence: corpus, isGrounded: false),
            LabelledClaim(text: Fixtures.ungroundedClaim, evidence: corpus, isGrounded: false),
            LabelledClaim(
                text: "Incident INC-9115 was resolved in 37 minutes.",
                evidence: corpus,
                isGrounded: false
            )
        ]
    }

    func testShippingScorerCatchesEveryFabricationInTheGoldenSet() {
        let report = VerifierCalibration.evaluate(samples: goldenSet, policy: GroundingPolicy())
        XCTAssertEqual(report.sampleCount, 6)
        XCTAssertEqual(report.falseNegatives, 0, "a fabrication shipped")
        XCTAssertEqual(report.truePositives, 3)
        XCTAssertEqual(report.falsePositives, 0, "a grounded claim was wrongly rejected")
    }

    func testCalibrationDetectsAGuttedVerifier() {
        // The whole reason the harness exists. A scorer that approves
        // everything must score recall 0 — if it did not, every calibration
        // number this package reports would be worthless.
        let report = VerifierCalibration.evaluate(
            samples: goldenSet,
            policy: GroundingPolicy(),
            scorer: AlwaysSupportsScorer()
        )
        XCTAssertEqual(report.truePositives, 0)
        XCTAssertEqual(report.falseNegatives, 3)
        XCTAssertEqual(report.recall, 0)
        XCTAssertEqual(report.f1, 0)
    }

    func testCalibrationAlsoDetectsAVerifierThatRefusesEverything() {
        // The opposite degenerate case: perfect recall, ruinous precision.
        let report = VerifierCalibration.evaluate(
            samples: goldenSet,
            policy: GroundingPolicy(),
            scorer: NeverSupportsScorer()
        )
        XCTAssertEqual(report.recall, 1)
        XCTAssertEqual(report.falsePositives, 3)
        XCTAssertEqual(report.precision, 0.5, accuracy: 1e-12)
    }

    func testPrecisionAndRecallAreZeroRatherThanOneWhenNothingWasRejected() {
        // A do-nothing verifier must not be flattered by a 0/0 = 1.0 default.
        let report = CalibrationReport(
            threshold: 0.5,
            truePositives: 0,
            falsePositives: 0,
            trueNegatives: 4,
            falseNegatives: 0
        )
        XCTAssertEqual(report.precision, 0)
        XCTAssertEqual(report.recall, 0)
        XCTAssertEqual(report.f1, 0)
        XCTAssertEqual(report.accuracy, 1)
    }

    func testEmptySampleSetProducesZeroesNotNaN() {
        let report = VerifierCalibration.evaluate(samples: [], policy: GroundingPolicy())
        XCTAssertEqual(report.sampleCount, 0)
        XCTAssertTrue(report.accuracy.isFinite)
        XCTAssertEqual(report.accuracy, 0)
        XCTAssertEqual(report.f1, 0)
    }

    func testSweepIsReproducibleAndCoversTheFullThresholdRange() {
        let sweep = VerifierCalibration.sweep(samples: goldenSet, steps: 10)
        XCTAssertEqual(sweep.reports.count, 11)
        XCTAssertEqual(sweep.reports.first?.threshold, 0)
        XCTAssertEqual(sweep.reports.last?.threshold, 1)
        for (previous, next) in zip(sweep.reports, sweep.reports.dropFirst()) {
            XCTAssertLessThan(previous.threshold, next.threshold)
        }
    }

    func testRaisingTheThresholdNeverLosesADetection() {
        // Coverage-based detection is monotone in the threshold: a claim
        // flagged at 0.4 must still be flagged at 0.6. A scorer change that
        // broke this would mean the threshold no longer means what the README
        // says it means.
        let sweep = VerifierCalibration.sweep(samples: goldenSet, steps: 10)
        for (previous, next) in zip(sweep.reports, sweep.reports.dropFirst()) {
            let previousDetected = Safe.add(previous.truePositives, previous.falsePositives)
            let nextDetected = Safe.add(next.truePositives, next.falsePositives)
            XCTAssertLessThanOrEqual(previousDetected, nextDetected)
        }
    }

    func testRecommendedThresholdBreaksTiesTowardRecall() {
        let low = CalibrationReport(
            threshold: 0.2, truePositives: 2, falsePositives: 2,
            trueNegatives: 2, falseNegatives: 2
        )
        let high = CalibrationReport(
            threshold: 0.8, truePositives: 2, falsePositives: 2,
            trueNegatives: 2, falseNegatives: 2
        )
        // Identical F1 and identical recall: the lower threshold wins.
        XCTAssertEqual(CalibrationSweep(reports: [high, low]).recommended?.threshold, 0.2)

        let recallHeavy = CalibrationReport(
            threshold: 0.9, truePositives: 3, falsePositives: 5,
            trueNegatives: 0, falseNegatives: 0
        )
        let balanced = CalibrationReport(
            threshold: 0.1, truePositives: 3, falsePositives: 5,
            trueNegatives: 0, falseNegatives: 0
        )
        XCTAssertEqual(
            CalibrationSweep(reports: [recallHeavy, balanced]).recommended?.threshold,
            0.1
        )
    }

    func testCalibrationIgnoresEnforcementSoItMeasuresTheDetectorNotTheResponse() {
        // `.refuse` and `.redact` must produce the same confusion matrix: the
        // harness measures detection, and enforcement happens afterwards.
        let refusing = VerifierCalibration.evaluate(
            samples: goldenSet,
            policy: GroundingPolicy(unsupportedClaimAction: .refuse)
        )
        let redacting = VerifierCalibration.evaluate(
            samples: goldenSet,
            policy: GroundingPolicy(unsupportedClaimAction: .redact)
        )
        XCTAssertEqual(refusing, redacting)
    }
}
