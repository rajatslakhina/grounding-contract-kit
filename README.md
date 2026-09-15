# GroundingContract

**An LLM answer is not a string. It is a set of claims, each carrying an evidence obligation — and shipping it unverified is shipping an unreviewed database migration.**

`GroundingContract` is the layer that sits *after* generation and *before* the user. It takes the answer a model produced and the evidence it was retrieved against, decomposes the answer into atomic claims, attributes each claim to specific evidence units, and then enforces a declared contract: annotate, redact, or refuse.

iOS 27 made local RAG two lines of Swift. `SpotlightSearchTool` plugs a `LanguageModelSession` straight into the on-device index and the model starts answering from your app's own content. What Apple's two lines do **not** give you is the part a lead has to own:

- Which of the sentences the model just produced are actually supported by what came back?
- What happens to the ones that aren't?
- How do you know your checker works?

This package is the answer to those three questions, and it needs no model to run — which is why its behaviour is verified on Linux CI, in 77 tests, with zero ML weights.

---

## The failure this exists to stop

> **Corpus says:** "The image cache evicts entries under a **48 MB** byte budget using least-recently-used ordering."
>
> **Model says:** "The image cache evicts entries under a **64 MB** byte budget."

Those two sentences are ~95 % lexically identical. Every similarity measure you would reach for — cosine over embeddings, BM25 overlap, n-gram containment, an LLM-as-judge prompt scoring "is this consistent?" — scores the fabricated one as supported, because by every measure of *similarity* it is. A hallucinated figure is the highest-cost, lowest-detectability error a grounded answer has: it is maximally quotable and minimally distinguishable.

So the scorer has **two asymmetric channels**:

| | Channel | What it measures | What it can do |
|---|---|---|---|
| 1 | **Prose** | Share of the claim's IDF-weighted mass present in the evidence | Raise the score |
| 2 | **Literal** | Every number and identifier in the claim, matched *exactly* against the evidence being credited | Only ever **veto**, to zero |

Channel 2 can see nothing but figures. Channel 1 cannot see figures at all. Neither is sufficient; the veto ordering is the contract's sharpest edge.

Measured, from `GroundingContractEngineTests` against the package's own fixture corpus:

| Claim | Coverage | Verdict |
|---|---|---|
| "…evicts entries using least-recently-used ordering." | **1.000** | `supported` → cites `cache` |
| "…under a **48 MB** byte budget." | **1.000** | `supported` |
| "…under a **64 MB** byte budget." | **0.000** | `unsupported` · `numericMismatch` · `["64"]` |
| "Incident **INC-9115** was resolved in 37 minutes." | **0.000** | `unsupported` · `numericMismatch` · `["inc-9115"]` |
| "…using a segmented admission filter." | **0.407** | `weaklySupported` |
| "Kubernetes autoscaling was disabled for the nightly worker pool." | **0.000** | `unsupported` · `insufficientCoverage` |

Note rows 3 and 4 share almost every word with a supported claim. One digit is the entire difference, and one digit is the entire outcome.

Those coverage figures are not decoration: `testPublishedCoverageFiguresAreGuardedByAnAssertion` pins every one of them to three decimal places, so a regression that moved 0.407 to 0.55 fails the build instead of quietly making this table wrong.

---

## Architecture

```
 answer ──▶ ClaimDecomposer ──▶ [Claim]              (character-exact spans)
                                   │
 evidence ─▶ EvidenceSet ──────────┤                 (IDF + literal index, built once)
                                   ▼
                            SupportScorer            ◀── pluggable seam
                        ┌──────────┴──────────┐
                   prose channel        literal channel
                   (IDF coverage)        (exact veto)
                        └──────────┬──────────┘
                                   ▼
                          SupportMeasurement
                                   │
                        GroundingPolicy applied
                                   ▼
                    ClaimVerdict × n ──▶ enforce
                          ┌────────┼────────┐
                     annotate   redact    refuse
                                   │
                                   ▼
                            VerifiedAnswer ──▶ AttributionLedger (bounded)
```

Every box is a protocol or a value type. Scoring is **pure and synchronous** — `GroundingContractEngine.evaluate(...)` is a `nonisolated static` that a `#Preview` or a unit test can call directly and get exactly the shipping logic. The `actor` exists only because the ledger is shared mutable state; there is deliberately no `await` inside the verification pipeline, so there is no suspension point at which a concurrent call could observe a half-built verdict list.

### Modules

| Module | Contents | Built by |
|---|---|---|
| `GroundingContract` | Everything above. No Apple frameworks, no model. | Linux **and** macOS CI |
| `GroundingContractUI` | `GroundingReportView` + `@Observable` driver. Entirely behind `#if canImport(SwiftUI)`. | macOS CI only |

---

## Design decisions, and what was rejected

