//
//  SafeArithmetic.swift
//  GroundingContract
//
//  Saturating / trap-free arithmetic helpers.
//
//  Every numeric operation in this package that could trap at runtime goes
//  through one of these helpers. Swift's `+`, `*`, `/`, `%` and the
//  `Int(Double)` initialiser all trap on overflow, division by zero, NaN and
//  out-of-range conversion. A grounding verifier runs on model output, which
//  is by definition attacker-shaped input, so none of those traps are
//  acceptable in the public path.
//

/// Trap-free integer and floating-point helpers.
///
/// These are deliberately free functions on an enum namespace rather than
/// operators: at a call site the reader should *see* that the saturating
/// behaviour was chosen, not infer it.
public enum Safe {

    /// Addition that saturates at `Int.min` / `Int.max` instead of trapping.
    @inlinable
    public static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow {
            return rhs > 0 ? Int.max : Int.min
        }
        return value
    }

    /// Multiplication that saturates instead of trapping.
    @inlinable
    public static func multiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        if overflow {
            return (lhs > 0) == (rhs > 0) ? Int.max : Int.min
        }
        return value
    }

    /// Integer division that returns `fallback` for a zero divisor and for the
    /// single overflowing case `Int.min / -1`.
    @inlinable
    public static func divide(_ lhs: Int, _ rhs: Int, fallback: Int = 0) -> Int {
        guard rhs != 0 else { return fallback }
        let (value, overflow) = lhs.dividedReportingOverflow(by: rhs)
        return overflow ? fallback : value
    }

    /// A ratio in `0...1`, defined as `0` when the denominator is zero.
    ///
    /// Used everywhere a "fraction of X" is reported, so an empty input set
    /// produces `0` rather than `NaN` leaking into a threshold comparison.
    @inlinable
    public static func ratio(_ numerator: Double, _ denominator: Double) -> Double {
        guard denominator.isFinite, denominator != 0, numerator.isFinite else { return 0 }
        let value = numerator / denominator
        guard value.isFinite else { return 0 }
        return clamp01(value)
    }

    /// Clamps to `0...1`, mapping NaN to `0`.
    ///
    /// NaN comparisons are always false, so `if score >= threshold` silently
    /// treats NaN as "unsupported" in some branches and "supported" in others
    /// depending on how the comparison is written. Normalising here removes
    /// that class of bug entirely.
    @inlinable
    public static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        if value < 0 { return 0 }
        if value > 1 { return 1 }
        return value
    }

    /// `Int(Double)` without the trap.
    ///
    /// `Int(x)` traps on NaN, on infinity, and on any value outside
    /// `Int.min...Int.max`. The range ceiling is derived from `Int.max` rather
    /// than a hardcoded 64-bit literal because `Int` is 32-bit on watchOS.
    @inlinable
    public static func int(_ value: Double, fallback: Int = 0) -> Int {
        // NaN is not a magnitude, so it gets the caller's fallback. The
        // infinities are magnitudes, so they saturate like any other
        // out-of-range value rather than silently becoming `fallback`.
        if value.isNaN { return fallback }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }
}
