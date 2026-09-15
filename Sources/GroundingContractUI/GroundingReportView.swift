//
//  GroundingReportView.swift
//  GroundingContractUI
//
//  The whole file is behind `canImport(SwiftUI)` so the package still builds,
//  and its core is still tested, on Linux CI where SwiftUI does not exist.
//

#if canImport(SwiftUI)
import SwiftUI
import GroundingContract

/// Observable driver for `GroundingReportView`.
///
/// `@MainActor` rather than `Sendable`-and-hop: every property here is read by
/// SwiftUI during layout, so main-actor isolation is the cheapest correct
/// answer. The engine it calls is an `actor` and does its work off this one.
@MainActor
@Observable
public final class GroundingReportModel {
    public private(set) var result: VerifiedAnswer?
    public private(set) var isVerifying = false

    public var answer: String
    public var policy: GroundingPolicy

    private let evidence: EvidenceSet
    private let engine: GroundingContractEngine
    private let question: String
    /// Incremented on every `verify()` entry. A verification that finishes
    /// after a newer one started is discarded.
    private var generation = 0

    public init(
        question: String,
        answer: String,
        evidence: EvidenceSet,
        policy: GroundingPolicy = GroundingPolicy()
    ) {
        self.question = question
        self.answer = answer
        self.evidence = evidence
        self.policy = policy
        self.engine = GroundingContractEngine(policy: policy)
    }

    public func verify() async {
        // `.task(id:)` cancels the previous task, but cancellation is
        // cooperative and the engine does not poll it -- a cancelled call still
        // resumes past the actor hop with a result computed under the *old*
        // policy. Without this token, toggling the contract quickly can leave
        // the UI showing the previous contract's verdict, which in a demo whose
        // entire point is one toggle is the worst possible bug.
        generation += 1
        let token = generation
        let requestedPolicy = policy
        isVerifying = true
        let verified = await engine.verify(
            answer: answer,
            evidence: evidence,
            question: question,
            policy: requestedPolicy
        )
        // Only the newest generation writes -- and it always writes, including
        // the `isVerifying` reset. An early `return` that skipped the reset
        // would leave a spinner running forever when the view is torn down
        // mid-verification.
        guard token == generation else { return }
        result = verified
        isVerifying = false
    }

    /// Every piece of state a verification depends on, as one value.
    ///
    /// `answer` and `policy` are both public and mutable, so a view keying its
    /// `.task` on a hand-picked subset of them shows a silently stale verdict
    /// the moment a consumer changes anything else -- a threshold, a tolerance,
    /// the staleness horizon. Deriving the key from the whole of both removes
    /// the possibility rather than documenting it.
    public var stateKey: String {
        [
            answer,
            "\(policy.supportThreshold)",
            "\(policy.weakSupportThreshold)",
            "\(policy.numericTolerance)",
            "\(policy.enforcesNumericLiterals)",
            "\(policy.staleEvidenceHorizonSeconds ?? -1)",
            "\(policy.minimumDistinctSources)",
            "\(policy.allowsEvidenceComposition)",
            policy.unsupportedClaimAction.rawValue,
            "\(policy.maximumRedactionRatio)"
        ].joined(separator: "|")
    }
}

/// Renders a `VerifiedAnswer`: what shipped, what was cut, and why.
public struct GroundingReportView: View {
    @State private var model: GroundingReportModel

    public init(model: GroundingReportModel) {
        _model = State(wrappedValue: model)
    }

