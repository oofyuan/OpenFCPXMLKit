//
// RefClipProjection.swift
// OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
// © 2026 • Licensed under MIT License
//


//
//	Unfolds ref-clip (compound clip) into its media sequence spine.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Projects a `ref-clip` by walking local anchors and unfolding
    /// ``RefClip/mediaSequence``.
    enum RefClipProjection {
        static func project(
            refClip: RefClip,
            element: any OFKXMLElement,
            resources: (any OFKXMLElement)?,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            lanePath: LanePath,
            absoluteStart: Fraction,
            channelFilter: ChannelKindFilter,
            options: TimelineProjectionOptions,
            onWindow: (MediaUsageWindow) throws -> Void,
            depth: Int = 0
        ) throws {
            let clipFilter = ChannelKindFilter.intersecting(
                channelFilter,
                .from(srcEnable: refClip.srcEnable)
            )

            // Local anchors on the ref-clip itself.
            try SpineProjection.projectHostChildren(
                of: element,
                includingHost: true,
                resources: resources,
                ancestors: ancestors,
                parentRetimings: parentRetimings,
                lanePath: lanePath,
                parentAbsoluteStart: absoluteStart,
                parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                primaryChannelFilter: clipFilter,
                connectedChannelFilter: channelFilter,
                options: options,
                onWindow: onWindow,
                depth: depth
            )

            guard let sequence = refClip.mediaSequence else { return }

            // Nested sequence spine: child offsets are relative to the compound
            // clip's local `start` (and sequence `tcStart` when composing further).
            let nestedLocalStart = refClip.start ?? sequence.tcStart
            let duration = refClip.duration

            // A ref-clip resource sequence is stored outside the usage element's XML subtree.
            // Carry the usage-local conform/timeMap mapping explicitly across that boundary.
            var childParents = parentRetimings
            let conformMapping = try ProjectionConformMapping.resolving(
                for: element,
                resources: resources
            )
            if refClip.timeMap != nil || !conformMapping.isIdentity {
                let containerSegments = try SpineProjection.containerContentRetimings(
                    timeMap: refClip.timeMap,
                    timelineOffset: absoluteStart,
                    timelineDuration: duration,
                    sourceLocalStart: nestedLocalStart,
                    conformMapping: conformMapping
                )
                childParents.append(containerSegments)
            }

            try SpineProjection.projectStoryElements(
                sequence.spine.element.fcpProjectableStoryElements,
                resources: resources,
                ancestors: ancestors,
                parentRetimings: childParents,
                lanePath: lanePath,
                parentAbsoluteStart: absoluteStart,
                parentLocalStart: nestedLocalStart,
                channelFilter: clipFilter,
                options: options,
                onWindow: onWindow,
                depth: depth
            )
        }
    }
}
