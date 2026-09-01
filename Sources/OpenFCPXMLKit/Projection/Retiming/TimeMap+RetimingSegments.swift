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
    /// - Timeline: the part of the adjusted `time` axis selected by the clip's
    ///   `start` / `duration`, placed at `clipOffset`
    /// - Media: the corresponding affine slice of
    ///   `a.originalTime` → `b.originalTime` (may reverse)
    /// - Scale: `abs(mediaDelta / remappedTimeDelta)` when remapped time advances
    ///
    /// Throws when the selected adjusted-time interval is not covered exactly or when an
    /// interior point uses a smooth transition curve that this exact projector cannot evaluate.
    func retimingSegments(
        clipOffset: Fraction,
        clipDuration: Fraction,
        clipTimeStart: Fraction? = nil
    ) throws -> [FinalCutPro.FCPXML.RetimingSegment] {
        let points = Array(timePoints)
        guard points.count >= 2,
              FinalCutPro.FCPXML.ProjectionTiming.isPositiveRange(
                  start: .zero,
                  end: clipDuration
              )
        else {
            throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
        }

        let first = points[0]
        let last = points[points.count - 1]
        let selectedTimeStart = clipTimeStart ?? first.time
        guard FinalCutPro.FCPXML.ProjectionTiming.compare(first.time, last.time) == .less,
              let selectedTimeEnd = FinalCutPro.FCPXML.ProjectionTiming.adding(
                  selectedTimeStart,
                  clipDuration
              ),
              let clipEnd = FinalCutPro.FCPXML.ProjectionTiming.adding(clipOffset, clipDuration)
        else { throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable }

        var segments: [FinalCutPro.FCPXML.RetimingSegment] = []
        segments.reserveCapacity(points.count - 1)

        var coveredEnd: Fraction?
        for index in 0 ..< (points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            guard FinalCutPro.FCPXML.ProjectionTiming.compare(a.time, b.time) == .less,
                  let sliceStart = FinalCutPro.FCPXML.ProjectionTiming.maximum(
                      a.time,
                      selectedTimeStart
                  ),
                  let sliceEnd = FinalCutPro.FCPXML.ProjectionTiming.minimum(
                      b.time,
                      selectedTimeEnd
                  )
            else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }
            guard FinalCutPro.FCPXML.ProjectionTiming.isPositiveRange(
                start: sliceStart,
                end: sliceEnd
            ) else { continue }
            let startsAtExpectedBoundary: Bool
            if let coveredEnd {
                startsAtExpectedBoundary = FinalCutPro.FCPXML.ProjectionTiming.compare(
                    coveredEnd,
                    sliceStart
                ) == .equal
            } else {
                startsAtExpectedBoundary = FinalCutPro.FCPXML.ProjectionTiming.compare(
                    selectedTimeStart,
                    sliceStart
                ) == .equal
            }
            guard startsAtExpectedBoundary else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }

            guard let timelineStart = FinalCutPro.FCPXML.ProjectionTiming.affineExactPoint(
                sliceStart,
                inputStart: selectedTimeStart,
                inputEnd: selectedTimeEnd,
                outputStart: clipOffset,
                outputEnd: clipEnd
            ),
            let timelineEnd = FinalCutPro.FCPXML.ProjectionTiming.affineExactPoint(
                sliceEnd,
                inputStart: selectedTimeStart,
                inputEnd: selectedTimeEnd,
                outputStart: clipOffset,
                outputEnd: clipEnd
            )
            else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }
            let (forwardStart, forwardEnd) = FinalCutPro.FCPXML.ProjectionTiming.ordered(
                timelineStart,
                timelineEnd
            )
            guard forwardStart.compared(to: forwardEnd) == .less else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }

            // Ensure timeline advances forward for occupancy reporting.
            let mediaStart = try exactOriginalTime(at: sliceStart, from: a, to: b)
            let mediaEnd = try exactOriginalTime(at: sliceEnd, from: a, to: b)
            let mediaOrdering = mediaEnd.compared(to: mediaStart)
            let isReversed = mediaOrdering == .less
            let scale = FinalCutPro.FCPXML.RetimingSegment.scaleMetadata(
                timelineStart: forwardStart,
                timelineEnd: forwardEnd,
                mediaStart: mediaStart,
                mediaEnd: mediaEnd
            )

            guard let segment = FinalCutPro.FCPXML.RetimingSegment(
                    exactTimelineStart: forwardStart,
                    exactTimelineEnd: forwardEnd,
                    exactMediaStart: mediaStart,
                    exactMediaEnd: mediaEnd,
                    scale: scale,
                    isReversed: isReversed
                ) else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }
            segments.append(segment)
            coveredEnd = sliceEnd
        }

        guard !segments.isEmpty,
              let coveredEnd,
              FinalCutPro.FCPXML.ProjectionTiming.compare(
                  coveredEnd,
                  selectedTimeEnd
              ) == .equal
        else {
            throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
        }
        return segments
    }

    private func exactOriginalTime(
        at point: Fraction,
        from a: TimePoint,
        to b: TimePoint
    ) throws -> FinalCutPro.FCPXML.ExactTime {
        if FinalCutPro.FCPXML.ProjectionTiming.compare(point, a.time) == .equal {
            guard let result = FinalCutPro.FCPXML.ExactTime(a.originalTime) else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }
            return result
        }
        if FinalCutPro.FCPXML.ProjectionTiming.compare(point, b.time) == .equal {
            guard let result = FinalCutPro.FCPXML.ExactTime(b.originalTime) else {
                throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
            }
            return result
        }

        // FCP emits constant-speed smooth2 pairs without transition handles. They are affine.
        // A smooth pair with an explicit outgoing/incoming transition is a true curve; without
        // a curve evaluator, an interior endpoint cannot be claimed as exact.
        let isExactlyAffine = a.interpolation == .linear
            || (a.transitionOutTime == nil && b.transitionInTime == nil)
        guard isExactlyAffine,
              let result = FinalCutPro.FCPXML.ProjectionTiming.affineExactPoint(
                  point,
                  inputStart: a.time,
                  inputEnd: b.time,
                  outputStart: a.originalTime,
                  outputEnd: b.originalTime
              )
        else {
            throw FinalCutPro.FCPXML.ProjectionTiming.ArithmeticError.unrepresentable
        }
        return result
    }
}
