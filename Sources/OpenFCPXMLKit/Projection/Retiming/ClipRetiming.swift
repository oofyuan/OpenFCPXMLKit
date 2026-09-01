//
//  ClipRetiming.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Resolves RetimingSegment lists for a clip from timeMap and/or identity placement.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Builds retiming segments for a story element that exposes timing params.
    enum ClipRetiming {
        /// Resolves one or more ``RetimingSegment`` values for a clip placement.
        ///
        /// Priority:
        /// 1. ``TimeMap`` with ≥ 2 points explicitly maps adjusted clip-local time to original
        ///    source-media time.
        /// 2. Otherwise `conformMapping` maps the raw parent-timeline duration to a source-media
        ///    duration while leaving the absolute source origin unchanged.
        static func segments(
            timeMap: TimeMap?,
            timelineOffset: Fraction,
            timelineDuration: Fraction,
            sourceMediaStart: Fraction,
            timeMapStart: Fraction? = nil,
            conformMapping: ProjectionConformMapping = .identity
        ) throws -> [RetimingSegment] {
            if let timeMap {
                return try timeMap.retimingSegments(
                    clipOffset: timelineOffset,
                    clipDuration: timelineDuration,
                    clipTimeStart: timeMapStart
                )
            }

            guard let timelineEnd = ProjectionTiming.adding(
                timelineOffset,
                timelineDuration
            ),
            let sourceDuration = conformMapping.sourceDuration(
                forTimelineDuration: timelineDuration
            ),
            let sourceMediaEnd = ProjectionTiming.adding(sourceMediaStart, sourceDuration)
            else {
                throw ProjectionTiming.ArithmeticError.unrepresentable
            }
            return [RetimingSegment(
                timelineStart: timelineOffset,
                timelineEnd: timelineEnd,
                mediaStart: sourceMediaStart,
                mediaEnd: sourceMediaEnd,
                scale: RetimingSegment.scaleMetadata(
                    timelineStart: timelineOffset,
                    timelineEnd: timelineEnd,
                    mediaStart: sourceMediaStart,
                    mediaEnd: sourceMediaEnd
                ),
                isReversed: false
            )]
        }
    }
}
