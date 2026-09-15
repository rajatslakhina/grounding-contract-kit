//
//  GroundingPolicy.swift
//  GroundingContract
//
//  The contract itself: what "grounded enough to ship" means, as data.
//

/// What to do with a claim the evidence does not support.
public enum UnsupportedClaimAction: String, Sendable, Hashable, CaseIterable {
    /// Return the answer unchanged, with verdicts attached. For telemetry-only
    /// rollouts where you want the measurement before the enforcement.
    case annotate
    /// Excise the unsupported claims and return what survives, unless too much
    /// of the answer disappears (see `maximumRedactionRatio`).
    case redact
    /// Refuse the whole answer the moment any claim fails.
    case refuse
}

/// The enforceable terms of a grounded answer.
public struct GroundingPolicy: Sendable, Hashable {

    /// Minimum evidence coverage, in `0...1`, for a claim to count as
    /// supported.
    public let supportThreshold: Double

    /// Coverage in `weakSupportThreshold ..< supportThreshold` is reported as
    /// weak: real signal, below the bar. Callers that want a two-state world
    /// set this equal to `supportThreshold`.
    public let weakSupportThreshold: Double

    /// Relative tolerance applied to numeric literals. `0` means a figure must
    /// match the source exactly.
    public let numericTolerance: Double

    /// When `false`, the numeric channel is disabled and figures are judged by
    /// prose similarity alone. Provided so the effect of the guard can be
    /// measured rather than asserted — see `testNumericGuardIsLoadBearing`.
    public let enforcesNumericLiterals: Bool

    /// Evidence older than this is not allowed to support a claim. `nil`
    /// disables the check.
    public let staleEvidenceHorizonSeconds: Double?

    /// A claim must be corroborated by at least this many distinct
    /// `sourceID`s. `1` is the normal setting; `2` is what you raise it to for
    /// claims that will be quoted back to a regulator.
    public let minimumDistinctSources: Int

    /// Whether coverage may be accumulated across several evidence units.
    ///
    /// `true` accepts multi-hop claims ("A, and separately B") but also
    /// accepts a claim stitched from fragments that never co-occurred, which
    /// is a real fabrication mode. Default `true`, with the trade-off named.
    public let allowsEvidenceComposition: Bool

    public let unsupportedClaimAction: UnsupportedClaimAction

    /// If redaction would remove more than this fraction of the answer's
    /// assertive characters, the answer is refused instead. Returning a
    /// shredded paragraph is worse than returning nothing.
    public let maximumRedactionRatio: Double

    public init(
        supportThreshold: Double = 0.6,
        weakSupportThreshold: Double = 0.35,
        numericTolerance: Double = 0,
        enforcesNumericLiterals: Bool = true,
        staleEvidenceHorizonSeconds: Double? = nil,
        minimumDistinctSources: Int = 1,
        allowsEvidenceComposition: Bool = true,
        unsupportedClaimAction: UnsupportedClaimAction = .redact,
        maximumRedactionRatio: Double = 0.5
    ) {
        let support = Safe.clamp01(supportThreshold)
        self.supportThreshold = support
        self.weakSupportThreshold = min(Safe.clamp01(weakSupportThreshold), support)
        self.numericTolerance = numericTolerance.isFinite ? max(0, numericTolerance) : 0
        self.enforcesNumericLiterals = enforcesNumericLiterals
        if let horizon = staleEvidenceHorizonSeconds, horizon.isFinite, horizon > 0 {
            self.staleEvidenceHorizonSeconds = horizon
        } else {
            self.staleEvidenceHorizonSeconds = nil
        }
        self.minimumDistinctSources = max(1, minimumDistinctSources)
        self.allowsEvidenceComposition = allowsEvidenceComposition
        self.unsupportedClaimAction = unsupportedClaimAction
        self.maximumRedactionRatio = Safe.clamp01(maximumRedactionRatio)
    }

    /// Telemetry-only: measure without changing what users see.
    public static let observability = GroundingPolicy(unsupportedClaimAction: .annotate)

    /// The setting for an answer that will be read as fact: exact figures,
    /// two independent sources, refuse rather than trim.
    public static let regulated = GroundingPolicy(
        supportThreshold: 0.75,
        weakSupportThreshold: 0.6,
        numericTolerance: 0,
        minimumDistinctSources: 2,
        allowsEvidenceComposition: false,
        unsupportedClaimAction: .refuse
    )
}
