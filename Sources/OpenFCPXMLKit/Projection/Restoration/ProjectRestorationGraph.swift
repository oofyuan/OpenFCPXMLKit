//
//  ProjectRestorationGraph.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

import Foundation
import SwiftTimecode

extension FinalCutPro.FCPXML {
    /// Deterministic address of one reachable structural node, rooted at the selected Project.
    public struct ProjectNodeAddress: Hashable, Sendable, CustomStringConvertible {
        public struct Component: Hashable, Sendable {
            public let elementName: String
            public let childOrdinal: Int

            public init(elementName: String, childOrdinal: Int) {
                self.elementName = elementName
                self.childOrdinal = childOrdinal
            }
        }

        public let components: [Component]

        public init(components: [Component]) {
            self.components = components
        }

        public var description: String {
            components
                .map { "\($0.elementName)[\($0.childOrdinal)]" }
                .joined(separator: "/")
        }

        public var parent: ProjectNodeAddress? {
            guard components.count > 1 else { return nil }
            return ProjectNodeAddress(components: Array(components.dropLast()))
        }

        public func appending(elementName: String, childOrdinal: Int) -> ProjectNodeAddress {
            ProjectNodeAddress(
                components: components + [
                    Component(elementName: elementName, childOrdinal: childOrdinal),
                ]
            )
        }

        public func isAncestor(of candidate: ProjectNodeAddress) -> Bool {
            candidate.components.count > components.count
                && Array(candidate.components.prefix(components.count)) == components
        }
    }

    /// Stable identity of one projected media usage within a selected Project.
    public struct ProjectUsageID: Hashable, Sendable, CustomStringConvertible {
        public let nodeAddress: ProjectNodeAddress
        public let mediaKind: MediaChannel.Kind
        public let sourceIndex: Int
        public let retimingSegmentOrdinal: Int

        public init(
            nodeAddress: ProjectNodeAddress,
            mediaKind: MediaChannel.Kind,
            sourceIndex: Int,
            retimingSegmentOrdinal: Int
        ) {
            self.nodeAddress = nodeAddress
            self.mediaKind = mediaKind
            self.sourceIndex = sourceIndex
            self.retimingSegmentOrdinal = retimingSegmentOrdinal
        }

        public var description: String {
            "\(nodeAddress.description)#\(mediaKind.rawValue)[\(sourceIndex)]@\(retimingSegmentOrdinal)"
        }
    }

    /// Raw source/channel declarations preserved at a usage site.
    public struct ProjectSourceChannelFacts: Hashable, Sendable, Equatable {
        public struct AudioChannelSourceFact: Hashable, Sendable, Equatable {
            public let sourceChannels: String
            public let outputChannels: String?
            public let isEnabled: Bool
            public let isActive: Bool

            public init(
                sourceChannels: String,
                outputChannels: String?,
                isEnabled: Bool,
                isActive: Bool
            ) {
                self.sourceChannels = sourceChannels
                self.outputChannels = outputChannels
                self.isEnabled = isEnabled
                self.isActive = isActive
            }
        }

        public let declaredSourceID: String?
        public let sourceChannels: String?
        public let outputChannels: String?
        public let audioChannelSources: [AudioChannelSourceFact]
        public let expandsAllAssetChannels: Bool

        public init(
            declaredSourceID: String?,
            sourceChannels: String?,
            outputChannels: String?,
            audioChannelSources: [AudioChannelSourceFact] = [],
            expandsAllAssetChannels: Bool = false
        ) {
            self.declaredSourceID = declaredSourceID
            self.sourceChannels = sourceChannels
            self.outputChannels = outputChannels
            self.audioChannelSources = audioChannelSources
            self.expandsAllAssetChannels = expandsAllAssetChannels
        }
    }

    public enum ProjectRestorationEdgeDisposition: String, Hashable, Sendable, CaseIterable {
        case resolvedMedia
        case resolvedContainer
        case provenNonFile
        case unsupported
        case missingReference
        case ambiguousReference
        case cycle
        case depthLimit
        case projectionFailure

        public var blocksCompleteness: Bool {
            switch self {
            case .resolvedMedia, .resolvedContainer, .provenNonFile:
                false
            case .unsupported, .missingReference, .ambiguousReference, .cycle,
                 .depthLimit, .projectionFailure:
                true
            }
        }
    }

    public enum ProjectRestorationIssueCode: String, Hashable, Sendable, CaseIterable {
        case unsupportedReachableElement
        case missingReference
        case missingResource
        case ambiguousResource
        case invalidContainerResource
        case resourceCycle
        case depthLimit
        case projectionFailure
        case invalidSourceID
        case sourceIndexOutOfRange
        case activeUsageMissingFromRestoration
        case conflictingUsageProjection
        case transitionHandlesUnproven
    }

