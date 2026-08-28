//
//  TimeMap+RetimingSegments.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Builds RetimingSegment values from consecutive timeMap time points.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML.TimeMap {
    /// Converts consecutive ``TimePoint`` pairs into ``RetimingSegment`` values placed on the
    /// sequence timeline.
    ///
    /// Each pair `(a, b)` maps:
    /// - Timeline: normalized onto `[clipOffset, clipOffset + clipDuration)` using the
    ///   first→last remapped `time` span (so occupancy matches the spine `duration`)
    /// - Media: `a.originalTime` → `b.originalTime` (may reverse)
    /// - Scale: `abs(mediaDelta / remappedTimeDelta)` when remapped time advances
    ///
    /// Returns an empty array when fewer than two points exist or the remapped span is zero.
    func retimingSegments(
        clipOffset: Fraction,
        clipDuration: Fraction
    ) throws -> [FinalCutPro.FCPXML.RetimingSegment] {
        let points = Array(timePoints)
        guard points.count >= 2 else { return [] }

        let first = points[0]
        let last = points[points.count - 1]
        guard FinalCutPro.FCPXML.ProjectionTiming.compare(first.time, last.time) != .equal,
              let clipEnd = FinalCutPro.FCPXML.ProjectionTiming.adding(
                  clipOffset,
                  clipDuration
              )
        else {
            if FinalCutPro.FCPXML.ProjectionTiming.compare(first.time, last.time) == .equal {
                return []
            }
            throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
        }

        var segments: [FinalCutPro.FCPXML.RetimingSegment] = []
        segments.reserveCapacity(points.count - 1)

        for index in 0 ..< (points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            guard FinalCutPro.FCPXML.ProjectionTiming.compare(a.time, b.time) != .equal else {
                continue
            }
            guard let timelineStart = FinalCutPro.FCPXML.ProjectionTiming.affinePoint(
                a.time,
                inputStart: first.time,
                inputEnd: last.time,
                outputStart: clipOffset,
                outputEnd: clipEnd
            ),
            let timelineEnd = FinalCutPro.FCPXML.ProjectionTiming.affinePoint(
                b.time,
                inputStart: first.time,
                inputEnd: last.time,
                outputStart: clipOffset,
                outputEnd: clipEnd
            ),
            let (forwardStart, forwardEnd) = FinalCutPro.FCPXML.ProjectionTiming.ordered(
                timelineStart,
                timelineEnd
            ),
            FinalCutPro.FCPXML.ProjectionTiming.isPositiveRange(
                start: forwardStart,
                end: forwardEnd
            )
            else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }

            // Ensure timeline advances forward for occupancy reporting.
            let mediaStart = a.originalTime
            let mediaEnd = b.originalTime
            guard let mediaOrdering = FinalCutPro.FCPXML.ProjectionTiming.compare(
                mediaEnd,
                mediaStart
            ) else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }
            let isReversed = mediaOrdering == .less
            let scale = FinalCutPro.FCPXML.RetimingSegment.scaleMetadata(
                timelineStart: a.time,
                timelineEnd: b.time,
                mediaStart: mediaStart,
                mediaEnd: mediaEnd
            )

            segments.append(
                FinalCutPro.FCPXML.RetimingSegment(
                    timelineStart: forwardStart,
                    timelineEnd: forwardEnd,
                    mediaStart: mediaStart,
                    mediaEnd: mediaEnd,
                    scale: scale,
                    isReversed: isReversed
                )
            )
        }

        return segments
    }
}
