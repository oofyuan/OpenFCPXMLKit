//
//  SpineProjection.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Recursive spine / anchored-story walk for timeline projection.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Walks story elements (primary spine, nested spines, anchored children,
    /// multicam angles, ref-clip sequences, auditions) emitting ``MediaUsageWindow``
    /// values for resolved media leaves.
    enum SpineProjection {
        static func projectStoryElements(
            _ elements: [any OFKXMLElement],
            resources: (any OFKXMLElement)?,
            ancestors: [any OFKXMLElement] = [],
            parentRetimings: [[RetimingSegment]] = [],
            lanePath: LanePath,
            parentAbsoluteStart: Fraction,
            parentLocalStart: Fraction?,
            channelFilter: ChannelKindFilter = .all,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void,
            depth: Int = 0,
            contentRetimings: [RetimingSegment] = []
        ) throws {
            // Guard against pathological nesting (cyclic media refs, etc.).
            guard depth < 64 else { return }

            for element in elements {
                if let type = element.fcpElementType, type.isLeafAnnotation {
                    continue
                }
                // Pool boundary per element: walking a subtree reads the XML tree heavily, and
                // the Foundation backend returns autoreleased objects that would otherwise
                // accumulate for the entire projection.
                try autoreleasepool {
                    try projectStoryElement(
                        element,
                        resources: resources,
                        ancestors: ancestors,
                        parentRetimings: retimings(
                            parentRetimings,
                            boundingContent: element,
                            with: contentRetimings
                        ),
                        lanePath: lanePath,
                        parentAbsoluteStart: parentAbsoluteStart,
                        parentLocalStart: parentLocalStart,
                        channelFilter: channelFilter,
                        options: options,
                        onWindow: onWindow,
                        depth: depth
                    )
                }
            }
        }

        /// Adds a container's mapping layer to the retiming chain for the content it encloses.
        ///
        /// A contained child may declare a longer span than the container that holds it —
        /// Final Cut Pro writes the whole source length on the `<audio>` inside a trimmed
        /// `<clip>` — and only the container's span is actually on the timeline. Anchored
        /// children (those carrying a `lane`) are connected clips rather than content, so they
        /// keep their own extent, which is how `_fcpEffectiveOcclusion` reads the same tree.
        private static func retimings(
            _ parentRetimings: [[RetimingSegment]],
            boundingContent element: any OFKXMLElement,
            with contentRetimings: [RetimingSegment]
        ) -> [[RetimingSegment]] {
            guard !contentRetimings.isEmpty, element.fcpLane == nil else { return parentRetimings }
            return parentRetimings + [contentRetimings]
        }

        /// Story children that remain eligible when a media host itself is excluded.
        ///
        /// Unlaned children are the disabled host's primary content and follow the host's
        /// visibility. Lane-bearing children are independently connected timeline items, so
        /// they continue through the normal projection walk and apply their own enabled,
        /// selection, occlusion, channel, timing, and retiming rules.
        private static func projectableChildren(
            of element: any OFKXMLElement,
            includingHost: Bool
        ) -> [any OFKXMLElement] {
            let children = element.fcpProjectableStoryElements
            guard !includingHost else { return children }
            return children.filter { ($0.fcpLane ?? 0) != 0 }
        }

        /// Projects a media host's local story children without leaking the host's
        /// `srcEnable` restriction into independently connected lane items.
        static func projectHostChildren(
            of element: any OFKXMLElement,
            includingHost: Bool,
            resources: (any OFKXMLElement)?,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            lanePath: LanePath,
            parentAbsoluteStart: Fraction,
            parentLocalStart: Fraction?,
            primaryChannelFilter: ChannelKindFilter,
            connectedChannelFilter: ChannelKindFilter,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void,
            depth: Int
        ) throws {
            for child in projectableChildren(of: element, includingHost: includingHost) {
                let filter = (child.fcpLane ?? 0) == 0
                    ? primaryChannelFilter
                    : connectedChannelFilter
                try projectStoryElements(
                    [child],
                    resources: resources,
                    ancestors: ancestors,
                    parentRetimings: parentRetimings,
                    lanePath: lanePath,
                    parentAbsoluteStart: parentAbsoluteStart,
                    parentLocalStart: parentLocalStart,
                    channelFilter: filter,
                    options: options,
                    onWindow: onWindow,
                    depth: depth
                )
            }
        }

        /// Timeline-to-content mappings a container imposes on the content nested inside it.
        private static func contentRetimings(
            for element: any OFKXMLElement,
            absoluteStart: Fraction
        ) -> [RetimingSegment] {
            guard let duration = element.fcpDuration else { return [] }

            guard let clip = element.fcpAsClip else {
                return [
                    RetimingSegment.identity(
                        timelineStart: absoluteStart,
                        duration: duration,
                        mediaStart: absoluteStart
                    )
                ]
            }

            let segments = ClipRetiming.segments(
                timeMap: clip.timeMap,
                clipOffset: absoluteStart,
                clipDuration: duration,
                mediaStart: absoluteStart
            )
            guard clip.timeMap != nil else { return segments }

            // Child offsets are made absolute relative to the clip's local `start`; move the
            // timeMap's source axis into that same coordinate space before composing leaves.
            return segments.map { segment in
                var segment = segment
                segment.mediaStart = ProjectionTiming.absoluteStart(
                    offset: segment.mediaStart,
                    parentAbsoluteStart: absoluteStart,
                    parentLocalStart: clip.start
                )
                segment.mediaEnd = ProjectionTiming.absoluteStart(
                    offset: segment.mediaEnd,
                    parentAbsoluteStart: absoluteStart,
                    parentLocalStart: clip.start
                )
                return segment
            }
        }

        private static func shouldEmitWindows(
            for element: any OFKXMLElement,
            ancestors: [any OFKXMLElement],
            options: TimelineProjectionOptions
        ) -> Bool {
            guard options.excludeFullyOccluded else { return true }
            return element._fcpEffectiveOcclusion(ancestors: ancestors) != .fullyOccluded
        }

        private static func projectStoryElement(
            _ element: any OFKXMLElement,
            resources: (any OFKXMLElement)?,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            lanePath: LanePath,
            parentAbsoluteStart: Fraction,
            parentLocalStart: Fraction?,
            channelFilter: ChannelKindFilter,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void,
            depth: Int
        ) throws {
            let nextDepth = depth + 1
            let childAncestors = [element] + ancestors
            let elementLanePath = lanePath.appending(element.fcpLane)
            let absoluteStart = ProjectionTiming.absoluteStart(
                offset: element.fcpOffset,
                parentAbsoluteStart: parentAbsoluteStart,
                parentLocalStart: parentLocalStart
            )
            let emitWindows = shouldEmitWindows(
                for: element,
                ancestors: ancestors,
                options: options
            )

            if let assetClip = element.fcpAsAssetClip {
                let includeHost = assetClip.enabled || options.includeDisabled
                if includeHost, emitWindows {
                    try emitAssetClipWindows(
                        assetClip: assetClip,
                        element: element,
                        ancestors: ancestors,
                        parentRetimings: parentRetimings,
                        resources: resources,
                        lanePath: elementLanePath,
                        absoluteStart: absoluteStart,
                        channelFilter: channelFilter,
                        options: options,
                        onWindow: onWindow
                    )
                }
                if includeHost {
                    emitHostAnnotationsIfNeeded(
                        element: element,
                        ancestors: ancestors,
                        resources: resources,
                        absoluteStart: absoluteStart,
                        options: options,
                        emitWindows: emitWindows
                    )
                }
                try projectHostChildren(
                    of: element,
                    includingHost: includeHost,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    lanePath: elementLanePath,
                    parentAbsoluteStart: absoluteStart,
                    parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                    primaryChannelFilter: ChannelKindFilter.intersecting(
                        channelFilter,
                        .from(srcEnable: assetClip.srcEnable)
                    ),
                    connectedChannelFilter: channelFilter,
                    options: options,
                    onWindow: onWindow,
                    depth: nextDepth
                )
                return
            }

            if let video = element.fcpAsVideo {
                let includeHost = video.enabled || options.includeDisabled
                if includeHost, emitWindows {
                    try emitVideoWindows(
                        video: video,
                        element: element,
                        ancestors: ancestors,
                        parentRetimings: parentRetimings,
                        resources: resources,
                        lanePath: elementLanePath,
                        absoluteStart: absoluteStart,
                        channelFilter: channelFilter,
                        options: options,
                        onWindow: onWindow
                    )
                }
                if includeHost {
                    emitHostAnnotationsIfNeeded(
                        element: element,
                        ancestors: ancestors,
                        resources: resources,
                        absoluteStart: absoluteStart,
                        options: options,
                        emitWindows: emitWindows
                    )
                }
                let childElements = projectableChildren(of: element, includingHost: includeHost)
                if !childElements.isEmpty {
                    try projectStoryElements(
                        childElements,
                        resources: resources,
                        ancestors: childAncestors,
                        parentRetimings: parentRetimings,
                        lanePath: elementLanePath,
                        parentAbsoluteStart: absoluteStart,
                        parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                        channelFilter: channelFilter,
                        options: options,
                        onWindow: onWindow,
                        depth: nextDepth
                    )
                }
                return
            }

            if let audio = element.fcpAsAudio {
                let includeHost = audio.enabled || options.includeDisabled
                if includeHost, emitWindows {
                    try emitAudioWindows(
                        audio: audio,
                        element: element,
                        ancestors: ancestors,
                        parentRetimings: parentRetimings,
                        resources: resources,
                        lanePath: elementLanePath,
                        absoluteStart: absoluteStart,
                        channelFilter: channelFilter,
                        options: options,
                        onWindow: onWindow
                    )
                }
                if includeHost {
                    emitHostAnnotationsIfNeeded(
                        element: element,
                        ancestors: ancestors,
                        resources: resources,
                        absoluteStart: absoluteStart,
                        options: options,
                        emitWindows: emitWindows
                    )
                }
                let childElements = projectableChildren(of: element, includingHost: includeHost)
                if !childElements.isEmpty {
                    try projectStoryElements(
                        childElements,
                        resources: resources,
                        ancestors: childAncestors,
                        parentRetimings: parentRetimings,
                        lanePath: elementLanePath,
                        parentAbsoluteStart: absoluteStart,
                        parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                        channelFilter: channelFilter,
                        options: options,
                        onWindow: onWindow,
                        depth: nextDepth
                    )
                }
                return
            }

            if let spine = element.fcpAsSpine {
                try projectStoryElements(
                    spine.element.fcpProjectableStoryElements,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    lanePath: elementLanePath,
                    parentAbsoluteStart: absoluteStart,
                    parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                    channelFilter: channelFilter,
                    options: options,
                    onWindow: onWindow,
                    depth: nextDepth
                )
                return
            }

            if let audition = element.fcpAsAudition {
                let clips: [any OFKXMLElement]
                switch options.auditions {
                case .active:
                    clips = [audition.activeClip].compactMap { $0 }
                case .all:
                    clips = Array(audition.clips)
                }
                try projectStoryElements(
                    clips,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    lanePath: elementLanePath,
                    parentAbsoluteStart: absoluteStart,
                    parentLocalStart: nil,
                    channelFilter: channelFilter,
                    options: options,
                    onWindow: onWindow,
                    depth: nextDepth
                )
                return
            }

            if let mcClip = element.fcpAsMCClip {
                let includeHost = mcClip.enabled || options.includeDisabled
                guard includeHost else {
                    try projectHostChildren(
                        of: element,
                        includingHost: false,
                        resources: resources,
                        ancestors: childAncestors,
                        parentRetimings: parentRetimings,
                        lanePath: elementLanePath,
                        parentAbsoluteStart: absoluteStart,
                        parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                        primaryChannelFilter: ChannelKindFilter.intersecting(
                            channelFilter,
                            .from(srcEnable: mcClip.srcEnable)
                        ),
                        connectedChannelFilter: channelFilter,
                        options: options,
                        onWindow: onWindow,
                        depth: nextDepth
                    )
                    return
                }
                // Host-level markers / keywords live on the mc-clip element itself; angle
                // unfold does not visit those annotation children. Emit even when the host
                // is occluded so connected / nested mc-clip markers reach the Markers sheet.
                emitHostAnnotationsIfNeeded(
                    element: element,
                    ancestors: ancestors,
                    resources: resources,
                    absoluteStart: absoluteStart,
                    options: options,
                    emitWindows: emitWindows
                )
                try MulticamProjection.project(
                    mcClip: mcClip,
                    element: element,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    lanePath: elementLanePath,
                    absoluteStart: absoluteStart,
                    channelFilter: channelFilter,
                    options: options,
                    onWindow: onWindow,
                    depth: nextDepth
                )
                return
            }

            if let refClip = element.fcpAsRefClip {
                let includeHost = refClip.enabled || options.includeDisabled
                guard includeHost else {
                    try projectHostChildren(
                        of: element,
                        includingHost: false,
                        resources: resources,
                        ancestors: childAncestors,
                        parentRetimings: parentRetimings,
                        lanePath: elementLanePath,
                        parentAbsoluteStart: absoluteStart,
                        parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                        primaryChannelFilter: ChannelKindFilter.intersecting(
                            channelFilter,
                            .from(srcEnable: refClip.srcEnable)
                        ),
                        connectedChannelFilter: channelFilter,
                        options: options,
                        onWindow: onWindow,
                        depth: nextDepth
                    )
                    return
                }
                // Host-level markers / keywords live on the ref-clip element itself;
                // compound unfold walks the media sequence, not these annotations.
                emitHostAnnotationsIfNeeded(
                    element: element,
                    ancestors: ancestors,
                    resources: resources,
                    absoluteStart: absoluteStart,
                    options: options,
                    emitWindows: emitWindows
                )
                try RefClipProjection.project(
                    refClip: refClip,
                    element: element,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    lanePath: elementLanePath,
                    absoluteStart: absoluteStart,
                    channelFilter: channelFilter,
                    options: options,
                    onWindow: onWindow,
                    depth: nextDepth
                )
                return
            }

            // Titles have no media channel but still need clip annotations (title text,
            // markers, keywords) even when they have no nested story children.
            if let title = element.fcpAsTitle {
                let includeHost = title.enabled || options.includeDisabled
                if includeHost {
                    emitHostAnnotationsIfNeeded(
                        element: element,
                        ancestors: ancestors,
                        resources: resources,
                        absoluteStart: absoluteStart,
                        options: options,
                        emitWindows: emitWindows
                    )
                }
                try projectStoryElements(
                    projectableChildren(of: title.element, includingHost: includeHost),
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    lanePath: elementLanePath,
                    parentAbsoluteStart: absoluteStart,
                    parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                    channelFilter: channelFilter,
                    options: options,
                    onWindow: onWindow,
                    depth: nextDepth
                )
                return
            }

            // Transitions have no media channel but still need transition (+ marker) annotations
            // even when they have no nested story children.
            if let transition = element.fcpAsTransition {
                emitHostAnnotationsIfNeeded(
                    element: element,
                    ancestors: ancestors,
                    resources: resources,
                    absoluteStart: absoluteStart,
                    options: options,
                    emitWindows: emitWindows
                )
                try projectStoryElements(
                    transition.element.fcpProjectableStoryElements,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    lanePath: elementLanePath,
                    parentAbsoluteStart: absoluteStart,
                    parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                    channelFilter: channelFilter,
                    options: options,
                    onWindow: onWindow,
                    depth: nextDepth
                )
                return
            }

            // Gaps, sync-clip / clip shells: no leaf media here,
            // but anchored / nested story children may still project.
            // Skip annotation-only story elements (markers, keywords, captions).
            if let type = element.fcpElementType, type.isAnnotation {
                return
            }

            let includeSubtree: Bool = {
                if let clip = element.fcpAsClip { return clip.enabled || options.includeDisabled }
                if let sync = element.fcpAsSyncClip { return sync.enabled || options.includeDisabled }
                if let gap = element.fcpAsGap { return gap.enabled || options.includeDisabled }
                return true
            }()
            let childElements = projectableChildren(of: element, includingHost: includeSubtree)
            guard !childElements.isEmpty else { return }

            // Sync-clip / clip shells may host markers and keywords without media leaves.
            if includeSubtree {
                emitHostAnnotationsIfNeeded(
                    element: element,
                    ancestors: ancestors,
                    resources: resources,
                    absoluteStart: absoluteStart,
                    options: options,
                    emitWindows: emitWindows
                )
            }

            try projectStoryElements(
                childElements,
                resources: resources,
                ancestors: childAncestors,
                parentRetimings: parentRetimings,
                lanePath: elementLanePath,
                parentAbsoluteStart: absoluteStart,
                parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                channelFilter: channelFilter,
                options: options,
                onWindow: onWindow,
                depth: nextDepth,
                contentRetimings: contentRetimings(for: element, absoluteStart: absoluteStart)
            )
        }

        private static func emitAssetClipWindows(
            assetClip: AssetClip,
            element: any OFKXMLElement,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            resources: (any OFKXMLElement)?,
            lanePath: LanePath,
            absoluteStart: Fraction,
            channelFilter: ChannelKindFilter,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void
        ) throws {
            guard let asset = element.fcpResource(forID: assetClip.ref, in: resources)?.fcpAsAsset
            else { return }

            let filter = ChannelKindFilter.intersecting(
                channelFilter,
                .from(srcEnable: assetClip.srcEnable)
            )
            let channels = AssetChannelExpansion.channels(
                from: asset,
                filter: filter,
                expandAllSourceChannels: options.expandAllSourceChannels
            )
            guard !channels.isEmpty else { return }

            let videoDuration = assetClip.duration ?? .zero
            let videoMediaStart = assetClip.start ?? asset.start ?? .zero
            let channelSegments = AudioSplitRetiming.segments(
                timeMap: assetClip.timeMap,
                absoluteStart: absoluteStart,
                videoDuration: videoDuration,
                videoMediaStart: videoMediaStart,
                clipStartAttribute: assetClip.start,
                audioStart: assetClip.audioStart,
                audioDuration: assetClip.audioDuration
            )
            let displayName = assetClip.name ?? asset.name

            for channel in channels {
                let retimings = channel.kind == .audio ? channelSegments.audio : channelSegments.video
                for retiming in retimings {
                    try emitComposedWindows(
                        channel: channel,
                        lanePath: lanePath,
                        retiming: retiming,
                        parentRetimings: parentRetimings,
                        displayName: displayName,
                        element: element,
                        ancestors: ancestors,
                        resources: resources,
                        options: options,
                        onWindow: onWindow
                    )
                }
            }
        }

        private static func emitVideoWindows(
            video: Video,
            element: any OFKXMLElement,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            resources: (any OFKXMLElement)?,
            lanePath: LanePath,
            absoluteStart: Fraction,
            channelFilter: ChannelKindFilter,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void
        ) throws {
            guard channelFilter.allows(.video) else { return }
            guard let asset = element.fcpResource(forID: video.ref, in: resources)?.fcpAsAsset
            else { return }

            let channels = AssetChannelExpansion.channels(
                from: asset,
                kind: .video,
                sourceIndex: AssetChannelExpansion.sourceIndex(fromSrcID: video.srcID)
            )
            guard !channels.isEmpty else { return }

            let mediaStart = video.start ?? asset.start ?? .zero
            let retimings = ClipRetiming.segments(
                timeMap: video.timeMap,
                clipOffset: absoluteStart,
                clipDuration: video.duration,
                mediaStart: mediaStart
            )
            let displayName = video.name ?? asset.name

            for channel in channels {
                for retiming in retimings {
                    try emitComposedWindows(
                        channel: channel,
                        lanePath: lanePath,
                        retiming: retiming,
                        parentRetimings: parentRetimings,
                        displayName: displayName,
                        element: element,
                        ancestors: ancestors,
                        resources: resources,
                        options: options,
                        onWindow: onWindow
                    )
                }
            }
        }

        private static func emitAudioWindows(
            audio: Audio,
            element: any OFKXMLElement,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            resources: (any OFKXMLElement)?,
            lanePath: LanePath,
            absoluteStart: Fraction,
            channelFilter: ChannelKindFilter,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void
        ) throws {
            guard channelFilter.allows(.audio) else { return }
            guard let asset = element.fcpResource(forID: audio.ref, in: resources)?.fcpAsAsset
            else { return }

            let channels = AssetChannelExpansion.channels(
                from: asset,
                kind: .audio,
                sourceIndex: AssetChannelExpansion.sourceIndex(fromSrcID: audio.srcID)
            )
            guard !channels.isEmpty else { return }

            let mediaStart = audio.start ?? asset.start ?? .zero
            let retimings = ClipRetiming.segments(
                timeMap: audio.timeMap,
                clipOffset: absoluteStart,
                clipDuration: audio.duration,
                mediaStart: mediaStart
            )
            let displayName = audio.name ?? asset.name

            for channel in channels {
                for retiming in retimings {
                    try emitComposedWindows(
                        channel: channel,
                        lanePath: lanePath,
                        retiming: retiming,
                        parentRetimings: parentRetimings,
                        displayName: displayName,
                        element: element,
                        ancestors: ancestors,
                        resources: resources,
                        options: options,
                        onWindow: onWindow
                    )
                }
            }
        }

        private static func emitComposedWindows(
            channel: MediaChannel,
            lanePath: LanePath,
            retiming: RetimingSegment,
            parentRetimings: [[RetimingSegment]],
            displayName: String?,
            element: any OFKXMLElement,
            ancestors: [any OFKXMLElement],
            resources: (any OFKXMLElement)?,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void
        ) throws {
            let composed = RetimingSegment.composing(parentLayers: parentRetimings, child: retiming)
            let annotations = WindowAnnotationBuilder.annotations(
                for: element,
                ancestors: ancestors,
                resources: resources,
                options: options,
                channelKind: channel.kind
            )
            for segment in composed where segment.hasUsableProjectionEndpoints {
                try onWindow(
                    MediaUsageWindow(
                        channel: channel,
                        lanePath: lanePath,
                        retiming: segment,
                        clipDisplayName: displayName,
                        roles: annotations.roles,
                        effects: annotations.effects,
                        breadcrumbs: annotations.breadcrumbs
                    )
                )
            }
        }

        /// Emits clip/title annotations once per host when a collector is installed.
        ///
        /// Visible hosts (`emitWindows == true`) get full annotations. Occluded hosts still
        /// emit markers/keywords so connected-clip Markers/Keywords reports stay complete;
        /// Titles / Transitions / Effects remain gated to visible occupancy.
        static func emitHostAnnotationsIfNeeded(
            element: any OFKXMLElement,
            ancestors: [any OFKXMLElement],
            resources: (any OFKXMLElement)?,
            absoluteStart: Fraction,
            options: TimelineProjectionOptions,
            emitWindows: Bool
        ) {
            emitClipAnnotationsIfNeeded(
                element: element,
                ancestors: ancestors,
                resources: resources,
                absoluteStart: absoluteStart,
                options: options,
                kind: emitWindows ? .all : .markersAndKeywordsOnly
            )
        }

        /// Emits clip/title annotations once per host when a collector is installed.
        static func emitClipAnnotationsIfNeeded(
            element: any OFKXMLElement,
            ancestors: [any OFKXMLElement],
            resources: (any OFKXMLElement)?,
            absoluteStart: Fraction,
            options: TimelineProjectionOptions,
            kind: WindowAnnotationBuilder.ClipAnnotationKind = .all
        ) {
            guard options.includeAnnotations,
                  let collector = TimelineProjectionLocals.clipAnnotationCollector,
                  let annotations = WindowAnnotationBuilder.clipAnnotations(
                      for: element,
                      ancestors: ancestors,
                      resources: resources,
                      absoluteStart: absoluteStart,
                      options: options,
                      kind: kind
                  )
            else { return }
            collector.append(annotations)
        }
    }
}
