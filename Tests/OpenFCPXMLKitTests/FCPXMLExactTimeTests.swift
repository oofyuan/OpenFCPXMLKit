//
//  FCPXMLExactTimeTests.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

import Foundation
import OpenFCPXMLKit
import SwiftTimecode
import Testing

@Suite("Exact FCPXML time")
struct FCPXMLExactTimeTests {
    typealias ExactTime = FinalCutPro.FCPXML.ExactTime

    @Test("Public exact time normalizes and round-trips Codable")
    func normalizationAndCodable() throws {
        let value = try #require(ExactTime(numerator: 2, denominator: 6))
        #expect(value.numerator == 1)
        #expect(value.denominator == 3)
        #expect(try JSONDecoder().decode(
            ExactTime.self,
            from: JSONEncoder().encode(value)
        ) == value)
        #expect(ExactTime(numerator: 1, denominator: 0) == nil)

        let invalid = Data(#"{"numerator":1,"denominator":-3}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ExactTime.self, from: invalid)
        }
    }

    @Test("Int64 extrema are legitimate exact endpoints")
    func integerExtremaAreLegitimateEndpoints() throws {
        let minimum = try #require(ExactTime(numerator: .min, denominator: 1))
        let maximum = try #require(ExactTime(numerator: .max, denominator: 1))
        #expect(minimum.compared(to: maximum) == .less)
        #expect(try #require(maximum.adding(minimum))
            == ExactTime(numerator: -1, denominator: 1))
        #expect(try #require(minimum.subtracting(minimum)) == .zero)
    }

    @Test("Checked arithmetic reduces before rejecting intermediates")
    func checkedArithmeticCrossCancels() throws {
        let large = try #require(ExactTime(numerator: .max, denominator: 3))
        let reciprocal = try #require(ExactTime(numerator: 3, denominator: .max))
        #expect(try #require(large.multiplying(by: reciprocal))
            == ExactTime(numerator: 1, denominator: 1))

        let oneThird = try #require(ExactTime(numerator: 1, denominator: 3))
        let twoSixths = try #require(ExactTime(numerator: 2, denominator: 6))
        #expect(oneThird.compared(to: twoSixths) == .equal)
        #expect(try #require(oneThird.adding(twoSixths))
            == ExactTime(numerator: 2, denominator: 3))
    }

    @Test("Affine mapping preserves exact frame-grid endpoint")
    func affineMappingIsExact() throws {
        let point = try #require(ExactTime(numerator: 3_003, denominator: 24_000))
        let inputEnd = try #require(ExactTime(numerator: 6_006, denominator: 24_000))
        let outputStart = try #require(ExactTime(
            numerator: 77_192_716,
            denominator: 24_000
        ))
        let outputEnd = try #require(ExactTime(
            numerator: 77_198_722,
            denominator: 24_000
        ))
        let result = try #require(ExactTime.affinePoint(
            point,
            inputStart: .zero,
            inputEnd: inputEnd,
            outputStart: outputStart,
            outputEnd: outputEnd
        ))
        #expect(result == ExactTime(numerator: 77_195_719, denominator: 24_000))
    }

    @Test("Unrepresentable exact results are unavailable")
    func unrepresentableResultIsUnavailable() throws {
        let maximum = try #require(ExactTime(numerator: .max, denominator: 1))
        let one = try #require(ExactTime(numerator: 1, denominator: 1))
        #expect(maximum.adding(one) == nil)

        let tiny = try #require(ExactTime(numerator: 1, denominator: .max))
        #expect(tiny.dividing(by: maximum) == nil)
    }

    @Test("Exact range exposes an exact positive duration")
    func exactRangeDuration() throws {
        let start = try #require(ExactTime(numerator: 10, denominator: 1))
        let end = try #require(ExactTime(numerator: 81, denominator: 8))
        let range = try #require(FinalCutPro.FCPXML.ExactTimeRange(
            start: start,
            end: end
        ))
        #expect(range.duration == ExactTime(numerator: 1, denominator: 8))
        #expect(FinalCutPro.FCPXML.ExactTimeRange(start: range.end, end: range.start) == nil)
    }

    @Test("Exact time preserves values wider than the legacy Fraction boundary")
    func exactTimePreservesWideRationals() throws {
        let numerator = Int128(Int64.max) + 1
        let value = try #require(ExactTime(numerator: numerator, denominator: 3))

        #expect(value.numerator == numerator)
        #expect(value.denominator == 3)
        #expect(value.fraction == nil)
        #expect(value.compatibilityFraction != nil)
    }
}