    public struct ProjectRestorationNode: Hashable, Sendable, Equatable {
        public let address: ProjectNodeAddress
        public let parentAddress: ProjectNodeAddress?
        public let elementName: String
        public let structuralKind: String?
        public let ref: String?
        public let lane: Int?
        public let isEnabled: Bool
        public let auditionCandidateIndex: Int?
        public let isActiveAuditionCandidate: Bool?
        public let multicamAngleID: String?
        public let isActiveMulticamAngle: Bool?
        public let containerAncestry: [String]
        public let isActivePlaybackMember: Bool
        public let isRestorationMember: Bool
        public let sourceChannelFacts: ProjectSourceChannelFacts

        public init(
            address: ProjectNodeAddress,
            parentAddress: ProjectNodeAddress?,
            elementName: String,
            structuralKind: String?,
            ref: String?,
            lane: Int?,
            isEnabled: Bool,
            auditionCandidateIndex: Int? = nil,
            isActiveAuditionCandidate: Bool? = nil,
            multicamAngleID: String? = nil,
            isActiveMulticamAngle: Bool? = nil,
            containerAncestry: [String] = [],
            isActivePlaybackMember: Bool,
            isRestorationMember: Bool,
            sourceChannelFacts: ProjectSourceChannelFacts
        ) {
            self.address = address
            self.parentAddress = parentAddress
            self.elementName = elementName
            self.structuralKind = structuralKind
            self.ref = ref
            self.lane = lane
            self.isEnabled = isEnabled
            self.auditionCandidateIndex = auditionCandidateIndex
            self.isActiveAuditionCandidate = isActiveAuditionCandidate
            self.multicamAngleID = multicamAngleID
            self.isActiveMulticamAngle = isActiveMulticamAngle
            self.containerAncestry = containerAncestry
            self.isActivePlaybackMember = isActivePlaybackMember
            self.isRestorationMember = isRestorationMember
            self.sourceChannelFacts = sourceChannelFacts
        }
    }

    public struct ProjectRestorationEdge: Hashable, Sendable, Equatable {
        public let sourceAddress: ProjectNodeAddress
        public let destinationAddress: ProjectNodeAddress?
        public let ref: String?
        public let disposition: ProjectRestorationEdgeDisposition

        public init(
            sourceAddress: ProjectNodeAddress,
            destinationAddress: ProjectNodeAddress?,
            ref: String?,
            disposition: ProjectRestorationEdgeDisposition
        ) {
            self.sourceAddress = sourceAddress
            self.destinationAddress = destinationAddress
            self.ref = ref
            self.disposition = disposition
        }
    }

    public struct ProjectRestorationUsage: Hashable, Sendable, Equatable, Identifiable {
        public let id: ProjectUsageID
        public let nodeAddress: ProjectNodeAddress
        public let resourceID: String
        public let mediaKind: MediaChannel.Kind
        public let sourceIndex: Int
        public let sourceChannelFacts: ProjectSourceChannelFacts
        public let retiming: RetimingSegment
        public let isActive: Bool
        public let isRestoration: Bool
        public let lanePath: LanePath
        public let retimingSegmentOrdinal: Int
        public let nativeStart: Fraction?
        public let nativeDuration: Fraction?

        public init(
            id: ProjectUsageID,
            nodeAddress: ProjectNodeAddress,
            resourceID: String,
            mediaKind: MediaChannel.Kind,
            sourceIndex: Int,
            sourceChannelFacts: ProjectSourceChannelFacts,
            retiming: RetimingSegment,
            isActive: Bool,
            isRestoration: Bool,
            lanePath: LanePath,
            retimingSegmentOrdinal: Int,
            nativeStart: Fraction?,
            nativeDuration: Fraction?
        ) {
            self.id = id
            self.nodeAddress = nodeAddress
            self.resourceID = resourceID
            self.mediaKind = mediaKind
            self.sourceIndex = sourceIndex
            self.sourceChannelFacts = sourceChannelFacts
            self.retiming = retiming
            self.isActive = isActive
            self.isRestoration = isRestoration
            self.lanePath = lanePath
            self.retimingSegmentOrdinal = retimingSegmentOrdinal
            self.nativeStart = nativeStart
            self.nativeDuration = nativeDuration
        }
    }

    public struct ProjectRestorationIssue: Hashable, Sendable, Equatable {
        public let code: ProjectRestorationIssueCode
        public let nodeAddress: ProjectNodeAddress
        public let ref: String?
        public let resourceID: String?
        public let message: String
        public let isBlocking: Bool

        public init(
            code: ProjectRestorationIssueCode,
            nodeAddress: ProjectNodeAddress,
            ref: String? = nil,
            resourceID: String? = nil,
            message: String,
            isBlocking: Bool = true
        ) {
            self.code = code
            self.nodeAddress = nodeAddress
            self.ref = ref
            self.resourceID = resourceID
            self.message = message
            self.isBlocking = isBlocking
        }
    }

    /// In-memory dependency closure for one selected Project.
    public struct ProjectRestorationGraph: Sendable, Equatable {
        public let projectStableID: String?
        public let rootAddress: ProjectNodeAddress
        public let nodes: [ProjectRestorationNode]
        public let edges: [ProjectRestorationEdge]
        public let usages: [ProjectRestorationUsage]
        public let issues: [ProjectRestorationIssue]
        public let requiresCopyFullResourceIDs: Set<String>
        public let isComplete: Bool

