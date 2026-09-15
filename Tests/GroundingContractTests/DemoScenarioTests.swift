import XCTest
@testable import GroundingContract

/// Pins the outcome table published in the companion demo app's README.
///
/// The demo repo has no test target of its own — it is an app, and its CI
/// compiles it rather than running it. Without these assertions the six rows
/// in that README would be prose nobody checks, which is precisely the failure
/// mode this package exists to argue against.
final class DemoScenarioTests: XCTestCase {

    /// Byte-identical to `DemoCorpus.units` in the demo app.
    private var corpus: EvidenceSet {
        EvidenceSet(units: [
            EvidenceUnit(
                id: "cache",
                text: """
                The image cache evicts entries under a 48 MB byte budget using \
                least-recently-used ordering, and refreshes recency on read.
                """,
                provenance: Provenance(
                    sourceID: "spotlight.local", displayName: "Caching notes", ageSeconds: 120
                )
            ),
            EvidenceUnit(
                id: "latency",
                text: """
                Checkout p95 latency measured 420 ms in the September release, and \
                the staged rollout covered 30 percent of devices.
                """,
                provenance: Provenance(
                    sourceID: "wiki.remote", displayName: "Release notes", ageSeconds: 3_600
                )
            ),
            EvidenceUnit(
                id: "incident",
                text: """
                Incident INC-9114 was resolved in 37 minutes after the retry storm \
                was rate limited at the client.
                """,
                provenance: Provenance(
                    sourceID: "spotlight.local", displayName: "Incident log", ageSeconds: 86_400
                )
            )
        ])
    }

    private enum Answer {
        static let mixed = """
        The image cache evicts entries using least-recently-used ordering. \
        Kubernetes autoscaling was disabled for the nightly worker pool.
        """
        static let wrongNumber = "The image cache evicts entries under a 64 MB byte budget."
        static let wrongIdentifier =
            "Incident INC-9115 was resolved in 37 minutes after a retry storm."
        static let grounded = """
        The image cache evicts entries under a 48 MB byte budget. \
        Checkout p95 latency measured 420 ms in the September release.
        """
        static let partial = "The image cache evicts entries using a segmented admission filter."
        static let ungrounded = """
        Kubernetes autoscaling was disabled for the nightly worker pool. \
        Terraform drift was reconciled by the nightly planner job.
        """
    }

    private func run(_ answer: String, _ policy: GroundingPolicy = GroundingPolicy()) -> VerifiedAnswer {
        GroundingContractEngine.evaluate(answer: answer, evidence: corpus, policy: policy)
    }

    func testDefaultStateVisiblyRedacts() {
        // The first thing a user sees on launch. If this became a refusal the
        // app would open on an empty screen.
        let result = run(Answer.mixed)
        guard case .redacted(let removed, let ratio) = result.outcome else {
            return XCTFail("expected redaction, got \(result.outcome)")
        }
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(ratio, 0.4923, accuracy: 5e-4)
        XCTAssertEqual(
            result.text,
            "The image cache evicts entries using least-recently-used ordering."
        )
        XCTAssertEqual(result.verdicts.map(\.status), [.supported, .unsupported])
    }

    func testFullyGroundedAnswerIsReturnedIntact() {
        let result = run(Answer.grounded)
        XCTAssertEqual(result.outcome, .answered)
        XCTAssertEqual(result.text, Answer.grounded)
        XCTAssertEqual(result.verdicts.map(\.status), [.supported, .supported])
    }

    func testSingleClaimFailuresRefuseOnTheRedactionBudget() {
        // All three are one-claim answers, so cutting the claim removes 100%
        // of the answer -- past the 50% budget. Same branch, different reasons,
        // which is exactly what the demo README's table now says.
        for answer in [Answer.wrongNumber, Answer.wrongIdentifier, Answer.partial] {
            let result = run(answer)
            guard case .refused(.redactionExceededBudget(let ratio)) = result.outcome else {
                return XCTFail("expected budget refusal for \(answer), got \(result.outcome)")
            }
            XCTAssertEqual(ratio, 1.0, accuracy: 1e-12)
            XCTAssertEqual(result.text, "")
        }
        XCTAssertEqual(run(Answer.wrongNumber).verdicts.first?.unmatchedLiterals, ["64"])
        XCTAssertEqual(run(Answer.wrongIdentifier).verdicts.first?.unmatchedLiterals, ["inc-9115"])
        XCTAssertEqual(run(Answer.partial).verdicts.first?.status, .weaklySupported)
        XCTAssertEqual(run(Answer.partial).verdicts.first?.coverage ?? -1, 0.407, accuracy: 5e-4)
    }

    func testEveryClaimUngroundedAlsoRefuses() {
        let result = run(Answer.ungrounded)
        guard case .refused(.redactionExceededBudget) = result.outcome else {
            return XCTFail("expected budget refusal, got \(result.outcome)")
        }
        XCTAssertEqual(result.verdicts.map(\.status), [.unsupported, .unsupported])
        XCTAssertEqual(result.verdicts.compactMap(\.reason), [.insufficientCoverage, .insufficientCoverage])
    }

    func testTheNumericToggleIsWhatFlipsTheFabricatedAnswers() {
        // The demo's headline interaction, asserted rather than described.
        let off = GroundingPolicy(enforcesNumericLiterals: false)
        XCTAssertEqual(run(Answer.wrongNumber, off).outcome, .answered)
        XCTAssertEqual(run(Answer.wrongIdentifier, off).outcome, .answered)
        // ...and it changes nothing for the rows that fail on prose coverage.
        XCTAssertEqual(run(Answer.partial, off).outcome, run(Answer.partial).outcome)
        XCTAssertEqual(run(Answer.ungrounded, off).outcome, run(Answer.ungrounded).outcome)
        XCTAssertEqual(run(Answer.mixed, off).outcome, run(Answer.mixed).outcome)
    }

    func testAnnotateShowsEveryVerdictWithoutEnforcing() {
        for answer in [Answer.mixed, Answer.wrongNumber, Answer.partial, Answer.ungrounded] {
            let result = run(answer, .observability)
            guard case .annotated = result.outcome else {
                return XCTFail("expected annotation, got \(result.outcome)")
            }
            XCTAssertEqual(result.text, answer, "annotate must not alter the text")
        }
    }
}
