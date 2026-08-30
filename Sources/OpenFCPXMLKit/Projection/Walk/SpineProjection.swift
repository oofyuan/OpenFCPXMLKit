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
            parentNodeAddress: ProjectNodeAddress,
            ancestors: [any OFKXMLElement] = [],
            parentRetimings: [[RetimingSegment]] = [],
            resourceReferencePath: Set<String> = [],
            lanePath: LanePath,
            parentAbsoluteStart: Fraction,
            parentLocalStart: Fraction?,
            channelFilter: ChannelKindFilter = .all,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void,
            depth: Int = 0,
            contentRetimings: [RetimingSegment] = [],
            resolvedNodeAddresses: [ProjectNodeAddress]? = nil
        ) throws {
            let addressedElements: [(element: any OFKXMLElement, address: ProjectNodeAddress)]
            if let resolvedNodeAddresses, resolvedNodeAddresses.count == elements.count {
                addressedElements = zip(elements, resolvedNodeAddresses).map {
                    (element: $0.0, address: $0.1)
                }
            } else {
                addressedElements = parentNodeAddress.addressing(elements)
            }
            for addressedElement in addressedElements {
                let element = addressedElement.element
                if let type = element.fcpElementType, type.isLeafAnnotation {
                    continue
                }
                // Pool boundary per element: walking a subtree reads the XML tree heavily, and
                // the Foundation backend returns autoreleased objects that would otherwise
                // accumulate for the entire projection.
                let nodeAddress = addressedElement.address
                guard depth < 64 else {
                    TimelineProjectionLocals.restorationDiagnosticCollector?.append(
                        ProjectRestorationIssue(
                            code: .depthLimit,
                            nodeAddress: nodeAddress,
                            ref: element.fcpRef,
                            resourceID: element.fcpRef,
                            message: "Project restoration traversal exceeded depth 64"
                        )
                    )
                    continue
                }
                do {
                    try autoreleasepool {
                        try projectStoryElement(
                            element,
                            nodeAddress: nodeAddress,
                            resources: resources,
                            ancestors: ancestors,
                            parentRetimings: retimings(
                                parentRetimings,
                                boundingContent: element,
                                with: contentRetimings
                            ),
                            resourceReferencePath: resourceReferencePath,
                            lanePath: lanePath,
                            parentAbsoluteStart: parentAbsoluteStart,
                            parentLocalStart: parentLocalStart,
                            channelFilter: channelFilter,
                            options: options,
                            onWindow: onWindow,
                            depth: depth
                        )
                    }
                } catch {
                    guard let collector = TimelineProjectionLocals.restorationDiagnosticCollector else {
                        throw error
                    }
                    collector.append(ProjectRestorationIssue(
                        code: .projectionFailure,
                        nodeAddress: nodeAddress,
                        ref: element.fcpRef,
                        resourceID: element.fcpRef,
                        message: "Projection failed at \(nodeAddress.description): \(error.localizedDescription)"
                    ))
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
            guard !contentRetimings.isEmpty, (element.fcpLane ?? 0) == 0 else {
                return parentRetimings
            }
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
            nodeAddress: ProjectNodeAddress,
            includingHost: Bool,
            resources: (any OFKXMLElement)?,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            resourceReferencePath: Set<String>,
            lanePath: LanePath,
            parentAbsoluteStart: Fraction,
            parentLocalStart: Fraction?,
            primaryChannelFilter: ChannelKindFilter,
            connectedChannelFilter: ChannelKindFilter,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void,
            depth: Int
        ) throws {
            let children = projectableChildren(of: element, includingHost: includingHost)
            for addressedChild in nodeAddress.addressing(children) {
                let child = addressedChild.element
                let filter = (child.fcpLane ?? 0) == 0
                    ? primaryChannelFilter
                    : connectedChannelFilter
                try projectStoryElements(
                    [child],
                    resources: resources,
                    parentNodeAddress: nodeAddress,
                    ancestors: ancestors,
                    parentRetimings: parentRetimings,
                    resourceReferencePath: resourceReferencePath,
                    lanePath: lanePath,
                    parentAbsoluteStart: parentAbsoluteStart,
                    parentLocalStart: parentLocalStart,
                    channelFilter: filter,
                    options: options,
                    onWindow: onWindow,
                    depth: depth,
                    resolvedNodeAddresses: [addressedChild.address]
                )
            }
        }

        /// Timeline-to-content mappings a container imposes on the content nested inside it.
        static func contentRetimings(
            for element: any OFKXMLElement,
            absoluteStart: Fraction,
            resources: (any OFKXMLElement)?
        ) throws -> [RetimingSegment] {
            guard let duration = element.fcpDuration else { return [] }

            let timeMap: TimeMap?
            let sourceLocalStart: Fraction?
            if let clip = element.fcpAsClip {
                timeMap = clip.timeMap
                sourceLocalStart = clip.start
            } else if let syncClip = element.fcpAsSyncClip {
                timeMap = syncClip.timeMap
                sourceLocalStart = syncClip.start
            } else {
                guard let identity = RetimingSegment.identity(
                    timelineStart: absoluteStart,
                    duration: duration,
                    mediaStart: absoluteStart
                ) else {
                    throw ProjectionTiming.ArithmeticError.unrepresentable
                }
                return [identity]
            }

            let conformMapping = try ProjectionConformMapping.resolving(
                for: element,
                resources: resources
            )
            return try containerContentRetimings(
                timeMap: timeMap,
                timelineOffset: absoluteStart,
                timelineDuration: duration,
                sourceLocalStart: sourceLocalStart,
                conformMapping: conformMapping
            )
        }

        /// Builds one explicit outer-timeline → contained-source mapping and moves its source
        /// axis into the same absolute coordinate space used by nested child placement.
        static func containerContentRetimings(
            timeMap: TimeMap?,
            timelineOffset: Fraction,
            timelineDuration: Fraction,
            sourceLocalStart: Fraction?,
            conformMapping: ProjectionConformMapping
        ) throws -> [RetimingSegment] {
            let localStart = sourceLocalStart ?? .zero
            let segments = try ClipRetiming.segments(
                timeMap: timeMap,
                timelineOffset: timelineOffset,
                timelineDuration: timelineDuration,
                sourceMediaStart: localStart,
                conformMapping: conformMapping
            )

            // Child offsets are made absolute relative to the host's raw local `start`; move the
            // explicit source axis into that same coordinate space before composing leaves.
            return try segments.map { segment in
                var segment = segment
                guard let mediaStart = ProjectionTiming.absoluteStart(
                    offset: segment.mediaStart,
                    parentAbsoluteStart: timelineOffset,
                    parentLocalStart: sourceLocalStart
                ),
                let mediaEnd = ProjectionTiming.absoluteStart(
                    offset: segment.mediaEnd,
                    parentAbsoluteStart: timelineOffset,
                    parentLocalStart: sourceLocalStart
                ) else {
                    throw ProjectionTiming.ArithmeticError.unrepresentable
                }
                segment.mediaStart = mediaStart
                segment.mediaEnd = mediaEnd
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
            nodeAddress: ProjectNodeAddress,
            resources: (any OFKXMLElement)?,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            resourceReferencePath: Set<String>,
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
            guard let absoluteStart = ProjectionTiming.absoluteStart(
                offset: element.fcpOffset,
                parentAbsoluteStart: parentAbsoluteStart,
                parentLocalStart: parentLocalStart
            ) else {
                throw ProjectionTiming.ArithmeticError.unrepresentable
            }
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
                        nodeAddress: nodeAddress,
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
                    nodeAddress: nodeAddress,
                    includingHost: includeHost,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    resourceReferencePath: resourceReferencePath,
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
                        nodeAddress: nodeAddress,
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
                        parentNodeAddress: nodeAddress,
                        ancestors: childAncestors,
                        parentRetimings: parentRetimings,
                        resourceReferencePath: resourceReferencePath,
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
                        nodeAddress: nodeAddress,
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
                        parentNodeAddress: nodeAddress,
                        ancestors: childAncestors,
                        parentRetimings: parentRetimings,
                        resourceReferencePath: resourceReferencePath,
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
                    parentNodeAddress: nodeAddress,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    resourceReferencePath: resourceReferencePath,
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
                    parentNodeAddress: nodeAddress,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    resourceReferencePath: resourceReferencePath,
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
                        nodeAddress: nodeAddress,
                        includingHost: false,
                        resources: resources,
                        ancestors: childAncestors,
                        parentRetimings: parentRetimings,
                        resourceReferencePath: resourceReferencePath,
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
                    nodeAddress: nodeAddress,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    resourceReferencePath: resourceReferencePath,
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
                        nodeAddress: nodeAddress,
                        includingHost: false,
                        resources: resources,
                        ancestors: childAncestors,
                        parentRetimings: parentRetimings,
                        resourceReferencePath: resourceReferencePath,
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
                    nodeAddress: nodeAddress,
                    resources: resources,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    resourceReferencePath: resourceReferencePath,
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
                    parentNodeAddress: nodeAddress,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    resourceReferencePath: resourceReferencePath,
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
                    parentNodeAddress: nodeAddress,
                    ancestors: childAncestors,
                    parentRetimings: parentRetimings,
                    resourceReferencePath: resourceReferencePath,
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
                parentNodeAddress: nodeAddress,
                ancestors: childAncestors,
                parentRetimings: parentRetimings,
                resourceReferencePath: resourceReferencePath,
                lanePath: elementLanePath,
                parentAbsoluteStart: absoluteStart,
                parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                channelFilter: channelFilter,
                options: options,
                onWindow: onWindow,
                depth: nextDepth,
                contentRetimings: try contentRetimings(
                    for: element,
                    absoluteStart: absoluteStart,
                    resources: resources
                )
            )
        }

        private static func emitAssetClipWindows(
            assetClip: AssetClip,
            element: any OFKXMLElement,
            nodeAddress: ProjectNodeAddress,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            resources: (any OFKXMLElement)?,
            lanePath: LanePath,
            absoluteStart: Fraction,
            channelFilter: ChannelKindFilter,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void
        ) throws {
            guard let resource = element.fcpResource(forID: assetClip.ref, in: resources) else {
                recordProjectionIssue(
                    code: .missingResource,
                    nodeAddress: nodeAddress,
                    ref: assetClip.ref,
                    resourceID: assetClip.ref,
                    message: "asset-clip ref \(assetClip.ref) did not resolve during projection"
                )
                return
            }
            guard let asset = resource.fcpAsAsset else {
                recordProjectionIssue(
                    code: .invalidContainerResource,
                    nodeAddress: nodeAddress,
                    ref: assetClip.ref,
                    resourceID: assetClip.ref,
                    message: "asset-clip ref \(assetClip.ref) did not resolve to an asset"
                )
                return
            }

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
            let conformMapping = try ProjectionConformMapping.resolving(
                for: element,
                resources: resources
            )
            let channelSegments = try AudioSplitRetiming.segments(
                timeMap: assetClip.timeMap,
                absoluteStart: absoluteStart,
                videoDuration: videoDuration,
                videoMediaStart: videoMediaStart,
                clipStartAttribute: assetClip.start,
                audioStart: assetClip.audioStart,
                audioDuration: assetClip.audioDuration,
                conformMapping: conformMapping
            )
            let displayName = assetClip.name ?? asset.name
            let sourceFacts = ProjectSourceChannelFacts.reading(
                element,
                expandsAllAssetChannels: options.expandAllSourceChannels
            )

            for channel in channels {
                var segmentOrdinal = 0
                let retimings = channel.kind == .audio ? channelSegments.audio : channelSegments.video
                for retiming in retimings {
                    try emitComposedWindows(
                        channel: channel,
                        nodeAddress: nodeAddress,
                        sourceChannelFacts: sourceFacts,
                        nextSegmentOrdinal: &segmentOrdinal,
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
            nodeAddress: ProjectNodeAddress,
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
            guard let resource = element.fcpResource(forID: video.ref, in: resources) else {
                recordProjectionIssue(
                    code: .missingResource,
                    nodeAddress: nodeAddress,
                    ref: video.ref,
                    resourceID: video.ref,
                    message: "video ref \(video.ref) did not resolve during projection"
                )
                return
            }
            // A <video> may reference an effect/generator. It is valid
            // non-file content, so it contributes no MediaUsageWindow and is
            // not a projection failure.
            if resource.fcpAsEffect != nil { return }
            guard let asset = resource.fcpAsAsset else {
                recordProjectionIssue(
                    code: .invalidContainerResource,
                    nodeAddress: nodeAddress,
                    ref: video.ref,
                    resourceID: video.ref,
                    message: "video ref \(video.ref) did not resolve to an asset"
                )
                return
            }

            guard let sourceIndex = AssetChannelExpansion.sourceIndex(fromSrcID: video.srcID) else {
                recordProjectionIssue(
                    code: .invalidSourceID,
                    nodeAddress: nodeAddress,
                    ref: video.ref,
                    resourceID: video.ref,
                    message: "video srcID must be a positive integer; only an absent srcID defaults to 1"
                )
                return
            }
            let channels = AssetChannelExpansion.channels(
                from: asset,
                kind: .video,
                sourceIndex: sourceIndex
            )
            guard !channels.isEmpty else {
                recordProjectionIssue(
                    code: .sourceIndexOutOfRange,
                    nodeAddress: nodeAddress,
                    ref: video.ref,
                    resourceID: video.ref,
                    message: "video srcID \(sourceIndex) is outside asset \(video.ref) channels"
                )
                return
            }

            let mediaStart = video.start ?? asset.start ?? .zero
            let conformMapping = try ProjectionConformMapping.resolving(
                for: element,
                resources: resources
            )
            let retimings = try ClipRetiming.segments(
                timeMap: video.timeMap,
                timelineOffset: absoluteStart,
                timelineDuration: video.duration,
                sourceMediaStart: mediaStart,
                conformMapping: conformMapping
            )
            let displayName = video.name ?? asset.name
            let sourceFacts = ProjectSourceChannelFacts.reading(element)

            for channel in channels {
                var segmentOrdinal = 0
                for retiming in retimings {
                    try emitComposedWindows(
                        channel: channel,
                        nodeAddress: nodeAddress,
                        sourceChannelFacts: sourceFacts,
                        nextSegmentOrdinal: &segmentOrdinal,
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
            nodeAddress: ProjectNodeAddress,
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
            guard let resource = element.fcpResource(forID: audio.ref, in: resources) else {
                recordProjectionIssue(
                    code: .missingResource,
                    nodeAddress: nodeAddress,
                    ref: audio.ref,
                    resourceID: audio.ref,
                    message: "audio ref \(audio.ref) did not resolve during projection"
                )
                return
            }
            guard let asset = resource.fcpAsAsset else {
                recordProjectionIssue(
                    code: .invalidContainerResource,
                    nodeAddress: nodeAddress,
                    ref: audio.ref,
                    resourceID: audio.ref,
                    message: "audio ref \(audio.ref) did not resolve to an asset"
                )
                return
            }

            guard let sourceIndex = AssetChannelExpansion.sourceIndex(fromSrcID: audio.srcID) else {
                recordProjectionIssue(
                    code: .invalidSourceID,
                    nodeAddress: nodeAddress,
                    ref: audio.ref,
                    resourceID: audio.ref,
                    message: "audio srcID must be a positive integer; only an absent srcID defaults to 1"
                )
                return
            }
            let channels = AssetChannelExpansion.channels(
                from: asset,
                kind: .audio,
                sourceIndex: sourceIndex
            )
            guard !channels.isEmpty else {
                recordProjectionIssue(
                    code: .sourceIndexOutOfRange,
                    nodeAddress: nodeAddress,
                    ref: audio.ref,
                    resourceID: audio.ref,
                    message: "audio srcID \(sourceIndex) is outside asset \(audio.ref) channels"
                )
                return
            }

            let mediaStart = audio.start ?? asset.start ?? .zero
            let conformMapping = try ProjectionConformMapping.resolving(
                for: element,
                resources: resources
            )
            let retimings = try ClipRetiming.segments(
                timeMap: audio.timeMap,
                timelineOffset: absoluteStart,
                timelineDuration: audio.duration,
                sourceMediaStart: mediaStart,
                conformMapping: conformMapping
            )
            let displayName = audio.name ?? asset.name
            let sourceFacts = ProjectSourceChannelFacts.reading(element)

            for channel in channels {
                var segmentOrdinal = 0
                for retiming in retimings {
                    try emitComposedWindows(
                        channel: channel,
                        nodeAddress: nodeAddress,
                        sourceChannelFacts: sourceFacts,
                        nextSegmentOrdinal: &segmentOrdinal,
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
            nodeAddress: ProjectNodeAddress,
            sourceChannelFacts: ProjectSourceChannelFacts,
            nextSegmentOrdinal: inout Int,
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
            let usable = composed.filter(\.hasUsableProjectionEndpoints)
            if usable.count != composed.count || usable.isEmpty {
                TimelineProjectionLocals.restorationDiagnosticCollector?.append(
                    ProjectRestorationIssue(
                        code: .projectionFailure,
                        nodeAddress: nodeAddress,
                        ref: channel.resourceID,
                        resourceID: channel.resourceID,
                        message: "Media retiming composition did not produce every exact usable endpoint"
                    )
                )
            }
            let annotations = WindowAnnotationBuilder.annotations(
                for: element,
                ancestors: ancestors,
                resources: resources,
                options: options,
                channelKind: channel.kind
            )
            for segment in usable {
                let segmentOrdinal = nextSegmentOrdinal
                nextSegmentOrdinal += 1
                try onWindow(
                    MediaUsageWindow(
                        channel: channel,
                        lanePath: lanePath,
                        retiming: segment,
                        clipDisplayName: displayName,
                        roles: annotations.roles,
                        effects: annotations.effects,
                        breadcrumbs: annotations.breadcrumbs,
                        projectNodeAddress: nodeAddress,
                        retimingSegmentOrdinal: segmentOrdinal,
                        sourceChannelFacts: sourceChannelFacts
                    )
                )
            }
        }

        static func recordProjectionIssue(
            code: ProjectRestorationIssueCode,
            nodeAddress: ProjectNodeAddress,
            ref: String?,
            resourceID: String?,
            message: String
        ) {
            TimelineProjectionLocals.restorationDiagnosticCollector?.append(
                ProjectRestorationIssue(
                    code: code,
                    nodeAddress: nodeAddress,
                    ref: ref,
                    resourceID: resourceID,
                    message: message
                )
            )
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
