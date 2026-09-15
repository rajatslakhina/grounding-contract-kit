//
//  Evidence.swift
//  GroundingContract
//
//  The retrieved material an answer is allowed to rest on.
//

/// Where a piece of evidence came from, and how old it is.
///
/// Age is supplied by the caller as seconds rather than captured as a `Date`
/// so the engine stays clock-free and fully deterministic under test. Callers
/// on device compute it once from `CSSearchableItem` metadata or from their
/// own store; callers in CI pass a literal.
public struct Provenance: Sendable, Hashable {
    /// Stable identifier of the producing source, e.g. `"spotlight.local"`.
    public let sourceID: String
    /// Human-facing label used when rendering a citation.
    public let displayName: String
    /// Age of the underlying record in seconds. Negative and non-finite
    /// values are normalised to `0` — a source that reports a record from the
    /// future is reporting a clock bug, not fresh evidence.
    public let ageSeconds: Double

    public init(sourceID: String, displayName: String, ageSeconds: Double) {
        self.sourceID = sourceID
        self.displayName = displayName
        if ageSeconds.isFinite, ageSeconds > 0 {
            self.ageSeconds = ageSeconds
        } else {
            self.ageSeconds = 0
        }
    }
}

/// One retrieved chunk that a claim may cite.
public struct EvidenceUnit: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let provenance: Provenance

    public init(id: String, text: String, provenance: Provenance) {
        self.id = id
        self.text = text
        self.provenance = provenance
    }
}

/// The complete evidence set for one answer, with its IDF model attached.
///
/// Constructing this is the only place tokenisation of evidence happens, so
/// the cost is paid once per answer rather than once per claim-unit pair.
public struct EvidenceSet: Sendable {
    public let units: [EvidenceUnit]
    /// Distinct `sourceID`s present, precomputed for the
    /// `minimumDistinctSources` contract term.
    public let distinctSourceIDs: Set<String>

    let idf: InverseDocumentFrequency
    /// Per-unit normalised token sets, index-aligned with `units`.
    let unitTerms: [Set<String>]
    /// Per-unit numeric/identifier literals, index-aligned with `units`.
    let unitLiterals: [Set<String>]

    public init(units: [EvidenceUnit]) {
        // Duplicate ids would make a citation ambiguous. Keep first-wins and
        // preserve caller order, which is retrieval rank order.
        var seen: Set<String> = []
        var deduplicated: [EvidenceUnit] = []
        deduplicated.reserveCapacity(units.count)
        for unit in units where seen.insert(unit.id).inserted {
            deduplicated.append(unit)
        }
        self.units = deduplicated
        self.distinctSourceIDs = Set(deduplicated.map(\.provenance.sourceID))
        self.idf = InverseDocumentFrequency(documents: deduplicated.map(\.text))
        self.unitTerms = deduplicated.map { Set(Lexicon.contentTokens($0.text).map(\.normalized)) }
        self.unitLiterals = deduplicated.map { NumericGuard.literals(in: $0.text) }
    }

    public var isEmpty: Bool { units.isEmpty }

    /// Bounds-checked accessor. Every internal index into `units` goes through
    /// this, so no scoring path can subscript out of range.
    func unit(at index: Int) -> EvidenceUnit? {
        guard index >= 0, index < units.count else { return nil }
        return units[index]
    }

    func terms(at index: Int) -> Set<String> {
        guard index >= 0, index < unitTerms.count else { return [] }
        return unitTerms[index]
    }

    func literals(at index: Int) -> Set<String> {
        guard index >= 0, index < unitLiterals.count else { return [] }
        return unitLiterals[index]
    }
}
