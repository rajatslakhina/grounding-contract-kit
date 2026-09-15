//
//  AttributionLedger.swift
//  GroundingContract
//
//  A bounded audit trail of grounding decisions.
//

/// One recorded decision.
public struct LedgerEntry: Sendable, Hashable, Identifiable {
    /// Monotonic sequence number assigned by the ledger.
    public let id: Int
    public let question: String
    public let claimCount: Int
    public let unsupportedCount: Int
    public let outcome: String
    public let citedEvidenceIDs: [String]
    /// Literals the verifier could not corroborate. This is the field that
    /// makes the ledger worth keeping: a spike here is a retrieval regression
    /// or a model regression, and it is visible before a user complains.
    public let unmatchedLiterals: [String]

    public init(
        id: Int,
        question: String,
        claimCount: Int,
        unsupportedCount: Int,
        outcome: String,
        citedEvidenceIDs: [String],
        unmatchedLiterals: [String]
    ) {
        self.id = id
        self.question = question
        self.claimCount = claimCount
        self.unsupportedCount = unsupportedCount
        self.outcome = outcome
        self.citedEvidenceIDs = citedEvidenceIDs
        self.unmatchedLiterals = unmatchedLiterals
    }

    /// Approximate retained size, used for the byte budget.
    var approximateByteCount: Int {
        var total = question.utf8.count
        total = Safe.add(total, outcome.utf8.count)
        for value in citedEvidenceIDs { total = Safe.add(total, value.utf8.count) }
        for value in unmatchedLiterals { total = Safe.add(total, value.utf8.count) }
        // Fixed overhead for the four integers and array boxes.
        return Safe.add(total, 64)
    }
}

/// Append-only, bounded audit log.
///
/// Two budgets, both enforced, because either one alone leaks. A count budget
/// alone is unbounded in memory when questions are long; a byte budget alone
/// lets a flood of tiny entries push out the ones that mattered. Oldest
/// entries are evicted first — an audit trail that drops the *newest* decision
/// is worse than useless during an incident.
public actor AttributionLedger {
    public let maximumEntries: Int
    public let maximumBytes: Int

    private var storage: [LedgerEntry] = []
    private var retainedBytes = 0
    private var nextID = 0
    private var evictedCount = 0

    public init(maximumEntries: Int = 256, maximumBytes: Int = 256 * 1024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    /// Records a decision and returns the entry, with its assigned id.
    @discardableResult
    public func record(
        question: String,
        answer: VerifiedAnswer
    ) -> LedgerEntry {
        var unmatched: [String] = []
        for verdict in answer.verdicts {
            unmatched.append(contentsOf: verdict.unmatchedLiterals)
        }
        let entry = LedgerEntry(
            id: nextID,
            question: question,
            claimCount: answer.verdicts.count,
            unsupportedCount: answer.unsupportedCount,
            outcome: Self.describe(answer.outcome),
            citedEvidenceIDs: answer.citedEvidenceIDs,
            unmatchedLiterals: unmatched
        )
        nextID = Safe.add(nextID, 1)
        storage.append(entry)
        retainedBytes = Safe.add(retainedBytes, entry.approximateByteCount)
        evictIfNeeded()
        return entry
    }

    /// Entries oldest-first.
    public func entries() -> [LedgerEntry] { storage }

    /// Most recent `count` entries, newest last. Bounds-checked.
    public func recent(_ count: Int) -> [LedgerEntry] {
        guard count > 0 else { return [] }
        let start = max(0, storage.count - count)
        return Array(storage[start...])
    }

    /// Entries dropped so far. Exposed so a caller can tell "no problems" from
    /// "the evidence of the problems was evicted".
    public func evictedEntryCount() -> Int { evictedCount }

    public func retainedByteCount() -> Int { retainedBytes }

    private func evictIfNeeded() {
        // Termination: the count clause strictly decreases `storage.count`
        // toward `maximumEntries`, and the byte clause carries its own
        // `storage.count > 1` guard. That guard -- not the count budget -- is
        // what stops the loop when a single entry is larger than the entire
        // byte budget: with one entry left the byte clause is false, so an
        // over-budget entry is retained rather than evicted into an empty
        // ledger that could never satisfy the budget anyway.
        while storage.count > maximumEntries
            || (retainedBytes > maximumBytes && storage.count > 1) {
            guard !storage.isEmpty else { break }
            let removed = storage.removeFirst()
            retainedBytes = max(0, retainedBytes - removed.approximateByteCount)
            evictedCount = Safe.add(evictedCount, 1)
        }
    }

    static func describe(_ outcome: ContractOutcome) -> String {
        switch outcome {
        case .answered:
            return "answered"
        case .annotated(let count):
            return "annotated(\(count))"
        case .redacted(let removed, _):
            return "redacted(\(removed))"
        case .refused(let cause):
            switch cause {
            case .unsupportedClaims(let count): return "refused.unsupportedClaims(\(count))"
            case .redactionExceededBudget: return "refused.redactionExceededBudget"
            case .nothingSurvivedRedaction: return "refused.nothingSurvivedRedaction"
            case .noEvidence: return "refused.noEvidence"
            }
        }
    }
}
