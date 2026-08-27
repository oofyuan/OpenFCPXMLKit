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
    ) -> [FinalCutPro.FCPXML.RetimingSegment] {
        let points = Array(timePoints)
        guard points.count >= 2 else { return [] }

        let first = points[0]
        let last = points[points.count - 1]

        // Time-map interpolation and speed summaries use seconds. Authoritative endpoints are
        // converted back through ProjectionTiming's bounded conversion below.
        let firstTimeSeconds = first.time.doubleValue
        let mapSpanSeconds = last.time.doubleValue - firstTimeSeconds
        guard abs(mapSpanSeconds) > .ulpOfOne else { return [] }

        var segments: [FinalCutPro.FCPXML.RetimingSegment] = []
        segments.reserveCapacity(points.count - 1)

        for index in 0 ..< (points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            let aTimeSeconds = a.time.doubleValue
            let bTimeSeconds = b.time.doubleValue
            let remappedDeltaSeconds = bTimeSeconds - aTimeSeconds
            guard abs(remappedDeltaSeconds) > .ulpOfOne else { continue }

            // Placement is interpolated in Double, then converted with an explicit precision
            // and integer bound so endpoint construction cannot saturate.
            let startFraction = (aTimeSeconds - firstTimeSeconds) / mapSpanSeconds
            let endFraction = (bTimeSeconds - firstTimeSeconds) / mapSpanSeconds
            let base = clipOffset.doubleValue
            let span = clipDuration.doubleValue
            guard let timelineStart = FinalCutPro.FCPXML.ProjectionTiming.fraction(
                seconds: base + span * startFraction
            ),
            let timelineEnd = FinalCutPro.FCPXML.ProjectionTiming.fraction(
                seconds: base + span * endFraction
            ),
            let (forwardStart, forwardEnd) = FinalCutPro.FCPXML.ProjectionTiming.ordered(
                timelineStart,
                timelineEnd
            ),
            FinalCutPro.FCPXML.ProjectionTiming.isPositiveRange(
                start: forwardStart,
                end: forwardEnd
            )
            else { continue }

            // Ensure timeline advances forward for occupancy reporting.
            let mediaStart = a.originalTime
            let mediaEnd = b.originalTime
            let mediaDeltaSeconds = mediaEnd.doubleValue - mediaStart.doubleValue
            guard mediaDeltaSeconds.isFinite else { continue }
            let isReversed = FinalCutPro.FCPXML.ProjectionTiming.compare(
                mediaEnd,
                mediaStart
            ) == .less
            let scale = abs(mediaDeltaSeconds / remappedDeltaSeconds)
            guard scale.isFinite else { continue }

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
