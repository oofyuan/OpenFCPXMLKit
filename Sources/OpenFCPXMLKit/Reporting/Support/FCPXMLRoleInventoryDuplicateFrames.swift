//
//  FCPXMLRoleInventoryDuplicateFrames.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Source-range reuse duration for inventory Duplicate Frames cells.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Computes Duplicate Frames from inventory **Source In / Source Out** ranges.
    ///
    /// Intersects each clip’s consumed source interval (`Source In` + **Source Duration**)
    /// with other inventoried usages of the same ``MediaChannel/resourceID``. Never uses
    /// ``MediaUsageWindow/mediaIn`` / ``mediaOut``: a `timeMap` routinely spans the whole
    /// source while the clip uses one slice (Sign `retimed-source-duration-follows-speed`).
    /// Same-clip video/audio rows are one host and never count as each other’s duplicates.
    /// Blank when there is no reusable source overlap.
    /// Sign `duplicate-frames-match-source-in-out`.
    enum RoleInventoryDuplicateFrames {
        /// Precomputed source usages for one inventory build.
        struct UsageIndex: Sendable {
            fileprivate var usages: [SourceUsage]
            
            init() {
                usages = []
            }
            
            fileprivate init(usages: [SourceUsage]) {
                self.usages = usages
            }
        }
        
        fileprivate struct SourceUsage: Sendable {
            /// XML node identity of the inventory host clip (not clip name + timeline In).
            var hostID: ObjectIdentifier
            var usesAudioTimelineBounds: Bool
            var resourceID: String
            var start: Double
            var end: Double
        }
        
        /// Builds source usages for every inventory entry (once per report).
        static func makeIndex(
            entries: [RoleInventoryClipEntry],
            projectionWindows: [MediaUsageWindow]?,
            windowIndex: ProjectionWindowIndex?
        ) -> UsageIndex {
            let index = windowIndex ?? projectionWindows.map { ProjectionWindowIndex(windows: $0) }
            var usages: [SourceUsage] = []
            usages.reserveCapacity(entries.count)
            
            for entry in entries {
                if let usage = sourceUsage(
                    for: entry,
                    projectionWindows: projectionWindows,
                    windowIndex: index
                ) {
                    usages.append(usage)
                }
            }
            
            return UsageIndex(usages: usages)
        }
        
        /// Formatted reused source duration for an inventory clip, or `""` when none.
        static func formattedDuration(
            for extracted: ExtractedElement,
            usesAudioTimelineBounds: Bool,
            usageIndex: UsageIndex,
            timecodeFormat: ReportTimecodeFormat
        ) -> String {
            let hostID = hostIdentity(for: inventoryClipContext(for: extracted))
            let subjects = usageIndex.usages.filter {
                $0.hostID == hostID && $0.usesAudioTimelineBounds == usesAudioTimelineBounds
            }
            guard !subjects.isEmpty else { return "" }
            
            var overlapIntervals: [TimelineOccupancyIndex.Interval] = []
            for subject in subjects {
                guard subject.end > subject.start + .ulpOfOne else { continue }
                for other in usageIndex.usages {
                    guard other.hostID != hostID else { continue }
                    guard other.resourceID == subject.resourceID else { continue }
                    let start = max(subject.start, other.start)
                    let end = min(subject.end, other.end)
                    guard end > start + .ulpOfOne else { continue }
                    overlapIntervals.append(
                        TimelineOccupancyIndex.Interval(start: start, end: end)
                    )
                }
            }
            
            let seconds = TimelineOccupancyIndex.unionDuration(overlapIntervals)
            guard seconds > .ulpOfOne else { return "" }
            
            guard let durationTimecode = try? extracted.element._fcpTimecode(
                fromRealTime: seconds,
                frameRateSource: .mainTimeline,
                breadcrumbs: extracted.breadcrumbs,
                resources: extracted.resources
            ) else { return "" }
            
            return ReportFormatting.timecodeString(durationTimecode, format: timecodeFormat)
        }
        
        private static func sourceUsage(
            for entry: RoleInventoryClipEntry,
            projectionWindows: [MediaUsageWindow]?,
            windowIndex: ProjectionWindowIndex?
        ) -> SourceUsage? {
            let extracted = entry.extracted
            guard let span = RoleInventoryTimelineBounds.mainTimelineSpan(
                for: extracted,
                usesAudioTimelineBounds: entry.usesAudioTimelineBounds,
                projectionWindows: projectionWindows,
                windowIndex: windowIndex
            ) else { return nil }
            
            let timelineSeconds = max(0, span.end - span.start)
            guard timelineSeconds > .ulpOfOne else { return nil }
            
            let clipContext = inventoryClipContext(for: extracted)
            let sourceStart = sourceStartSeconds(for: clipContext)
            guard let sourceStart else { return nil }
            
            let sourceDuration = RoleInventorySourceSpan.retimedMediaSeconds(
                for: extracted,
                clipContext: clipContext,
                timelineSeconds: timelineSeconds,
                usesAudioTimelineBounds: entry.usesAudioTimelineBounds,
                projectionWindows: projectionWindows,
                windowIndex: windowIndex
            ) ?? timelineSeconds
            
            let sourceEnd = sourceStart + sourceDuration
            guard sourceEnd > sourceStart + .ulpOfOne else { return nil }
            
            guard let resourceID = resourceID(
                for: extracted,
                usesAudioTimelineBounds: entry.usesAudioTimelineBounds,
                windowIndex: windowIndex
            ) else { return nil }
            
            return SourceUsage(
                hostID: hostIdentity(for: clipContext),
                usesAudioTimelineBounds: entry.usesAudioTimelineBounds,
                resourceID: resourceID,
                start: sourceStart,
                end: sourceEnd
            )
        }
        
        /// Same origin as Role Inventory **Source In** (`start` as local timecode).
        private static func sourceStartSeconds(for clipContext: ExtractedElement) -> Double? {
            if let timecode = clipContext.element._fcpTimelineStartAsTimecode()
                ?? clipContext.element._fcpStartAsTimecode(
                    frameRateSource: .localToElement,
                    default: nil
                )
            {
                return timecode.realTimeValue
            }
            return clipContext.element.fcpStart?.doubleValue
        }
        
        private static func resourceID(
            for extracted: ExtractedElement,
            usesAudioTimelineBounds: Bool,
            windowIndex: ProjectionWindowIndex?
        ) -> String? {
            if let windowIndex {
                let windows = matchingWindows(
                    for: extracted,
                    usesAudioTimelineBounds: usesAudioTimelineBounds,
                    index: windowIndex
                )
                let preferred = windows.filter { $0.channel.kind == .video }
                let pool = preferred.isEmpty ? windows : preferred
                if let id = pool.map(\.channel.resourceID).first(where: { !$0.isEmpty }) {
                    return id
                }
            }
            return extracted.element.fcpRef
        }
        
        private static func inventoryClipContext(
            for extracted: ExtractedElement
        ) -> ExtractedElement {
            if let elementType = extracted.element.fcpElementType,
               reportClipHostTypes.contains(elementType)
            {
                return extracted
            }
            return extracted.ancestorClipContext() ?? extracted
        }
        
        private static func hostIdentity(for clipContext: ExtractedElement) -> ObjectIdentifier {
            if let backing = clipContext.element.backingObject {
                return ObjectIdentifier(backing)
            }
            return ObjectIdentifier(clipContext.element)
        }
        
        private static func expectedTimelineStart(
            for extracted: ExtractedElement,
            usesAudioTimelineBounds: Bool
        ) -> Double {
            let absoluteStart = extracted.value(forContext: .absoluteStart) ?? 0
            if usesAudioTimelineBounds,
               extracted.element.fcpAudioDuration != nil
            {
                let clipStart = extracted.element.fcpStart?.doubleValue ?? 0
                let audioStart = extracted.element.fcpAudioStart?.doubleValue ?? clipStart
                return absoluteStart + (audioStart - clipStart)
            }
            return absoluteStart
        }
        
        private static func matchingWindows(
            for extracted: ExtractedElement,
            usesAudioTimelineBounds: Bool,
            index: ProjectionWindowIndex
        ) -> [MediaUsageWindow] {
            index.windows(
                clipName: extracted.displayClipName(),
                expectedStart: expectedTimelineStart(
                    for: extracted,
                    usesAudioTimelineBounds: usesAudioTimelineBounds
                )
            )
        }
    }
}