        public init(
            projectStableID: String?,
            rootAddress: ProjectNodeAddress,
            nodes: [ProjectRestorationNode],
            edges: [ProjectRestorationEdge],
            usages: [ProjectRestorationUsage],
            issues: [ProjectRestorationIssue],
            requiresCopyFullResourceIDs: Set<String>,
            isComplete: Bool
        ) {
            self.projectStableID = projectStableID
            self.rootAddress = rootAddress
            self.nodes = nodes
            self.edges = edges
            self.usages = usages
            self.issues = issues
            self.requiresCopyFullResourceIDs = requiresCopyFullResourceIDs
            self.isComplete = isComplete
        }

        public var activeUsages: [ProjectRestorationUsage] {
            usages.filter(\.isActive)
        }

        public var restorationUsages: [ProjectRestorationUsage] {
            usages.filter(\.isRestoration)
        }

        public var resolvedMediaResourceIDs: Set<String> {
            Set(edges.compactMap { edge in
                edge.disposition == .resolvedMedia ? edge.ref : nil
            })
        }

        public var provenNonFileNodeAddresses: Set<ProjectNodeAddress> {
            Set(edges.compactMap { edge in
                edge.disposition == .provenNonFile ? edge.sourceAddress : nil
            })
        }

        public var blockingIssues: [ProjectRestorationIssue] {
            issues.filter(\.isBlocking)
        }
    }
}

extension FinalCutPro.FCPXML.ProjectNodeAddress {
    static func root(for source: FinalCutPro.FCPXML.ReportTimelineSource) -> Self {
        if let project = source.project {
            return Self(components: [
                Component(elementName: project.element.name ?? "project", childOrdinal: 0),
            ])
        }
        return Self(components: [
            Component(elementName: source.sequence.element.name ?? "sequence", childOrdinal: 0),
        ])
    }

    func appending(
        _ element: any OFKXMLElement,
        fallbackOccurrence: Int = 0
    ) -> Self {
        appending(
            elementName: element.name ?? "unknown",
            childOrdinal: Self.childOrdinal(
                of: element,
                fallbackOccurrence: fallbackOccurrence
            )
        )
    }

    /// Addresses an ordered subset of one parent's children without collapsing
    /// byte-identical sibling elements when a backend has no object identity.
    func addressing(
        _ elements: [any OFKXMLElement]
    ) -> [(element: any OFKXMLElement, address: Self)] {
        var occurrencesByXML: [String: Int] = [:]
        return elements.map { element in
            let fingerprint = element.xmlCompactString
            let occurrence = occurrencesByXML[fingerprint, default: 0]
            occurrencesByXML[fingerprint] = occurrence + 1
            return (
                element,
                appending(element, fallbackOccurrence: occurrence)
            )
        }
    }

    private static func childOrdinal(
        of element: any OFKXMLElement,
        fallbackOccurrence: Int
    ) -> Int {
        guard let siblings = element.parentElement?.childElements else { return 0 }
        if let target = element.backingObject,
           let ordinal = siblings.firstIndex(where: { $0.backingObject === target })
        {
            return ordinal
        }

        // Resource and selected-angle wrappers remain identifiable by a unique declared ID
        // even when a backend cannot expose object identity.
        for attribute in ["id", "uid", "angleID"] {
            guard let value = element.stringValue(forAttributeNamed: attribute) else { continue }
            let matches = siblings.enumerated().filter {
                $0.element.stringValue(forAttributeNamed: attribute) == value
            }
            if matches.count == 1, let ordinal = matches.first?.offset {
                return ordinal
            }
        }

        // Traversal supplies the occurrence within its ordered child subset. Matching that
        // occurrence against the parent's complete child list preserves distinct addresses for
        // byte-identical siblings instead of collapsing every wrapper onto the first element.
        let matchingOrdinals = siblings.enumerated().compactMap { index, sibling in
            sibling.xmlCompactString == element.xmlCompactString ? index : nil
        }
        guard matchingOrdinals.indices.contains(fallbackOccurrence) else {
            return matchingOrdinals.first ?? 0
        }
        return matchingOrdinals[fallbackOccurrence]
    }
}

extension FinalCutPro.FCPXML.ProjectSourceChannelFacts {
    static func reading(
        _ element: any OFKXMLElement,
        expandsAllAssetChannels: Bool = false
    ) -> Self {
        let channelSources = element.childElements.compactMap { child -> AudioChannelSourceFact? in
            guard let source = child.fcpAsAudioChannelSource else { return nil }
            return AudioChannelSourceFact(
                sourceChannels: source.sourceChannels,
                outputChannels: source.outputChannels,
                isEnabled: source.enabled,
                isActive: source.active
            )
        }
        return Self(
            declaredSourceID: element.stringValue(forAttributeNamed: "srcID"),
            sourceChannels: element.fcpSourceChannels,
            outputChannels: element.fcpOutputChannels,
            audioChannelSources: channelSources,
            expandsAllAssetChannels: expandsAllAssetChannels
        )
    }
}
