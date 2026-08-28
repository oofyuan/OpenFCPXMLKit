//
//  ProjectionTiming.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

//
//  Absolute timeline placement for nested / anchored projection walks.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Fraction compatibility adapter for the authoritative ``ExactTime`` projection core.
    ///
    /// Mirrors the Extraction absolute-start rule for story/clip placement: a child's `offset`
    /// is relative to the parent's local timeline (`parent.start`, or `sequence.tcStart` when that
    /// is the last parent local origin). Any exact result that cannot be represented by the public
    /// fixed-width time boundary is unavailable; projection never reconstructs it from a decimal.
    enum ProjectionTiming {
        /// Decimal places retained only by non-authoritative display/statistical conversions.
        static let fractionPrecision: Int = 12

        typealias Ordering = ExactTimeOrdering

        enum ArithmeticError: Error {
            case unrepresentable
        }

        /// Converts non-authoritative display/statistical seconds into a finite Fraction without
        /// integer saturation. Projection endpoints must use the exact helpers below instead.
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
                    if rounded >= Double(Int.min),
                       rounded <= Double(Int.max),
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

        static func compare(_ lhs: Fraction, _ rhs: Fraction) -> Ordering? {
            guard let lhs = ExactTime(lhs), let rhs = ExactTime(rhs) else { return nil }
            return lhs.compared(to: rhs)
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
            ExactTime(value) != nil
        }

        /// Absolute sequence-local start for a child with the given `offset`.
        static func absoluteStart(
            offset: Fraction?,
            parentAbsoluteStart: Fraction,
            parentLocalStart: Fraction?
        ) -> Fraction? {
            let childOffset = offset ?? .zero
            if let parentLocalStart {
                guard let relative = subtracting(childOffset, parentLocalStart) else { return nil }
                return adding(parentAbsoluteStart, relative)
            }
            return adding(parentAbsoluteStart, childOffset)
        }

        /// Local timeline origin exposed to nested / anchored children after entering this element.
        static func localStartForChildren(of element: any OFKXMLElement) -> Fraction? {
            element.fcpStart
        }

        static func adding(_ lhs: Fraction, _ rhs: Fraction) -> Fraction? {
            guard let lhs = ExactTime(lhs),
                  let rhs = ExactTime(rhs),
                  let result = lhs.adding(rhs)
            else { return nil }
            return result.fraction
        }

        static func subtracting(_ lhs: Fraction, _ rhs: Fraction) -> Fraction? {
            guard let lhs = ExactTime(lhs),
                  let rhs = ExactTime(rhs),
                  let result = lhs.subtracting(rhs)
            else { return nil }
            return result.fraction
        }

        static func multiplying(_ lhs: Fraction, _ rhs: Fraction) -> Fraction? {
            guard let lhs = ExactTime(lhs),
                  let rhs = ExactTime(rhs),
                  let result = lhs.multiplying(by: rhs)
            else { return nil }
            return result.fraction
        }

        static func dividing(_ lhs: Fraction, _ rhs: Fraction) -> Fraction? {
            guard let lhs = ExactTime(lhs),
                  let rhs = ExactTime(rhs),
                  let result = lhs.dividing(by: rhs)
            else { return nil }
            return result.fraction
        }

        static func affinePoint(
            _ point: Fraction,
            inputStart: Fraction,
            inputEnd: Fraction,
            outputStart: Fraction,
            outputEnd: Fraction
        ) -> Fraction? {
            guard let point = ExactTime(point),
                  let inputStart = ExactTime(inputStart),
                  let inputEnd = ExactTime(inputEnd),
                  let outputStart = ExactTime(outputStart),
                  let outputEnd = ExactTime(outputEnd),
                  let result = ExactTime.affinePoint(
                      point,
                      inputStart: inputStart,
                      inputEnd: inputEnd,
                      outputStart: outputStart,
                      outputEnd: outputEnd
                  )
            else { return nil }
            return result.fraction
        }
    }
}