**Sentence-level claims, not proposition-level.** Finer decomposition needs a model, and a verifier that needs a model to decide *what to verify* has a circularity problem: the component you distrust is now inside the component you trust. Sentences are computable exactly, and a sentence is also the only unit a reader can actually be shown a citation next to. This is a ceiling, stated as one.

**Exact literal matching, tolerance opt-in and off by default.** A figure quoted from a document should be the figure in the document. `numericTolerance` exists for callers whose model legitimately rounds ("about 4.2 million" against "4,215,000") and is a deliberate loosening of the contract, never a default. Identifiers — `INC-9114`, `SKU-4471`, `v1.2.3` — **never** benefit from tolerance: `INC-9115` is a different incident, not a rounding error.

**String canonicalisation for numbers, not a `Double` round trip.** `10000000000000000001` and `10000000000000000002` both become `1e19` as `Double`s, which would make a fabricated figure match. Canonicalisation strips leading zeros and trailing fractional zeros as *text*; nothing in the literal channel depends on float formatting being stable across platforms.

**Redaction splices; it never rewrites.** Surviving text is rebuilt from the original characters at the claims' recorded offsets. A redaction step that paraphrases would reintroduce exactly the ungrounded-generation problem it exists to remove. `testRedactionNeverInventsWordsTheModelDidNotWrite` asserts every surviving character appears, in order, in the original.

**Redaction escalates to refusal.** If cutting the unsupported claims would remove more than `maximumRedactionRatio` of the answer, the answer is refused instead. A shredded paragraph reads as authoritative while being incoherent; nothing is better.

**`weaklySupported` is reported but not shippable.** Two thresholds, not one, because "we barely missed" and "we were nowhere near" are different operational signals — and collapsing them loses the one number that tells you whether to tune the threshold or fix retrieval. Weak still fails the contract.

**Evidence composition is on by default, and it is a real trade-off.** `allowsEvidenceComposition` lets a claim accumulate coverage across up to three units, which is necessary for multi-hop claims — and also accepts a claim stitched from fragments that never co-occurred, which is a genuine fabrication mode. `GroundingPolicy.regulated` turns it off. The trade-off is named rather than hidden.

**Hand-rolled tokeniser, not `NLTokenizer`.** The calibration numbers in this README are only meaningful if the tokeniser that produced them is the tokeniser that ships. A platform-dependent tokeniser makes Linux CI results non-transferable to device. Cost: the tokeniser is ~90 lines you now own.

**Negation is not a stopword.** Stripping `not` makes "not evicted" and "evicted" the same claim. That is a correctness bug wearing a recall trade-off's clothes.

**Two budgets on the ledger, both enforced.** A count budget alone is unbounded in memory when questions are long; a byte budget alone lets a flood of tiny entries evict the ones that mattered. Oldest-first eviction, and `evictedEntryCount()` is public so a caller can tell "no problems" from "the evidence of the problems was evicted".

**Deterministic summation, not nearly-deterministic.** Floating-point addition is not associative and Swift's `Hasher` is seeded per process, so summing IDF mass while iterating a `Dictionary` or a `Set` varies the last ULP of `coverage` between runs — enough to flip a claim sitting exactly on a threshold. The scorer sums over sorted keys instead. A determinism claim is either true or it is marketing.

**Dotted version numbers are treated as identifiers, not ignored.** `1.2.3` is neither a plain quantity nor a letter-bearing token. Letting it fall through as "no literal here" would mean "version 1.2.4" passed unvetoed against a corpus saying 1.2.3 — a silent hole in the package's headline promise. It has no magnitude, so it is matched exactly, like a SKU.

---

## Measuring the verifier

A verifier you have not measured is a second unverified component in front of the first one. `VerifierCalibration` runs a `SupportScorer` over a labelled golden set and reports a confusion matrix whose **positive class is "detected as ungrounded"** — because the expensive error is a fabrication that ships, so recall on that class is the number to look at first.

```swift
let sweep = VerifierCalibration.sweep(samples: goldenSet, steps: 20)
sweep.recommended   // best F1, ties broken toward recall, then toward the lower threshold
```

Two deliberate refusals to flatter:

- `precision` and `recall` are **0**, not 1, when their denominator is zero. A do-nothing verifier that rejected nothing and was therefore never wrong must not score 1.0.
- Calibration reads `verdicts`, and enforcement never edits that array — it only decides what text comes back. So the confusion matrix is independent of the response *by construction*, not by an override. `testCalibrationMatrixIsIndependentOfEnforcement` asserts both halves: `.refuse` and `.redact` produce an identical matrix, **and** they produce genuinely different answers, so the first assertion is not passing for the trivial reason.

### The test that matters most

`testCalibrationDetectsAGuttedVerifier` feeds the harness an `AlwaysSupportsScorer` — a verifier with its brain removed, returning coverage `1.0` for every claim — and asserts **recall 0, F1 0, 3 false negatives**. If that assertion did not hold, every calibration number in this README would be worthless. `testCalibrationAlsoDetectsAVerifierThatRefusesEverything` covers the opposite degenerate case: recall 1, precision 0.5.

