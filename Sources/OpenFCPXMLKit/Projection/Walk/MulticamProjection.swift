//
//  MulticamProjection.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Unfolds mc-clip into active (or all) multicam angle storylines.
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Projects an `mc-clip` by walking local anchors and unfolding
    /// ``Media/Multicam`` angles selected by ``TimelineProjectionOptions/mcClipAngles``.
    enum MulticamProjection {
        static func project(
            mcClip: MCClip,
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
                .from(srcEnable: mcClip.srcEnable)
            )

            // Local anchors / nested story children on the mc-clip itself.
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

            guard !resourceReferencePath.contains(mcClip.ref) else {
                SpineProjection.recordProjectionIssue(
                    code: .resourceCycle,
                    nodeAddress: nodeAddress,
                    ref: mcClip.ref,
                    resourceID: mcClip.ref,
                    message: "mc-clip resource cycle detected at \(mcClip.ref)"
                )
                return
            }
            guard let resourceElement = element.fcpResource(forID: mcClip.ref, in: resources) else {
                SpineProjection.recordProjectionIssue(
                    code: .missingResource,
                    nodeAddress: nodeAddress,
                    ref: mcClip.ref,
                    resourceID: mcClip.ref,
                    message: "mc-clip ref \(mcClip.ref) did not resolve during projection"
                )
                return
            }
            guard let multicam = resourceElement.fcpAsMedia?.multicam else {
                SpineProjection.recordProjectionIssue(
                    code: .invalidContainerResource,
                    nodeAddress: nodeAddress,
                    ref: mcClip.ref,
                    resourceID: mcClip.ref,
                    message: "mc-clip resource \(mcClip.ref) has no multicam"
                )
                return
            }
            let resourceAddress = nodeAddress.appending(resourceElement)
            let multicamAddress = resourceAddress.appending(multicam.element)
            let nestedReferencePath = resourceReferencePath.union([mcClip.ref])

            let parentLocalStart = mcClip.start
            var angleParents = parentRetimings
            let conformMapping = try ProjectionConformMapping.resolving(
                for: element,
                resources: resources
            )
            if mcClip.timeMap != nil || !conformMapping.isIdentity {
                let containerSegments = try SpineProjection.containerContentRetimings(
                    timeMap: mcClip.timeMap,
                    timelineOffset: absoluteStart,
                    timelineDuration: mcClip.duration,
                    sourceLocalStart: parentLocalStart,
                    conformMapping: conformMapping
                )
                angleParents.append(containerSegments)
            }
            switch options.mcClipAngles {
            case .active:
                let (audioAngle, videoAngle) = mcClip.audioVideoMCAngles
                let declaredSources = Array(mcClip.sources)
                let requiresVideoAngle = declaredSources.contains {
                    $0.sourceEnable == .all || $0.sourceEnable == .video
                }
                let requiresAudioAngle = declaredSources.contains {
                    $0.sourceEnable == .all || $0.sourceEnable == .audio
                }
                if requiresVideoAngle, clipFilter.allows(.video), videoAngle == nil {
                    SpineProjection.recordProjectionIssue(
                        code: .invalidContainerResource,
                        nodeAddress: nodeAddress,
                        ref: mcClip.ref,
                        resourceID: mcClip.ref,
                        message: "mc-clip has no uniquely resolved active video angle"
                    )
                }
                if requiresAudioAngle, clipFilter.allows(.audio), audioAngle == nil {
                    SpineProjection.recordProjectionIssue(
                        code: .invalidContainerResource,
                        nodeAddress: nodeAddress,
                        ref: mcClip.ref,
                        resourceID: mcClip.ref,
                        message: "mc-clip has no uniquely resolved active audio angle"
                    )
                }
                if let videoAngle,
                   let audioAngle,
                   videoAngle.angleID == audioAngle.angleID
                {
                    try projectAngle(
                        videoAngle,
                        parentNodeAddress: multicamAddress,
                        resources: resources,
                        ancestors: ancestors,
                        parentRetimings: angleParents,
                        resourceReferencePath: nestedReferencePath,
                        lanePath: lanePath,
                        parentAbsoluteStart: absoluteStart,
                        parentLocalStart: parentLocalStart,
                        channelFilter: clipFilter,
                        options: options,
                        onWindow: onWindow,
                        depth: depth
                    )
                } else {
                    if let videoAngle {
                        try projectAngle(
                            videoAngle,
                            parentNodeAddress: multicamAddress,
                            resources: resources,
                            ancestors: ancestors,
                            parentRetimings: angleParents,
                            resourceReferencePath: nestedReferencePath,
                            lanePath: lanePath,
                            parentAbsoluteStart: absoluteStart,
                            parentLocalStart: parentLocalStart,
                            channelFilter: ChannelKindFilter.intersecting(clipFilter, .videoOnly),
                            options: options,
                            onWindow: onWindow,
                            depth: depth
                        )
                    }
                    if let audioAngle {
                        try projectAngle(
                            audioAngle,
                            parentNodeAddress: multicamAddress,
                            resources: resources,
                            ancestors: ancestors,
                            parentRetimings: angleParents,
                            resourceReferencePath: nestedReferencePath,
                            lanePath: lanePath,
                            parentAbsoluteStart: absoluteStart,
                            parentLocalStart: parentLocalStart,
                            channelFilter: ChannelKindFilter.intersecting(clipFilter, .audioOnly),
                            options: options,
                            onWindow: onWindow,
                            depth: depth
                        )
                    }
                }

            case .all:
                for angle in multicam.angles {
                    try projectAngle(
                        angle,
                        parentNodeAddress: multicamAddress,
                        resources: resources,
                        ancestors: ancestors,
                        parentRetimings: angleParents,
                        resourceReferencePath: nestedReferencePath,
                        lanePath: lanePath,
                        parentAbsoluteStart: absoluteStart,
                        parentLocalStart: parentLocalStart,
                        channelFilter: clipFilter,
                        options: options,
                        onWindow: onWindow,
                        depth: depth
                    )
                }
            }
        }

        private static func projectAngle(
            _ angle: Media.Multicam.Angle,
            parentNodeAddress: ProjectNodeAddress,
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
            let angleAddress = parentNodeAddress.appending(angle.element)
            try SpineProjection.projectStoryElements(
                angle.element.fcpProjectableStoryElements,
                resources: resources,
                parentNodeAddress: angleAddress,
                ancestors: ancestors,
                parentRetimings: parentRetimings,
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
    }
}
