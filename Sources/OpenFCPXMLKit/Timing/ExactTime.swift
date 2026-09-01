//
//  ExactTime.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Exact ordering for authoritative FCPXML time values.
    public enum ExactTimeOrdering: Int, Codable, Sendable {
        case less = -1
        case equal = 0
        case greater = 1
    }

    /// A normalized rational time value used by authoritative projection calculations.
    ///
    /// The denominator is always positive, zero is always represented as `0/1`, and every
    /// nonzero value is reduced. Projection uses Swift's 128-bit integers so affine calculations
    /// do not fail merely because a valid FCPXML result exceeds the legacy 64-bit `Fraction`
    /// boundary. Operations still return `nil` on genuine 128-bit overflow; they never substitute
    /// a floating-point approximation or a saturated integer.
    public struct ExactTime: Hashable, Sendable {
        public let numerator: Int128
        public let denominator: Int128

        public init?(numerator: Int128, denominator: Int128) {
            guard denominator > 0 else { return nil }
            if numerator == 0 {
                self.numerator = 0
                self.denominator = 1
                return
            }

            let divisor = Self.greatestCommonDivisor(
                numerator.magnitude,
                UInt128(denominator)
            )
            guard let signedDivisor = Int128(exactly: divisor) else { return nil }
            self.numerator = numerator / signedDivisor
            self.denominator = denominator / signedDivisor
        }

        /// Creates an exact value from SwiftTimecode's compatibility `Fraction` type.
        public init?(_ fraction: Fraction) {
            guard let numerator = Int128(exactly: fraction.numerator),
                  let denominator = Int128(exactly: fraction.denominator)
            else { return nil }
            self.init(numerator: numerator, denominator: denominator)
        }

        public static let zero = ExactTime(numerator: 0, denominator: 1)!

        /// Converts back to the compatibility `Fraction` type without loss.
        public var fraction: Fraction? {
            guard let numerator = Int(exactly: numerator),
                  let denominator = Int(exactly: denominator)
            else { return nil }
            return Fraction(numerator, denominator)
        }

        /// A bounded compatibility value for legacy display/reporting APIs.
        ///
        /// Projection and restoration code must use the authoritative `ExactTime` value. This
        /// adapter is exact whenever possible; otherwise it rounds once, using integer arithmetic,
        /// to at most nanosecond precision so existing `Fraction`-based presentation APIs remain
        /// source compatible without influencing projection decisions.
        public var compatibilityFraction: Fraction? {
            if let fraction { return fraction }

            let whole = numerator / denominator
            guard whole.magnitude <= UInt128(Int.max) else { return nil }
            let wholeMagnitude = Int128(whole.magnitude)
            let maximumDenominator = Int128(Int.max) / (wholeMagnitude + 1)
            let targetDenominator = min(Int128(1_000_000_000), maximumDenominator)
            guard targetDenominator > 0 else { return nil }

            let remainderMagnitude = (numerator % denominator).magnitude
            let product = remainderMagnitude.multipliedFullWidth(
                by: UInt128(targetDenominator)
            )
            let division = UInt128(denominator).dividingFullWidth(product)
            var fractionalMagnitude = division.quotient
            if division.remainder >= UInt128(denominator) - division.remainder {
                fractionalMagnitude += 1
            }

            let (base, baseOverflow) = whole.multipliedReportingOverflow(
                by: targetDenominator
            )
            guard !baseOverflow,
                  let fractional = Int128(exactly: fractionalMagnitude)
            else { return nil }
            let signedFractional = numerator < 0 ? -fractional : fractional
            let (combined, overflow) = base.addingReportingOverflow(signedFractional)
            guard !overflow,
                  let compatibleNumerator = Int(exactly: combined),
                  let compatibleDenominator = Int(exactly: targetDenominator)
            else { return nil }
            return Fraction(reducing: compatibleNumerator, compatibleDenominator)
        }

        /// Non-authoritative display/statistics conversion.
        public var doubleValue: Double {
            Double(numerator) / Double(denominator)
        }

        /// Exact ordering by signed full-width cross multiplication.
        public func compared(to other: Self) -> ExactTimeOrdering {
            let lhs = numerator.multipliedFullWidth(by: other.denominator)
            let rhs = other.numerator.multipliedFullWidth(by: denominator)
            if lhs.high != rhs.high {
                return lhs.high < rhs.high ? .less : .greater
            }
            if lhs.low != rhs.low {
                return lhs.low < rhs.low ? .less : .greater
            }
            return .equal
        }

        public func adding(_ other: Self) -> Self? {
            if numerator == 0 { return other }
            if other.numerator == 0 { return self }
            return Self.combining(self, other, subtract: false)
        }

        public func subtracting(_ other: Self) -> Self? {
            if other.numerator == 0 { return self }
            if compared(to: other) == .equal { return .zero }
            return Self.combining(self, other, subtract: true)
        }

        public func multiplying(by other: Self) -> Self? {
            if numerator == 0 || other.numerator == 0 { return .zero }
            return Self.product(
                numeratorMagnitudes: [numerator.magnitude, other.numerator.magnitude],
                denominatorMagnitudes: [UInt128(denominator), UInt128(other.denominator)],
                negative: (numerator < 0) != (other.numerator < 0)
            )
        }

        public func dividing(by other: Self) -> Self? {
            guard other.numerator != 0 else { return nil }
            if numerator == 0 { return .zero }
            return Self.product(
                numeratorMagnitudes: [numerator.magnitude, UInt128(other.denominator)],
                denominatorMagnitudes: [UInt128(denominator), other.numerator.magnitude],
                negative: (numerator < 0) != (other.numerator < 0)
            )
        }

        /// Maps a point exactly between two rational axes.
        public static func affinePoint(
            _ point: Self,
            inputStart: Self,
            inputEnd: Self,
            outputStart: Self,
            outputEnd: Self
        ) -> Self? {
            if point.compared(to: inputStart) == .equal { return outputStart }
            if point.compared(to: inputEnd) == .equal { return outputEnd }
            guard inputStart.compared(to: inputEnd) != .equal,
                  let inputOffset = point.subtracting(inputStart),
                  let inputSpan = inputEnd.subtracting(inputStart),
                  let outputSpan = outputEnd.subtracting(outputStart),
                  let projectedOffset = multiplyThenDivide(
                      inputOffset,
                      outputSpan,
                      by: inputSpan
                  )
            else { return nil }
            return outputStart.adding(projectedOffset)
        }

        private typealias SignedFullWidth = (high: Int128, low: UInt128)
        private typealias UnsignedFullWidth = (high: UInt128, low: UInt128)

        private static func combining(
            _ lhs: Self,
            _ rhs: Self,
            subtract: Bool
        ) -> Self? {
            let sharedDivisor = greatestCommonDivisor(
                UInt128(lhs.denominator),
                UInt128(rhs.denominator)
            )
            guard let divisor = Int128(exactly: sharedDivisor) else { return nil }
            let lhsMultiplier = rhs.denominator / divisor
            let rhsMultiplier = lhs.denominator / divisor
            let lhsProduct = lhs.numerator.multipliedFullWidth(by: lhsMultiplier)
            let rhsProduct = rhs.numerator.multipliedFullWidth(by: rhsMultiplier)
            guard let fullNumerator = subtract
                ? subtractingFullWidth(lhsProduct, rhsProduct)
                : addingFullWidth(lhsProduct, rhsProduct),
                  let reducedNumerator = reducingFullWidth(
                      fullNumerator,
                      cancellableBy: sharedDivisor
                  )
            else { return nil }

            guard let cancellation = Int128(exactly: reducedNumerator.cancellation) else {
                return nil
            }
            let reducedLHSDenominator = lhs.denominator / cancellation
            let (denominator, overflow) = reducedLHSDenominator
                .multipliedReportingOverflow(by: lhsMultiplier)
            guard !overflow else { return nil }
            return Self(numerator: reducedNumerator.value, denominator: denominator)
        }

        /// Exact `(lhs × rhs) ÷ divisor`, cancelling every rational factor before multiplication.
        private static func multiplyThenDivide(
            _ lhs: Self,
            _ rhs: Self,
            by divisor: Self
        ) -> Self? {
            guard divisor.numerator != 0 else { return nil }
            return product(
                numeratorMagnitudes: [
                    lhs.numerator.magnitude,
                    rhs.numerator.magnitude,
                    UInt128(divisor.denominator)
                ],
                denominatorMagnitudes: [
                    UInt128(lhs.denominator),
                    UInt128(rhs.denominator),
                    divisor.numerator.magnitude
                ],
                negative: ((lhs.numerator < 0) != (rhs.numerator < 0))
                    != (divisor.numerator < 0)
            )
        }

        private static func product(
            numeratorMagnitudes: [UInt128],
            denominatorMagnitudes: [UInt128],
            negative: Bool
        ) -> Self? {
            if numeratorMagnitudes.contains(0) { return .zero }
            var numerators = numeratorMagnitudes
            var denominators = denominatorMagnitudes

            for numeratorIndex in numerators.indices {
                for denominatorIndex in denominators.indices {
                    let divisor = greatestCommonDivisor(
                        numerators[numeratorIndex],
                        denominators[denominatorIndex]
                    )
                    numerators[numeratorIndex] /= divisor
                    denominators[denominatorIndex] /= divisor
                }
            }

            var numeratorMagnitude: UInt128 = 1
            for factor in numerators {
                let (product, overflow) = numeratorMagnitude.multipliedReportingOverflow(by: factor)
                guard !overflow else { return nil }
                numeratorMagnitude = product
            }
            var denominatorMagnitude: UInt128 = 1
            for factor in denominators {
                let (product, overflow) = denominatorMagnitude
                    .multipliedReportingOverflow(by: factor)
                guard !overflow else { return nil }
                denominatorMagnitude = product
            }

            guard let numerator = signedValue(
                magnitude: numeratorMagnitude,
                negative: negative
            ),
            let denominator = Int128(exactly: denominatorMagnitude)
            else { return nil }
            return Self(numerator: numerator, denominator: denominator)
        }

        private static func addingFullWidth(
            _ lhs: SignedFullWidth,
            _ rhs: SignedFullWidth
        ) -> SignedFullWidth? {
            let (low, carry) = lhs.low.addingReportingOverflow(rhs.low)
            let (partialHigh, _) = UInt128(bitPattern: lhs.high)
                .addingReportingOverflow(UInt128(bitPattern: rhs.high))
            let (highBits, _) = partialHigh.addingReportingOverflow(carry ? 1 : 0)
            let result: SignedFullWidth = (high: Int128(bitPattern: highBits), low: low)
            let lhsNegative = lhs.high < 0
            let rhsNegative = rhs.high < 0
            guard lhsNegative != rhsNegative || (result.high < 0) == lhsNegative else {
                return nil
            }
            return result
        }

        private static func subtractingFullWidth(
            _ lhs: SignedFullWidth,
            _ rhs: SignedFullWidth
        ) -> SignedFullWidth? {
            let (low, borrow) = lhs.low.subtractingReportingOverflow(rhs.low)
            let (partialHigh, _) = UInt128(bitPattern: lhs.high)
                .subtractingReportingOverflow(UInt128(bitPattern: rhs.high))
            let (highBits, _) = partialHigh.subtractingReportingOverflow(borrow ? 1 : 0)
            let result: SignedFullWidth = (high: Int128(bitPattern: highBits), low: low)
            let lhsNegative = lhs.high < 0
            let rhsNegative = rhs.high < 0
            guard lhsNegative == rhsNegative || (result.high < 0) == lhsNegative else {
                return nil
            }
            return result
        }

        private static func reducingFullWidth(
            _ value: SignedFullWidth,
            cancellableBy divisor: UInt128
        ) -> (value: Int128, cancellation: UInt128)? {
            guard divisor > 0 else { return nil }
            let negative = value.high < 0
            let magnitude = fullWidthMagnitude(of: value)
            guard let (_, remainder) = dividingMagnitude(magnitude, by: divisor) else {
                return nil
            }
            let cancellation = greatestCommonDivisor(remainder, divisor)
            guard let (quotient, _) = dividingMagnitude(magnitude, by: cancellation),
                  quotient.high == 0,
                  let reducedValue = signedValue(
                      magnitude: quotient.low,
                      negative: negative
                  )
            else { return nil }
            return (reducedValue, cancellation)
        }

        private static func fullWidthMagnitude(of value: SignedFullWidth) -> UnsignedFullWidth {
            guard value.high < 0 else { return (UInt128(value.high), value.low) }
            let (low, carry) = (~value.low).addingReportingOverflow(1)
            let high = ~UInt128(bitPattern: value.high) &+ (carry ? 1 : 0)
            return (high, low)
        }

        private static func dividingMagnitude(
            _ value: UnsignedFullWidth,
            by divisor: UInt128
        ) -> (quotient: UnsignedFullWidth, remainder: UInt128)? {
            guard divisor > 0 else { return nil }
            let highQuotient = value.high / divisor
            let highRemainder = value.high % divisor
            let lowDivision = divisor.dividingFullWidth((high: highRemainder, low: value.low))
            return ((highQuotient, lowDivision.quotient), lowDivision.remainder)
        }

        private static func signedValue(magnitude: UInt128, negative: Bool) -> Int128? {
            if negative {
                if magnitude == UInt128(Int128.max) + 1 { return .min }
                guard let value = Int128(exactly: magnitude) else { return nil }
                return -value
            }
            return Int128(exactly: magnitude)
        }

        private static func greatestCommonDivisor(_ lhs: UInt128, _ rhs: UInt128) -> UInt128 {
            var first = lhs
            var second = rhs
            while second != 0 {
                (first, second) = (second, first % second)
            }
            return first
        }
    }

}

