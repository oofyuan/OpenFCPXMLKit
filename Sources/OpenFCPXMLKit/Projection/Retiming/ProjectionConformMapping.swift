//
//  ProjectionConformMapping.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Exact, explicit mapping between a clip's source-media duration and its parent-timeline
    /// occupancy. Absolute source-media origins are never scaled by this mapping.
    struct ProjectionConformMapping: Equatable, Sendable {
        let timelineDurationPerSourceDuration: Fraction

        static let identity = ProjectionConformMapping(
            timelineDurationPerSourceDuration: Fraction(1, 1)
        )

        var isIdentity: Bool {
            ProjectionTiming.compare(
                timelineDurationPerSourceDuration,
                Fraction(1, 1)
            ) == .equal
        }

        static func resolving(
            for element: any OFKXMLElement,
            resources: (any OFKXMLElement)?
        ) throws -> ProjectionConformMapping {
            guard let conform = element.firstChild(whereFCPElement: .conformRate),
                  conform.scaleEnabled
            else { return .identity }

            // The resolver is deliberately scoped to the conform-rate owned by this host.
            // Child attributes must not inherit this factor while being decoded. Unlike the old
            // attribute getter, this boundary also distinguishes a valid no-op from missing
            // mapping evidence.
            guard let sourceFrameRate = conform.srcFrameRate?.timecodeFrameRate,
                  let (_, remainingAncestors) = element.fcpAncestorTimeline(
                      ancestors: nil as [any OFKXMLElement]?,
                      includingSelf: true
                  ),
                  let (parent, parentAncestors) = element._fcpFirstContainerAncestorWithZeroLane(
                      ancestors: remainingAncestors,
                      includingSelf: false
                  ),
                  let timelineFrameRate = parent._fcpTimecodeFrameRate(
                      source: .localToElement,
                      breadcrumbs: parentAncestors,
                      resources: resources
                  )
            else {
                throw ProjectionTiming.ArithmeticError.unrepresentable
            }
            guard timelineFrameRate != sourceFrameRate else { return .identity }

            // A nil table result is an explicit wall-clock/no-op combination, not permission to
            // manufacture an approximate factor.
            guard let factor = fcpConformRateScalingFraction(
                timelineFrameRate: timelineFrameRate,
                mediaFrameRate: sourceFrameRate
            ) else { return .identity }
            guard ProjectionTiming.compare(factor, .zero) == .greater else {
                throw ProjectionTiming.ArithmeticError.unrepresentable
            }
            return ProjectionConformMapping(
                timelineDurationPerSourceDuration: factor
            )
        }

        func sourceDuration(forTimelineDuration duration: Fraction) -> Fraction? {
            ProjectionTiming.dividing(duration, timelineDurationPerSourceDuration)
        }

        func timelineDuration(forSourceDuration duration: Fraction) -> Fraction? {
            ProjectionTiming.multiplying(duration, timelineDurationPerSourceDuration)
        }
    }
}
