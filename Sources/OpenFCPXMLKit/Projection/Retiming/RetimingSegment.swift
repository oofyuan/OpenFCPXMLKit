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
            self.timelineStart = timelineStart
            self.timelineEnd = timelineEnd
            self.mediaStart = mediaStart
            self.mediaEnd = mediaEnd
            self.scale = scale
            self.isReversed = isReversed
        }

        /// Forward timeline occupancy length in seconds (`max(0, timelineEnd − timelineStart)`).
        public var timelineDuration: Double {
            max(0, timelineEnd.doubleValue - timelineStart.doubleValue)
        }

        /// Absolute media span length in seconds (`abs(mediaEnd − mediaStart)`).
        ///
        /// Hold / freeze segments approach `0` even when timeline occupancy is positive.
        public var mediaDuration: Double {
            abs(mediaEnd.doubleValue - mediaStart.doubleValue)
        }

        /// `true` when media does not advance over a positive timeline span (hold / freeze).
        public var isHold: Bool {
            ProjectionTiming.isPositiveRange(start: timelineStart, end: timelineEnd)
                && ProjectionTiming.compare(mediaStart, mediaEnd) == .equal
        }

        /// Whether this segment can safely become an authoritative media-usage window.
        var hasUsableProjectionEndpoints: Bool {
            let endpoints = [timelineStart, timelineEnd, mediaStart, mediaEnd]
            guard endpoints.allSatisfy(ProjectionTiming.hasUsableEndpoint),
                  scale.isFinite,
                  ProjectionTiming.isPositiveRange(start: timelineStart, end: timelineEnd),
                  let mediaOrdering = ProjectionTiming.compare(mediaStart, mediaEnd)
            else { return false }
            return mediaOrdering != .equal || scale == 0
        }

        /// `true` when `timeline` lies in the half-open occupancy `[timelineStart, timelineEnd)`.
        public func containsTimeline(_ timeline: Fraction) -> Bool {
            guard let startOrder = ProjectionTiming.compare(timeline, timelineStart),
                  let endOrder = ProjectionTiming.compare(timeline, timelineEnd)
            else { return false }
            return startOrder != .less && endOrder == .less
        }

        /// `true` when this segment’s timeline occupancy overlaps `[start, end)`.
        public func intersectsTimeline(start: Fraction, end: Fraction) -> Bool {
            guard let (queryStart, queryEnd) = ProjectionTiming.ordered(start, end),
                  ProjectionTiming.isPositiveRange(start: queryStart, end: queryEnd),
                  let startsBeforeQueryEnd = ProjectionTiming.compare(timelineStart, queryEnd),
                  let queryStartsBeforeEnd = ProjectionTiming.compare(queryStart, timelineEnd)
            else { return false }
            return startsBeforeQueryEnd == .less && queryStartsBeforeEnd == .less
        }

        /// Returns a copy clipped to the overlapping timeline range `[start, end)`, remapping
        /// media endpoints through ``mediaPoint(forTimeline:)``.
        ///
        /// Returns `nil` when there is no positive overlap.
        public func clipped(toTimelineStart start: Fraction, timelineEnd end: Fraction) -> RetimingSegment? {
            guard let (queryStart, queryEnd) = ProjectionTiming.ordered(start, end),
                  let clippedStart = ProjectionTiming.maximum(timelineStart, queryStart),
                  let clippedEnd = ProjectionTiming.minimum(timelineEnd, queryEnd),
                  ProjectionTiming.isPositiveRange(start: clippedStart, end: clippedEnd),
                  let clippedMediaStart = projectedMediaPoint(forTimeline: clippedStart),
                  let clippedMediaEnd = projectedMediaPoint(forTimeline: clippedEnd)
            else { return nil }
            return RetimingSegment(
                timelineStart: clippedStart,
                timelineEnd: clippedEnd,
                mediaStart: clippedMediaStart,
                mediaEnd: clippedMediaEnd,
                scale: scale,
                isReversed: ProjectionTiming.compare(clippedMediaEnd, clippedMediaStart) == .less
            )
        }

        /// Identity mapping: clip occupies `[timelineStart, timelineStart + duration)` and
        /// reads media `[mediaStart, mediaStart + duration)`.
        public static func identity(
            timelineStart: Fraction,
            duration: Fraction,
            mediaStart: Fraction
        ) -> RetimingSegment {
            // Use Double-backed composition: conform-scaled model fractions mixed with
            // literal FCPXML rationals can trap on Int overflow in Fraction `+`.
            RetimingSegment(
                timelineStart: timelineStart,
                timelineEnd: ProjectionTiming.adding(timelineStart, duration),
                mediaStart: mediaStart,
                mediaEnd: ProjectionTiming.adding(mediaStart, duration),
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
                let parentEndpoints = [
                    parent.timelineStart,
                    parent.timelineEnd,
                    parent.mediaStart,
                ]
                guard parentEndpoints.allSatisfy(ProjectionTiming.hasUsableEndpoint),
                      child.containsTimeline(parent.mediaStart),
                      let childMediaPoint = child.projectedMediaPoint(
                          forTimeline: parent.mediaStart
                      ),
                      ProjectionTiming.hasUsableEndpoint(childMediaPoint)
                else { return [] }

                return [
                    RetimingSegment(
                        timelineStart: parent.timelineStart,
                        timelineEnd: parent.timelineEnd,
                        mediaStart: childMediaPoint,
                        mediaEnd: childMediaPoint,
                        scale: 0,
                        isReversed: false
                    )
                ]
            }

            guard let (parentMediaLo, parentMediaHi) = ProjectionTiming.ordered(
                parent.mediaStart,
                parent.mediaEnd
            ),
            let (childTimelineLo, childTimelineHi) = ProjectionTiming.ordered(
                child.timelineStart,
                child.timelineEnd
            ),
            let overlapLo = ProjectionTiming.maximum(parentMediaLo, childTimelineLo),
            let overlapHi = ProjectionTiming.minimum(parentMediaHi, childTimelineHi),
            ProjectionTiming.isPositiveRange(start: overlapLo, end: overlapHi),
            let outerStart = parent.projectedTimelinePoint(forMedia: overlapLo),
            let outerEnd = parent.projectedTimelinePoint(forMedia: overlapHi),
            let (timelineStart, timelineEnd) = ProjectionTiming.ordered(outerStart, outerEnd),
            ProjectionTiming.isPositiveRange(start: timelineStart, end: timelineEnd),
            let childMediaAtLo = child.projectedMediaPoint(forTimeline: overlapLo),
            let childMediaAtHi = child.projectedMediaPoint(forTimeline: overlapHi)
            else { return [] }

            let composedScale = max(0, parent.scale) * max(0, child.scale)
            guard composedScale.isFinite else { return [] }
            let composedReversed = parent.isReversed != child.isReversed

            return [
                RetimingSegment(
                    timelineStart: timelineStart,
                    timelineEnd: timelineEnd,
                    mediaStart: childMediaAtLo,
                    mediaEnd: childMediaAtHi,
                    scale: composedScale,
                    isReversed: composedReversed
                )
            ]
        }

        /// Maps a media-axis point through this segment onto the timeline axis.
        public func timelinePoint(forMedia media: Fraction) -> Fraction {
            projectedTimelinePoint(forMedia: media) ?? timelineStart
        }

        private func projectedTimelinePoint(forMedia media: Fraction) -> Fraction? {
            if ProjectionTiming.compare(media, mediaStart) == .equal { return timelineStart }
            if ProjectionTiming.compare(media, mediaEnd) == .equal { return timelineEnd }
            let mediaSpan = mediaEnd.doubleValue - mediaStart.doubleValue
            let timelineSpan = timelineEnd.doubleValue - timelineStart.doubleValue
            guard mediaSpan.isFinite,
                  timelineSpan.isFinite,
                  abs(mediaSpan) > .ulpOfOne
            else { return nil }
            let t = (media.doubleValue - mediaStart.doubleValue) / mediaSpan
            guard t.isFinite else { return nil }
            return ProjectionTiming.fraction(
                seconds: timelineStart.doubleValue + t * timelineSpan
            )
        }

        /// Maps a timeline-axis point through this segment onto the media axis.
        public func mediaPoint(forTimeline timeline: Fraction) -> Fraction {
            projectedMediaPoint(forTimeline: timeline) ?? mediaStart
        }

        private func projectedMediaPoint(forTimeline timeline: Fraction) -> Fraction? {
            if ProjectionTiming.compare(timeline, timelineStart) == .equal { return mediaStart }
            if ProjectionTiming.compare(timeline, timelineEnd) == .equal { return mediaEnd }
            let timelineSpan = timelineEnd.doubleValue - timelineStart.doubleValue
            let mediaSpan = mediaEnd.doubleValue - mediaStart.doubleValue
            guard timelineSpan.isFinite,
                  mediaSpan.isFinite,
                  abs(timelineSpan) > .ulpOfOne
            else { return nil }
            let t = (timeline.doubleValue - timelineStart.doubleValue) / timelineSpan
            guard t.isFinite else { return nil }
            return ProjectionTiming.fraction(
                seconds: mediaStart.doubleValue + t * mediaSpan
            )
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
