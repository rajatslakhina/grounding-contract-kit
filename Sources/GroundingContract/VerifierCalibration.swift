//
//  VerifierCalibration.swift
//  GroundingContract
//
//  Measuring the verifier, because a verifier you have not measured is a
//  second unverified component sitting in front of the first one.
//

/// One labelled example: a claim, the evidence it was shown, and whether a
/// human says the evidence actually supports it.
public struct LabelledClaim: Sendable {
    public let text: String
    public let evidence: EvidenceSet
    /// Ground truth. `false` means the claim is a fabrication relative to this
    /// evidence and *must* be caught.
    public let isGrounded: Bool

    public init(text: String, evidence: EvidenceSet, isGrounded: Bool) {
        self.text = text
        self.evidence = evidence
        self.isGrounded = isGrounded
    }
}

/// Confusion matrix and derived rates at one threshold.
///
/// The positive class is **"detected as ungrounded"**, chosen deliberately:
/// the expensive error is a fabrication that ships, so recall on this class is
/// the number that matters and is the one a reader should look at first.
public struct CalibrationReport: Sendable, Hashable {
    public let threshold: Double
    /// Ungrounded, and caught.
    public let truePositives: Int
    /// Grounded, but wrongly rejected — the cost of the contract, paid in
    /// useful answers the user never sees.
    public let falsePositives: Int
    /// Grounded, and passed.
    public let trueNegatives: Int
    /// Ungrounded, and shipped anyway. The failure the package exists to stop.
    public let falseNegatives: Int

    public init(
        threshold: Double,
        truePositives: Int,
        falsePositives: Int,
        trueNegatives: Int,
        falseNegatives: Int
    ) {
        self.threshold = Safe.clamp01(threshold)
        self.truePositives = max(0, truePositives)
        self.falsePositives = max(0, falsePositives)
        self.trueNegatives = max(0, trueNegatives)
        self.falseNegatives = max(0, falseNegatives)
    }

    public var sampleCount: Int {
        Safe.add(Safe.add(truePositives, falsePositives), Safe.add(trueNegatives, falseNegatives))
    }

    /// Of the claims we rejected, how many deserved it. `0` when nothing was
    /// rejected — reporting 1.0 for "rejected nothing, was never wrong" would
    /// make a do-nothing verifier look perfect.
    public var precision: Double {
        Safe.ratio(Double(truePositives), Double(Safe.add(truePositives, falsePositives)))
    }

    /// Of the fabrications present, how many we caught. `0` when the sample
    /// contains no fabrications, for the same reason.
    public var recall: Double {
        Safe.ratio(Double(truePositives), Double(Safe.add(truePositives, falseNegatives)))
    }

    public var f1: Double {
        let denominator = precision + recall
        guard denominator > 0 else { return 0 }
        return Safe.ratio(2 * precision * recall, denominator)
    }

    public var accuracy: Double {
        Safe.ratio(Double(Safe.add(truePositives, trueNegatives)), Double(sampleCount))
    }
}

/// A sweep across candidate thresholds.
public struct CalibrationSweep: Sendable {
    public let reports: [CalibrationReport]

    public init(reports: [CalibrationReport]) {
        self.reports = reports
    }

    /// Best threshold by F1, breaking ties toward **higher recall** and then
    /// toward the lower threshold. Ties are common on small golden sets, and
    /// breaking them arbitrarily is how a calibration result stops being
    /// reproducible.
    public var recommended: CalibrationReport? {
        reports.max { lhs, rhs in
            if lhs.f1 != rhs.f1 { return lhs.f1 < rhs.f1 }
            if lhs.recall != rhs.recall { return lhs.recall < rhs.recall }
            return lhs.threshold > rhs.threshold
        }
    }
}

/// Runs a `SupportScorer` against a labelled set.
public enum VerifierCalibration {

    /// Scores every sample once at `policy.supportThreshold`.
    public static func evaluate(
        samples: [LabelledClaim],
        policy: GroundingPolicy,
        scorer: any SupportScorer = LexicalEntailmentScorer(),
        decomposer: any ClaimDecomposer = SentenceClaimDecomposer()
    ) -> CalibrationReport {
        var truePositives = 0
        var falsePositives = 0
        var trueNegatives = 0
        var falseNegatives = 0

        for sample in samples {
            let verified = GroundingContractEngine.evaluate(
                answer: sample.text,
                evidence: sample.evidence,
                policy: GroundingPolicy(
                    supportThreshold: policy.supportThreshold,
                    weakSupportThreshold: policy.weakSupportThreshold,
                    numericTolerance: policy.numericTolerance,
                    enforcesNumericLiterals: policy.enforcesNumericLiterals,
                    staleEvidenceHorizonSeconds: policy.staleEvidenceHorizonSeconds,
                    minimumDistinctSources: policy.minimumDistinctSources,
                    allowsEvidenceComposition: policy.allowsEvidenceComposition,
                    // Force annotation so enforcement never hides a verdict:
                    // calibration measures the *detector*, not the response.
                    unsupportedClaimAction: .annotate,
                    maximumRedactionRatio: policy.maximumRedactionRatio
                ),
                decomposer: decomposer,
                scorer: scorer
            )
            // A sample counts as "detected as ungrounded" when any claim in it
            // failed to reach `supported`. A sample with no assertive claims
            // is never flagged, which is correct: it asserted nothing.
            let flagged = verified.verdicts.contains { $0.status != .supported }

            switch (sample.isGrounded, flagged) {
            case (false, true): truePositives = Safe.add(truePositives, 1)
            case (true, true): falsePositives = Safe.add(falsePositives, 1)
            case (true, false): trueNegatives = Safe.add(trueNegatives, 1)
            case (false, false): falseNegatives = Safe.add(falseNegatives, 1)
            }
        }

        return CalibrationReport(
            threshold: policy.supportThreshold,
            truePositives: truePositives,
            falsePositives: falsePositives,
            trueNegatives: trueNegatives,
            falseNegatives: falseNegatives
        )
    }

    /// Evaluates at `steps + 1` evenly spaced thresholds from 0 to 1.
    ///
    /// Thresholds are generated from integer division so the sweep is
    /// reproducible and never accumulates floating-point drift.
    public static func sweep(
        samples: [LabelledClaim],
        basePolicy: GroundingPolicy = GroundingPolicy(),
        steps: Int = 20,
        scorer: any SupportScorer = LexicalEntailmentScorer(),
        decomposer: any ClaimDecomposer = SentenceClaimDecomposer()
    ) -> CalibrationSweep {
        let boundedSteps = min(max(1, steps), 1000)
        var reports: [CalibrationReport] = []
        reports.reserveCapacity(Safe.add(boundedSteps, 1))
        for step in 0 ... boundedSteps {
            let threshold = Safe.ratio(Double(step), Double(boundedSteps))
            let policy = GroundingPolicy(
                supportThreshold: threshold,
                weakSupportThreshold: threshold,
                numericTolerance: basePolicy.numericTolerance,
                enforcesNumericLiterals: basePolicy.enforcesNumericLiterals,
                staleEvidenceHorizonSeconds: basePolicy.staleEvidenceHorizonSeconds,
                minimumDistinctSources: basePolicy.minimumDistinctSources,
                allowsEvidenceComposition: basePolicy.allowsEvidenceComposition,
                unsupportedClaimAction: .annotate,
                maximumRedactionRatio: basePolicy.maximumRedactionRatio
            )
            reports.append(evaluate(samples: samples, policy: policy, scorer: scorer, decomposer: decomposer))
        }
        return CalibrationSweep(reports: reports)
    }
}