    public var body: some View {
        List {
            Section("Contract") {
                Picker("On unsupported claim", selection: policyBinding) {
                    ForEach(UnsupportedClaimAction.allCases, id: \.self) { action in
                        Text(action.rawValue.capitalized).tag(action)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Enforce numeric literals", isOn: numericBinding)
            }

            if let result = model.result {
                Section("Outcome") {
                    OutcomeRow(outcome: result.outcome)
                    if result.isRefusal {
                        Text("Nothing is shown to the user.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(result.text)
                            .font(.callout)
                    }
                }

                Section("Claims (\(result.verdicts.count))") {
                    ForEach(result.verdicts) { verdict in
                        VerdictRow(verdict: verdict)
                    }
                }
            }

            if model.isVerifying {
                // Shown whether or not a previous result is on screen, so a
                // re-verification after a contract change is visible rather
                // than looking like nothing happened.
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Verifying\u{2026}").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: taskKey) { await model.verify() }
    }

    /// Re-runs verification whenever anything the verdict depends on changes.
    private var taskKey: String { model.stateKey }

    private var policyBinding: Binding<UnsupportedClaimAction> {
        Binding(
            get: { model.policy.unsupportedClaimAction },
            set: { model.policy = model.policy.with(unsupportedClaimAction: $0) }
        )
    }

    private var numericBinding: Binding<Bool> {
        Binding(
            get: { model.policy.enforcesNumericLiterals },
            set: { model.policy = model.policy.with(enforcesNumericLiterals: $0) }
        )
    }
}

struct OutcomeRow: View {
    let outcome: ContractOutcome

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(tint)
    }

    private var title: String {
        switch outcome {
        case .answered:
            return "Answered — every claim cited"
        case .annotated(let count):
            return "Annotated — \(count) claim(s) flagged, nothing removed"
        case .redacted(let removed, let ratio):
            let percent = Safe.int((ratio * 100).rounded())
            return "Redacted — \(removed) claim(s) removed (\(percent)% of the answer)"
        case .refused(let cause):
            switch cause {
            case .unsupportedClaims(let count):
                return "Refused — \(count) unsupported claim(s)"
            case .redactionExceededBudget(let ratio):
                let percent = Safe.int((ratio * 100).rounded())
                return "Refused — redaction would remove \(percent)% of the answer"
            case .nothingSurvivedRedaction:
                return "Refused — no claim survived redaction"
            case .noEvidence:
                return "Refused — no evidence retrieved"
            }
        }
    }

    private var symbol: String {
        switch outcome {
        case .answered: return "checkmark.seal"
        case .annotated: return "exclamationmark.bubble"
        case .redacted: return "scissors"
        case .refused: return "hand.raised"
        }
    }

    private var tint: Color {
        switch outcome {
        case .answered: return .green
        case .annotated: return .orange
        case .redacted: return .orange
        case .refused: return .red
        }
    }
}

struct VerdictRow: View {
    let verdict: ClaimVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(verdict.claim.text).font(.callout)
            }
            HStack(spacing: 8) {
                Text("coverage \(percentText)")
                if let reason = verdict.reason {
                    Text(reason.rawValue)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !verdict.unmatchedLiterals.isEmpty {
                Text("uncorroborated figures: \(verdict.unmatchedLiterals.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if !verdict.citations.isEmpty {
                Text(verdict.citations.map(\.displayName).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 2)
    }

    private var percentText: String {
        "\(Safe.int((verdict.coverage * 100).rounded()))%"
    }

    private var symbol: String {
        switch verdict.status {
        case .supported: return "checkmark.circle.fill"
        case .weaklySupported: return "questionmark.circle.fill"
        case .unsupported: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch verdict.status {
        case .supported: return .green
        case .weaklySupported: return .orange
        case .unsupported: return .red
        }
    }
}

extension GroundingPolicy {
    /// Copy-with helpers, because `GroundingPolicy` is a value type whose
    /// initialiser normalises every field — mutating a stored property in
    /// place would skip that normalisation.
    public func with(unsupportedClaimAction: UnsupportedClaimAction) -> GroundingPolicy {
        GroundingPolicy(
            supportThreshold: supportThreshold,
            weakSupportThreshold: weakSupportThreshold,
            numericTolerance: numericTolerance,
            enforcesNumericLiterals: enforcesNumericLiterals,
            staleEvidenceHorizonSeconds: staleEvidenceHorizonSeconds,
            minimumDistinctSources: minimumDistinctSources,
            allowsEvidenceComposition: allowsEvidenceComposition,
            unsupportedClaimAction: unsupportedClaimAction,
            maximumRedactionRatio: maximumRedactionRatio
        )
    }

    public func with(enforcesNumericLiterals: Bool) -> GroundingPolicy {
        GroundingPolicy(
            supportThreshold: supportThreshold,
            weakSupportThreshold: weakSupportThreshold,
            numericTolerance: numericTolerance,
            enforcesNumericLiterals: enforcesNumericLiterals,
            staleEvidenceHorizonSeconds: staleEvidenceHorizonSeconds,
            minimumDistinctSources: minimumDistinctSources,
            allowsEvidenceComposition: allowsEvidenceComposition,
            unsupportedClaimAction: unsupportedClaimAction,
            maximumRedactionRatio: maximumRedactionRatio
        )
    }
}
#endif