The same discipline is applied to the numeric guard itself. `testNumericGuardIsLoadBearingNotDecorative` verifies the same fabricated claim twice, once with `enforcesNumericLiterals: true` and once `false`, and asserts the verdict *changes*. Delete the literal channel and the test fails rather than silently continuing to pass.

---

## Safety properties

No force-unwraps, no `try!`, no `as!`. Every collection access bounds-checked — `EvidenceSet` exposes `public` `unit(at:)`, `terms(at:)` and `literals(at:)`, and no scoring path subscripts directly. They are public because `SupportScorer` is a public seam: a caller writing a custom scorer gets the same guarded access the built-in one uses, not a raw array and good intentions.

Every trapping arithmetic operation goes through `Safe`: saturating `add`/`multiply`, `divide` that handles both a zero divisor and the single overflowing case `Int.min / -1`, `ratio` that returns `0` rather than `NaN`, and `int(_:)` whose range ceiling is derived from `Int.max` rather than a hardcoded 64-bit literal, because `Int` is 32-bit on watchOS. `clamp01` maps `NaN` to `0` so a score can never be "unsupported" in one branch and "supported" in another depending on which way the comparison happens to be written.

The ledger's eviction loop terminates even when a single entry is larger than the entire byte budget: the byte clause carries its own `storage.count > 1` guard, so an over-budget entry is retained rather than evicted into an empty ledger that could never satisfy the budget anyway (`testASingleOversizedEntryIsRetainedRatherThanLoopingForever`). 200 concurrent writers against a 50-entry ledger issue **200 unique, monotonic ids** — the test collects every id `record` returns, not just the 50 that survive — and leave 50 retained entries with 150 recorded evictions.

---

## Usage

```swift
let evidence = EvidenceSet(units: retrievedItems.map {
    EvidenceUnit(
        id: $0.uniqueIdentifier,
        text: $0.attributeSet.contentDescription ?? "",
        provenance: Provenance(
            sourceID: "spotlight.local",
            displayName: $0.attributeSet.title ?? "Untitled",
            ageSeconds: Date.now.timeIntervalSince($0.attributeSet.contentModificationDate ?? .now)
        )
    )
})

let engine = GroundingContractEngine(
    policy: GroundingPolicy(
        supportThreshold: 0.6,
        unsupportedClaimAction: .redact,
        maximumRedactionRatio: 0.5
    ),
    ledger: AttributionLedger()
)

let response = try await session.respond(to: prompt)
let verified = await engine.verify(
    answer: response.content,
    evidence: evidence,
    question: prompt
)

switch verified.outcome {
case .answered:                 show(verified.text)
case .redacted(let cut, _):     show(verified.text, footnote: "\(cut) unsupported claim(s) removed")
case .annotated:                show(verified.text, verdicts: verified.verdicts)
case .refused(let cause):       showRefusal(cause)
}
```

Two policies ship:

```swift
GroundingPolicy.observability  // .annotate — measure before you enforce
GroundingPolicy.regulated      // 0.75 threshold, 2 distinct sources, no composition, .refuse
```

### Install

```swift
.package(url: "https://github.com/rajatslakhina/grounding-contract-kit.git", from: "1.0.0")
```

---

## Demo app

**[grounding-contract-demo-app](https://github.com/rajatslakhina/grounding-contract-demo-app)** — a SwiftUI app that consumes this package as a version-pinned remote dependency. Six candidate model answers, two contract toggles, and one toggle (**Enforce numeric literals**) that turns the fabricated-figure claim from red to green in front of you.

---

## Verification

Run it yourself:

```bash
swift build -Xswiftc -warnings-as-errors
swift test
```

Locally, on Swift 6.0.3 (Linux, Swift 6 language mode), after wiping `.build`: `swift build -Xswiftc -warnings-as-errors` clean and `swift test` → **77 tests, 0 failures**. CI runs the same two commands plus an iOS Simulator compile of `GroundingContractUI` — see the [Actions](../../actions) tab for the current result rather than a run id quoted here that goes stale on the next commit.

**What was not verified, stated plainly:** the demo app was **not run on an iOS Simulator**, and **no screenshots exist** — not in this repo and not in the demo repo. This package was produced by an unattended scheduled task, and computer-use access is not grantable in that mode; the refusal, verbatim, was:

> Computer-use access to "Simulator" can't be approved during a scheduled run. To grant it, send a message in this conversation (the approval card will appear), or add the app to the scheduled task's settings. (Retrying returns this same result.)

"It compiles for an iOS Simulator destination" and "it ran on an iOS Simulator" are different claims. Only the first is true here. Nothing in this repo has been observed rendering on a screen.

## License

MIT — see [LICENSE](LICENSE).
