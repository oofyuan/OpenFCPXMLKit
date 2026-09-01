//
//  RetimingSegment.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Linear timeline↔media mapping segment for projection windows.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// One linear mapping between container (timeline) time and media time.
    ///
    /// Timeline periods are always forward (`timelineStart` ≤ `timelineEnd`).
    /// Media spans may reverse (`mediaEnd` &lt; `mediaStart`) when playback is reversed.
    ///
    /// Identity segments are emitted when no usable ``TimeMap`` is present.
    /// When a ``TimeMap`` has multiple `timept` entries, one segment is emitted per
    /// consecutive pair (normalized onto clip duration), including reverse playback.
    public struct RetimingSegment: Hashable, Sendable, Equatable {
        /// Inclusive timeline start (sequence-local unless composed further).
        public var timelineStart: Fraction

        /// Exclusive timeline end.
        public var timelineEnd: Fraction

        /// Media start (may be greater than ``mediaEnd`` when reversed).
        public var mediaStart: Fraction

        /// Media end.
        public var mediaEnd: Fraction

        /// Authoritative endpoints used by projection and restoration calculations.
        ///
        /// The legacy `Fraction` properties above remain available for display/reporting
        /// compatibility. When a valid affine result exceeds that 64-bit boundary, those legacy
        /// values are bounded presentation approximations and these values remain exact.
        public var exactTimelineStart: ExactTime
        public var exactTimelineEnd: ExactTime
        public var exactMediaStart: ExactTime
        public var exactMediaEnd: ExactTime

        /// Playback speed magnitude: `abs(mediaDelta / remappedTimeDelta)`.
        /// Identity is `1`; hold approaches `0`; `2` means roughly 200% media rate.
        public var scale: Double

        /// Whether media plays in reverse over this segment (`mediaEnd` &lt; `mediaStart`
        /// while timeline occupancy advances).
        public var isReversed: Bool

        public init(
            timelineStart: Fraction,
            timelineEnd: Fraction,
            mediaStart: Fraction,
            mediaEnd: Fraction,
            scale: Double = 1,
            isReversed: Bool = false
        ) {
            let exactTimelineStart = ExactTime(timelineStart)!
            let exactTimelineEnd = ExactTime(timelineEnd)!
            let exactMediaStart = ExactTime(mediaStart)!
            let exactMediaEnd = ExactTime(mediaEnd)!
            self.timelineStart = timelineStart
            self.timelineEnd = timelineEnd
            self.mediaStart = mediaStart
            self.mediaEnd = mediaEnd
            self.exactTimelineStart = exactTimelineStart
            self.exactTimelineEnd = exactTimelineEnd
            self.exactMediaStart = exactMediaStart
            self.exactMediaEnd = exactMediaEnd
            self.scale = scale
            self.isReversed = isReversed
        }

        init?(
            exactTimelineStart: ExactTime,
            exactTimelineEnd: ExactTime,
            exactMediaStart: ExactTime,
            exactMediaEnd: ExactTime,
            scale: Double = 1,
            isReversed: Bool = false
        ) {
            guard let timelineStart = exactTimelineStart.compatibilityFraction,
                  let timelineEnd = exactTimelineEnd.compatibilityFraction,
                  let mediaStart = exactMediaStart.compatibilityFraction,
                  let mediaEnd = exactMediaEnd.compatibilityFraction
            else { return nil }
            self.timelineStart = timelineStart
            self.timelineEnd = timelineEnd
            self.mediaStart = mediaStart
            self.mediaEnd = mediaEnd
            self.exactTimelineStart = exactTimelineStart
            self.exactTimelineEnd = exactTimelineEnd
            self.exactMediaStart = exactMediaStart
            self.exactMediaEnd = exactMediaEnd
            self.scale = scale
            self.isReversed = isReversed
        }

        /// Forward timeline occupancy length in seconds (`max(0, timelineEnd − timelineStart)`).
        public var timelineDuration: Double {
            max(0, exactTimelineEnd.doubleValue - exactTimelineStart.doubleValue)
        }

        /// Absolute media span length in seconds (`abs(mediaEnd − mediaStart)`).
        ///
        /// Hold / freeze segments approach `0` even when timeline occupancy is positive.
        public var mediaDuration: Double {
            abs(exactMediaEnd.doubleValue - exactMediaStart.doubleValue)
        }

        /// `true` when media does not advance over a positive timeline span (hold / freeze).
        public var isHold: Bool {
            exactTimelineStart.compared(to: exactTimelineEnd) == .less
                && exactMediaStart.compared(to: exactMediaEnd) == .equal
        }

        /// Non-authoritative display scale derived from exact endpoints. An infinite value means
        /// the ratio is unavailable as a finite `Double`; it never invalidates the endpoints.
        static func scaleMetadata(
            timelineStart: Fraction,
            timelineEnd: Fraction,
            mediaStart: Fraction,
            mediaEnd: Fraction
        ) -> Double {
            if ProjectionTiming.compare(mediaStart, mediaEnd) == .equal { return 0 }
            guard let timelineSpan = ProjectionTiming.subtracting(timelineEnd, timelineStart),
                  let mediaSpan = ProjectionTiming.subtracting(mediaEnd, mediaStart),
                  let ratio = ProjectionTiming.dividing(mediaSpan, timelineSpan)
            else { return .infinity }
            let value = abs(ratio.doubleValue)
            return value.isFinite ? value : .infinity
        }

        static func scaleMetadata(
            timelineStart: ExactTime,
            timelineEnd: ExactTime,
            mediaStart: ExactTime,
            mediaEnd: ExactTime
        ) -> Double {
            if mediaStart.compared(to: mediaEnd) == .equal { return 0 }
            guard let timelineSpan = timelineEnd.subtracting(timelineStart),
                  let mediaSpan = mediaEnd.subtracting(mediaStart),
                  let ratio = mediaSpan.dividing(by: timelineSpan)
            else { return .infinity }
            let value = abs(ratio.doubleValue)
            return value.isFinite ? value : .infinity
        }

        /// Whether this segment can safely become an authoritative media-usage window.
        var hasUsableProjectionEndpoints: Bool {
            guard exactTimelineStart.compared(to: exactTimelineEnd) == .less else { return false }
            let mediaOrdering = exactMediaStart.compared(to: exactMediaEnd)
            return mediaOrdering != .equal || isHold
        }

        /// `true` when `timeline` lies in the half-open occupancy `[timelineStart, timelineEnd)`.
        public func containsTimeline(_ timeline: Fraction) -> Bool {
            guard let timeline = ExactTime(timeline) else { return false }
            let startOrder = timeline.compared(to: exactTimelineStart)
            let endOrder = timeline.compared(to: exactTimelineEnd)
            return startOrder != .less && endOrder == .less
        }

        /// `true` when this segment’s timeline occupancy overlaps `[start, end)`.
        public func intersectsTimeline(start: Fraction, end: Fraction) -> Bool {
            guard let start = ExactTime(start), let end = ExactTime(end) else { return false }
            let (queryStart, queryEnd) = ProjectionTiming.ordered(start, end)
            guard queryStart.compared(to: queryEnd) == .less else { return false }
            let startsBeforeQueryEnd = exactTimelineStart.compared(to: queryEnd)
            let queryStartsBeforeEnd = queryStart.compared(to: exactTimelineEnd)
            return startsBeforeQueryEnd == .less && queryStartsBeforeEnd == .less
        }

        /// Returns a copy clipped to the overlapping timeline range `[start, end)`, remapping
        /// media endpoints through ``mediaPoint(forTimeline:)``.
        ///
        /// Returns `nil` when there is no positive overlap.
        public func clipped(toTimelineStart start: Fraction, timelineEnd end: Fraction) -> RetimingSegment? {
            guard let start = ExactTime(start), let end = ExactTime(end) else { return nil }
            let (queryStart, queryEnd) = ProjectionTiming.ordered(start, end)
            let clippedStart = ProjectionTiming.maximum(exactTimelineStart, queryStart)
            let clippedEnd = ProjectionTiming.minimum(exactTimelineEnd, queryEnd)
            guard clippedStart.compared(to: clippedEnd) == .less,
                  let clippedMediaStart = projectedExactMediaPoint(forTimeline: clippedStart),
                  let clippedMediaEnd = projectedExactMediaPoint(forTimeline: clippedEnd)
            else { return nil }
            return RetimingSegment(
                exactTimelineStart: clippedStart,
                exactTimelineEnd: clippedEnd,
                exactMediaStart: clippedMediaStart,
                exactMediaEnd: clippedMediaEnd,
                scale: scale,
                isReversed: clippedMediaEnd.compared(to: clippedMediaStart) == .less
            )
        }

        /// Identity mapping: clip occupies `[timelineStart, timelineStart + duration)` and
        /// reads media `[mediaStart, mediaStart + duration)`.
        public static func identity(
            timelineStart: Fraction,
            duration: Fraction,
            mediaStart: Fraction
        ) -> RetimingSegment? {
            guard let exactTimelineStart = ExactTime(timelineStart),
                  let exactDuration = ExactTime(duration),
                  let exactMediaStart = ExactTime(mediaStart),
                  let timelineEnd = exactTimelineStart.adding(exactDuration),
                  let mediaEnd = exactMediaStart.adding(exactDuration)
            else { return nil }
            return RetimingSegment(
                exactTimelineStart: exactTimelineStart,
                exactTimelineEnd: timelineEnd,
                exactMediaStart: exactMediaStart,
                exactMediaEnd: mediaEnd,
                scale: 1,
                isReversed: false
            )
        }

        /// Composes a child segment through a parent container segment.
        ///
        /// Parent maps outer timeline ↔ nested sequence (media) time. Child maps nested
        /// timeline ↔ asset media. Overlap is taken in the nested-time domain (parent media
        /// axis vs child timeline axis). Returns an empty array when there is no overlap.
        public static func composing(
            parent: RetimingSegment,
            child: RetimingSegment
        ) -> [RetimingSegment] {
            // A freeze has positive outer occupancy but a zero-width media range. Treat its
            // fixed media point as a point lookup in the child mapping instead of applying
            // the ordinary positive-width overlap test.
            if parent.isHold {
                guard child.containsExactTimeline(parent.exactMediaStart),
                      let childMediaPoint = child.projectedExactMediaPoint(
                          forTimeline: parent.exactMediaStart
                      )
                else { return [] }

                guard let result = RetimingSegment(
                        exactTimelineStart: parent.exactTimelineStart,
                        exactTimelineEnd: parent.exactTimelineEnd,
                        exactMediaStart: childMediaPoint,
                        exactMediaEnd: childMediaPoint,
                        scale: 0,
                        isReversed: false
                    ) else { return [] }
                return [result]
            }

            let (parentMediaLo, parentMediaHi) = ProjectionTiming.ordered(
                parent.exactMediaStart,
                parent.exactMediaEnd
            )
            let (childTimelineLo, childTimelineHi) = ProjectionTiming.ordered(
                child.exactTimelineStart,
                child.exactTimelineEnd
            )
            let overlapLo = ProjectionTiming.maximum(parentMediaLo, childTimelineLo)
            let overlapHi = ProjectionTiming.minimum(parentMediaHi, childTimelineHi)
            guard overlapLo.compared(to: overlapHi) == .less,
                  let outerStart = parent.projectedExactTimelinePoint(forMedia: overlapLo),
                  let outerEnd = parent.projectedExactTimelinePoint(forMedia: overlapHi),
                  let childMediaAtLo = child.projectedExactMediaPoint(forTimeline: overlapLo),
                  let childMediaAtHi = child.projectedExactMediaPoint(forTimeline: overlapHi)
            else { return [] }
            let (timelineStart, timelineEnd) = ProjectionTiming.ordered(outerStart, outerEnd)
            guard timelineStart.compared(to: timelineEnd) == .less else { return [] }

            let composedScale: Double = {
                guard parent.scale.isFinite, child.scale.isFinite else { return .infinity }
                let value = max(0, parent.scale) * max(0, child.scale)
                return value.isFinite ? value : .infinity
            }()
            let composedReversed = parent.isReversed != child.isReversed

            guard let result = RetimingSegment(
                    exactTimelineStart: timelineStart,
                    exactTimelineEnd: timelineEnd,
                    exactMediaStart: childMediaAtLo,
                    exactMediaEnd: childMediaAtHi,
                    scale: composedScale,
                    isReversed: composedReversed
                ) else { return [] }
            return [result]
        }

        /// Maps a media-axis point through this segment onto the timeline axis.
        public func timelinePoint(forMedia media: Fraction) -> Fraction? {
            guard let media = ExactTime(media) else { return nil }
            return projectedExactTimelinePoint(forMedia: media)?.compatibilityFraction
        }

        /// Authoritative exact mapping of a media-axis point onto the timeline axis.
        public func exactTimelinePoint(forMedia media: ExactTime) -> ExactTime? {
            projectedExactTimelinePoint(forMedia: media)
        }

        private func projectedExactTimelinePoint(forMedia media: ExactTime) -> ExactTime? {
            if media.compared(to: exactMediaStart) == .equal { return exactTimelineStart }
            if media.compared(to: exactMediaEnd) == .equal { return exactTimelineEnd }
            return ExactTime.affinePoint(
                media,
                inputStart: exactMediaStart,
                inputEnd: exactMediaEnd,
                outputStart: exactTimelineStart,
                outputEnd: exactTimelineEnd
            )
        }

        /// Maps a timeline-axis point through this segment onto the media axis.
        public func mediaPoint(forTimeline timeline: Fraction) -> Fraction? {
            guard let timeline = ExactTime(timeline) else { return nil }
            return projectedExactMediaPoint(forTimeline: timeline)?.compatibilityFraction
        }

        /// Authoritative exact mapping of a timeline-axis point onto the media axis.
        public func exactMediaPoint(forTimeline timeline: ExactTime) -> ExactTime? {
            projectedExactMediaPoint(forTimeline: timeline)
        }

        private func projectedExactMediaPoint(forTimeline timeline: ExactTime) -> ExactTime? {
            if timeline.compared(to: exactTimelineStart) == .equal { return exactMediaStart }
            if timeline.compared(to: exactTimelineEnd) == .equal { return exactMediaEnd }
            return ExactTime.affinePoint(
                timeline,
                inputStart: exactTimelineStart,
                inputEnd: exactTimelineEnd,
                outputStart: exactMediaStart,
                outputEnd: exactMediaEnd
            )
        }

        private func containsExactTimeline(_ timeline: ExactTime) -> Bool {
            timeline.compared(to: exactTimelineStart) != .less
                && timeline.compared(to: exactTimelineEnd) == .less
        }

        /// Composes `child` through each overlapping parent segment.
        ///
        /// `parents` is ordered outermost → innermost (same as walk push order).
        public static func composing(
            parents: [RetimingSegment],
            child: RetimingSegment
        ) -> [RetimingSegment] {
            guard !parents.isEmpty else { return [child] }
            var current = [child]
            // Innermost parent first.
            for parent in parents.reversed() {
                current = current.flatMap { composing(parent: parent, child: $0) }
            }
            return current
        }

        /// Composes a child through nested container layers, where each inner array contains
        /// alternative segments from one container's timeMap rather than additional nesting.
        static func composing(
            parentLayers: [[RetimingSegment]],
            child: RetimingSegment
        ) -> [RetimingSegment] {
            guard !parentLayers.isEmpty else { return [child] }
            var current = [child]
            for layer in parentLayers.reversed() {
                current = current.flatMap { childSegment in
                    layer.flatMap { parentSegment in
                        composing(parent: parentSegment, child: childSegment)
                    }
                }
            }
            return current
        }

        /// Composes every child through the parent chain (outermost → innermost).
        ///
        /// Useful when both a container and a nested clip expose multi-point ``TimeMap``
        /// segments: each child is composed independently, then results are concatenated.
        public static func composing(
            parents: [RetimingSegment],
            children: [RetimingSegment]
        ) -> [RetimingSegment] {
            guard !children.isEmpty else { return [] }
            guard !parents.isEmpty else { return children }
            return children.flatMap { composing(parents: parents, child: $0) }
        }
    }
}