extension FinalCutPro.FCPXML.ExactTime: Codable {
    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try container.decode(Int128.self, forKey: .numerator)
        let denominator = try container.decode(Int128.self, forKey: .denominator)
        guard let value = Self(numerator: numerator, denominator: denominator) else {
            throw DecodingError.dataCorruptedError(
                forKey: .denominator,
                in: container,
                debugDescription: "ExactTime requires a positive denominator"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }
}

extension FinalCutPro.FCPXML {
    /// A positive half-open range on an exact FCPXML time axis.
    public struct ExactTimeRange: Equatable, Hashable, Sendable {
        public let start: ExactTime
        public let end: ExactTime

        public init?(start: ExactTime, end: ExactTime) {
            guard start.compared(to: end) == .less else { return nil }
            self.start = start
            self.end = end
        }

        public var duration: ExactTime? {
            end.subtracting(start)
        }
    }
}

extension FinalCutPro.FCPXML.ExactTimeRange: Codable {
    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(FinalCutPro.FCPXML.ExactTime.self, forKey: .start)
        let end = try container.decode(FinalCutPro.FCPXML.ExactTime.self, forKey: .end)
        guard let range = Self(start: start, end: end) else {
            throw DecodingError.dataCorruptedError(
                forKey: .end,
                in: container,
                debugDescription: "ExactTimeRange requires a positive range"
            )
        }
        self = range
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}
