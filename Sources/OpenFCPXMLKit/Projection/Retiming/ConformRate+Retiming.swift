//
//  ConformRate+Retiming.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Applies basic conform-rate scaling metadata to retiming segments.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML.ConformRate {
    /// Scaling factor applied when ``scaleEnabled`` is true and both frame rates are known.
    ///
    /// Uses the shared FCPXML conform table (`fcpConformRateScalingFactor`).
    /// Returns `nil` when scaling does not apply (disabled, missing rate, or same-group no-op).
    func mediaScalingFactor(
        timelineFrameRate: TimecodeFrameRate
    ) -> Double? {
        guard scaleEnabled,
              let mediaFrameRate = srcFrameRate?.timecodeFrameRate
        else { return nil }

        return fcpConformRateScalingFactor(
            timelineFrameRate: timelineFrameRate,
            mediaFrameRate: mediaFrameRate
        )
    }

    /// Returns a copy of `segment` with ``RetimingSegment/scale`` set from the conform factor
    /// when applicable.
    ///
    /// Timeline and media span coordinates are left unchanged. This helper is non-authoritative
    /// reporting metadata; ``TimelineProjector`` applies conform through its explicit exact
    /// coordinate mapping instead.
    func applyingConform(
        to segment: FinalCutPro.FCPXML.RetimingSegment,
        timelineFrameRate: TimecodeFrameRate?
    ) -> FinalCutPro.FCPXML.RetimingSegment {
        guard let timelineFrameRate,
              let factor = mediaScalingFactor(timelineFrameRate: timelineFrameRate),
              abs(factor) > .ulpOfOne
        else { return segment }

        return FinalCutPro.FCPXML.RetimingSegment(
            exactTimelineStart: segment.exactTimelineStart,
            exactTimelineEnd: segment.exactTimelineEnd,
            exactMediaStart: segment.exactMediaStart,
            exactMediaEnd: segment.exactMediaEnd,
            scale: abs(factor),
            isReversed: segment.isReversed
        ) ?? segment
    }
}
