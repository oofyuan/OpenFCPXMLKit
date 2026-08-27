//
//  ProjectionTiming.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Absolute timeline placement for nested / anchored projection walks.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Fraction-based absolute start composition for projection walks.
    ///
    /// Mirrors the Extraction absolute-start rule for story/clip placement:
    /// a child's `offset` is relative to the parent's local timeline (parent `start`
    /// or sequence `tcStart` when that is the last parent local origin).
    ///
    /// Exact rational addition/subtraction is retained whenever the result fits `Fraction`.
    /// Interpolated retiming and conform-rate values use one explicitly bounded conversion,
    /// avoiding SwiftTimecode's default high-precision `Double` conversion near `Int` limits.
    enum ProjectionTiming {
        /// Decimal places kept when reconverting projection timeline math to ``Fraction``.
        static let fractionPrecision: Int = 12

        enum Ordering {
            case less
            case equal
            case greater
        }

        /// Converts computed seconds into a finite Fraction without integer saturation.
        /// Precision is reduced only when needed to keep the scaled numerator representable.
        static func fraction(
            seconds: Double,
            decimalPrecision: Int = fractionPrecision
        ) -> Fraction? {
            guard seconds.isFinite else { return nil }

            var denominator = 1
            for _ in 0 ..< max(0, decimalPrecision) {
                let (next, overflow) = denominator.multipliedReportingOverflow(by: 10)
                guard !overflow else { break }
                denominator = next
            }

            while denominator >= 1 {
                let scaled = seconds * Double(denominator)
                if scaled.isFinite {
                    let rounded = scaled.rounded(.toNearestOrAwayFromZero)
                    if rounded > Double(Int.min),
                       rounded < Double(Int.max),
                       let numerator = Int(exactly: rounded)
                    {
                        return Fraction(reducing: numerator, denominator)
                    }
                }
                if denominator == 1 { break }
                denominator /= 10
            }
            return nil
        }

        /// Exact ordering by full-width cross multiplication.
        static func compare(_ lhs: Fraction, _ rhs: Fraction) -> Ordering? {
            guard lhs.denominator > 0, rhs.denominator > 0 else { return nil }
            let lhsProduct = lhs.numerator.multipliedFullWidth(by: rhs.denominator)
            let rhsProduct = rhs.numerator.multipliedFullWidth(by: lhs.denominator)
            if lhsProduct.high != rhsProduct.high {
                return lhsProduct.high < rhsProduct.high ? .less : .greater
            }
            if lhsProduct.low != rhsProduct.low {
                return lhsProduct.low < rhsProduct.low ? .less : .greater
            }
            return .equal
        }

        static func ordered(_ lhs: Fraction, _ rhs: Fraction) -> (Fraction, Fraction)? {
            guard let ordering = compare(lhs, rhs) else { return nil }
            return ordering == .greater ? (rhs, lhs) : (lhs, rhs)
        }

        static func minimum(_ lhs: Fraction, _ rhs: Fraction) -> Fraction? {
            guard let ordering = compare(lhs, rhs) else { return nil }
            return ordering == .greater ? rhs : lhs
        }

        static func maximum(_ lhs: Fraction, _ rhs: Fraction) -> Fraction? {
            guard let ordering = compare(lhs, rhs) else { return nil }
            return ordering == .less ? rhs : lhs
        }

        static func isPositiveRange(start: Fraction, end: Fraction) -> Bool {
            compare(start, end) == .less
        }

        static func hasUsableEndpoint(_ value: Fraction) -> Bool {
            value.denominator > 0
                && value.numerator != Int.min
                && value.numerator != Int.max
        }

        /// Absolute sequence-local start for a child with the given `offset`.
        static func absoluteStart(
            offset: Fraction?,
            parentAbsoluteStart: Fraction,
            parentLocalStart: Fraction?
        ) -> Fraction {
            let childOffset = offset ?? .zero
            if let parentLocalStart {
                return adding(
                    parentAbsoluteStart,
                    subtracting(childOffset, parentLocalStart)
                )
            }
            return adding(parentAbsoluteStart, childOffset)
        }

        /// Local timeline origin exposed to nested / anchored children after entering
        /// this element (parent `start`, if present; otherwise `nil` so children add
        /// their offsets onto `absoluteStart` directly).
        static func localStartForChildren(of element: any OFKXMLElement) -> Fraction? {
            element.fcpStart
        }

        /// Safe `a + b` for projection timeline composition.
        static func adding(_ a: Fraction, _ b: Fraction) -> Fraction {
            if a.numerator == 0 { return b }
            if b.numerator == 0 { return a }
            if let exact = combining(a, b, subtract: false) { return exact }
            guard let bounded = fraction(seconds: a.doubleValue + b.doubleValue) else {
                preconditionFailure("Projection sum is not representable as a finite Fraction")
            }
            return bounded
        }

        /// Safe `a - b` for projection timeline composition.
        static func subtracting(_ a: Fraction, _ b: Fraction) -> Fraction {
            if b.numerator == 0 { return a }
            if compare(a, b) == .equal { return .zero }
            if let exact = combining(a, b, subtract: true) { return exact }
            guard let bounded = fraction(seconds: a.doubleValue - b.doubleValue) else {
                preconditionFailure("Projection difference is not representable as a finite Fraction")
            }
            return bounded
        }

        private static func combining(
            _ lhs: Fraction,
            _ rhs: Fraction,
            subtract: Bool
        ) -> Fraction? {
            guard lhs.denominator > 0, rhs.denominator > 0 else { return nil }
            let divisor = greatestCommonDivisor(lhs.denominator, rhs.denominator)
            let lhsMultiplier = rhs.denominator / divisor
            let rhsMultiplier = lhs.denominator / divisor
            let (lhsNumerator, lhsOverflow) = lhs.numerator.multipliedReportingOverflow(
                by: lhsMultiplier
            )
            let (rhsNumerator, rhsOverflow) = rhs.numerator.multipliedReportingOverflow(
                by: rhsMultiplier
            )
            guard !lhsOverflow, !rhsOverflow else { return nil }
            let (numerator, numeratorOverflow) = subtract
                ? lhsNumerator.subtractingReportingOverflow(rhsNumerator)
                : lhsNumerator.addingReportingOverflow(rhsNumerator)
            let (denominator, denominatorOverflow) = lhs.denominator.multipliedReportingOverflow(
                by: lhsMultiplier
            )
            guard !numeratorOverflow,
                  !denominatorOverflow,
                  numerator != Int.min,
                  denominator > 0
            else { return nil }
            return Fraction(reducing: numerator, denominator)
        }

        private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
            var a = lhs
            var b = rhs
            while b != 0 {
                let remainder = a % b
                a = b
                b = remainder
            }
            return a
        }
    }
}
