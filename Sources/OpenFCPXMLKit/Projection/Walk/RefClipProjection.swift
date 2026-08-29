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
            nodeAddress: ProjectNodeAddress,
            resources: (any OFKXMLElement)?,
            ancestors: [any OFKXMLElement],
            parentRetimings: [[RetimingSegment]],
            resourceReferencePath: Set<String>,
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
                nodeAddress: nodeAddress,
                includingHost: true,
                resources: resources,
                ancestors: ancestors,
                parentRetimings: parentRetimings,
                resourceReferencePath: resourceReferencePath,
                lanePath: lanePath,
                parentAbsoluteStart: absoluteStart,
                parentLocalStart: ProjectionTiming.localStartForChildren(of: element),
                primaryChannelFilter: clipFilter,
                connectedChannelFilter: channelFilter,
                options: options,
                onWindow: onWindow,
                depth: depth
            )

            guard !resourceReferencePath.contains(refClip.ref) else {
                SpineProjection.recordProjectionIssue(
                    code: .resourceCycle,
                    nodeAddress: nodeAddress,
                    ref: refClip.ref,
                    resourceID: refClip.ref,
                    message: "ref-clip resource cycle detected at \(refClip.ref)"
                )
                return
            }
            guard let resourceElement = element.fcpResource(forID: refClip.ref, in: resources) else {
                SpineProjection.recordProjectionIssue(
                    code: .missingResource,
                    nodeAddress: nodeAddress,
                    ref: refClip.ref,
                    resourceID: refClip.ref,
                    message: "ref-clip ref \(refClip.ref) did not resolve during projection"
                )
                return
            }
            guard let sequence = resourceElement.fcpAsMedia?.sequence else {
                SpineProjection.recordProjectionIssue(
                    code: .invalidContainerResource,
                    nodeAddress: nodeAddress,
                    ref: refClip.ref,
                    resourceID: refClip.ref,
                    message: "ref-clip resource \(refClip.ref) has no sequence"
                )
                return
            }
            let resourceAddress = nodeAddress.appending(resourceElement)
            let sequenceAddress = resourceAddress.appending(sequence.element)
            let spineAddress = sequenceAddress.appending(sequence.spine.element)
            let nestedReferencePath = resourceReferencePath.union([refClip.ref])

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
                parentNodeAddress: spineAddress,
                ancestors: ancestors,
                parentRetimings: childParents,
                resourceReferencePath: nestedReferencePath,
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
