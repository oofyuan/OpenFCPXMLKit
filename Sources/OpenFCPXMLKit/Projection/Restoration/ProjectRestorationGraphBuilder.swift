//
//  ProjectRestorationGraphBuilder.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

import Foundation

extension FinalCutPro.FCPXML {
    /// Builds the in-memory structural and media-usage closure for one selected Project.
    ///
    /// Structural discovery records XML containment and resource-reference facts. Exact
    /// media timing remains owned by ``TimelineProjector``; active and restoration views
    /// are merged by ``ProjectUsageID`` rather than projection array position.
    public struct ProjectRestorationGraphBuilder: Sendable {
        public init() {}

        public func buildSync(
            from source: ReportTimelineSource,
            fcpxml: FinalCutPro.FCPXML
        ) throws -> ProjectRestorationGraph {
            let rootAddress = ProjectNodeAddress.root(for: source)
            let accumulator = ProjectRestorationAccumulator(
                projectStableID: source.project?.uid ?? source.project?.id,
                rootAddress: rootAddress,
                resources: fcpxml.root.resources
            )
            accumulator.walk(source: source)

            let restoration = try projectedWindows(
                from: source,
                fcpxml: fcpxml,
                options: .projectRestoration,
                accumulator: accumulator
            )
            let active = try projectedWindows(
                from: source,
                fcpxml: fcpxml,
                options: .activeMediaUsage,
                accumulator: accumulator
            )
            accumulator.merge(restorationWindows: restoration, activeWindows: active)
            return accumulator.finish()
        }

        private func projectedWindows(
            from source: ReportTimelineSource,
            fcpxml: FinalCutPro.FCPXML,
            options: TimelineProjectionOptions,
            accumulator: ProjectRestorationAccumulator
        ) throws -> [MediaUsageWindow] {
            let collector = ProjectRestorationDiagnosticCollector()
            var windows: [MediaUsageWindow] = []
            do {
                try TimelineProjectionLocals.$restorationDiagnosticCollector.withValue(collector) {
                    try TimelineProjector().projectSync(
                        from: source,
                        fcpxml: fcpxml,
                        options: options
                    ) { windows.append($0) }
                }
            } catch {
                accumulator.append(issues: collector.issues)
                accumulator.appendProjectionFailure(
                    view: options == .projectRestoration ? "restoration" : "active",
                    error: error
                )
                return []
            }
            accumulator.append(issues: collector.issues)
            return windows
        }
    }

    /// Convenience entry point for the selected report timeline source.
    public func projectRestorationGraph(
        from source: ReportTimelineSource
    ) throws -> ProjectRestorationGraph {
        try ProjectRestorationGraphBuilder().buildSync(from: source, fcpxml: self)
    }
}

extension FinalCutPro.FCPXML {
    private final class ProjectRestorationAccumulator {
        let projectStableID: String?
        let rootAddress: ProjectNodeAddress
        let resources: any OFKXMLElement

        private var nodesByAddress: [ProjectNodeAddress: ProjectRestorationNode] = [:]
        private var edges: [ProjectRestorationEdge] = []
        private var issues: [ProjectRestorationIssue] = []
        private var usagesByID: [ProjectUsageID: ProjectRestorationUsage] = [:]
        private var copyFullResourceIDs: Set<String> = []
        private var mediaLeafAddresses: [ProjectNodeAddress: String] = [:]
        private var transitionNeighborAddresses: Set<ProjectNodeAddress> = []

        init(
            projectStableID: String?,
            rootAddress: ProjectNodeAddress,
            resources: any OFKXMLElement
        ) {
            self.projectStableID = projectStableID
            self.rootAddress = rootAddress
            self.resources = resources
        }

        func append(issues newIssues: [ProjectRestorationIssue]) {
            for issue in newIssues {
                append(issue: issue)
            }
        }

        func appendProjectionFailure(view: String, error: Error) {
            append(issue: .init(
                code: .projectionFailure,
                nodeAddress: rootAddress,
                message: "Project \(view) projection failed: \(error.localizedDescription)"
            ))
        }

        func walk(source: ReportTimelineSource) {
            let rootElement = source.project?.element ?? source.sequence.element
            addNode(
                element: rootElement,
                address: rootAddress,
                parentAddress: nil,
                active: true,
                restoration: true
            )

            let sequenceAddress: ProjectNodeAddress
            if source.project != nil {
                sequenceAddress = rootAddress.appending(source.sequence.element)
                addContainer(
                    element: source.sequence.element,
                    address: sequenceAddress,
                    parentAddress: rootAddress,
                    active: true
                )
            } else {
                sequenceAddress = rootAddress
            }

            let spineAddress = sequenceAddress.appending(source.sequence.spine.element)
            addContainer(
                element: source.sequence.spine.element,
                address: spineAddress,
                parentAddress: sequenceAddress,
                active: true
            )
            walkElements(
                structuralChildren(of: source.sequence.spine.element),
                parentAddress: spineAddress,
                inheritedActive: true,
                containerAncestry: ["sequence", "spine"],
                resourcePath: [],
                depth: 0
            )
        }

        private func walkElements(
            _ elements: [any OFKXMLElement],
            parentAddress: ProjectNodeAddress,
            inheritedActive: Bool,
            containerAncestry: [String],
            resourcePath: Set<String>,
            depth: Int
        ) {
            let addressedElements = parentAddress.addressing(elements)
            for (index, addressedElement) in addressedElements.enumerated() {
                let element = addressedElement.element
                let address = addressedElement.address
                if element.fcpAsTransition != nil {
                    if index > 0 {
                        transitionNeighborAddresses.insert(addressedElements[index - 1].address)
                    }
                    if index + 1 < addressedElements.count {
                        transitionNeighborAddresses.insert(addressedElements[index + 1].address)
                    }
                }
                walkElement(
                    element,
                    address: address,
                    parentAddress: parentAddress,
                    inheritedActive: inheritedActive,
                    containerAncestry: containerAncestry,
                    resourcePath: resourcePath,
                    depth: depth
                )
            }
        }

        private func walkElement(
            _ element: any OFKXMLElement,
            address: ProjectNodeAddress,
            parentAddress: ProjectNodeAddress,
            inheritedActive: Bool,
            containerAncestry: [String],
            resourcePath: Set<String>,
            depth: Int,
            auditionCandidateIndex: Int? = nil,
            activeAuditionCandidate: Bool? = nil,
            multicamAngleID: String? = nil,
            activeMulticamAngle: Bool? = nil
        ) {
            guard depth < 64 else {
                addNode(
                    element: element,
                    address: address,
                    parentAddress: parentAddress,
                    active: false,
                    restoration: true,
                    containerAncestry: containerAncestry
                )
                addEdge(source: address, destination: nil, ref: element.fcpRef, disposition: .depthLimit)
                append(issue: .init(
                    code: .depthLimit,
                    nodeAddress: address,
                    ref: element.fcpRef,
                    resourceID: element.fcpRef,
                    message: "Project restoration traversal exceeded depth 64"
                ))
                return
            }

            let isEnabled = element.fcpGetEnabled(default: true)
            let active = inheritedActive && isEnabled
                && (activeAuditionCandidate ?? true)
                && (activeMulticamAngle ?? true)
            addNode(
                element: element,
                address: address,
                parentAddress: parentAddress,
                active: active,
                restoration: true,
                auditionCandidateIndex: auditionCandidateIndex,
                activeAuditionCandidate: activeAuditionCandidate,
                multicamAngleID: multicamAngleID,
                activeMulticamAngle: activeMulticamAngle,
                containerAncestry: containerAncestry
            )
            addEdge(source: parentAddress, destination: address, ref: nil, disposition: .resolvedContainer)
            recordEffectReferences(
                in: element,
                parentAddress: address,
                active: active,
                containerAncestry: containerAncestry
            )

            if element.fcpElementType == nil {
                addEdge(source: address, destination: nil, ref: element.fcpRef, disposition: .unsupported)
                append(issue: .init(
                    code: .unsupportedReachableElement,
                    nodeAddress: address,
                    ref: element.fcpRef,
                    resourceID: element.fcpRef,
                    message: "Unsupported reachable story element <\(element.name ?? "unknown")>"
                ))
                walkElements(
                    structuralChildren(of: element),
                    parentAddress: address,
                    inheritedActive: active,
                    containerAncestry: containerAncestry + [element.name ?? "unknown"],
                    resourcePath: resourcePath,
                    depth: depth + 1
                )
                return
            }

            if let assetClip = element.fcpAsAssetClip {
                resolveAsset(
                    ref: rawRequiredRef(element),
                    at: address,
                    sourceKind: nil,
                    expandsAllChannels: true
                )
                walkHostChildren(
                    element,
                    address: address,
                    inheritedActive: inheritedActive,
                    hostActive: active,
                    ancestry: containerAncestry + ["asset-clip"],
                    resourcePath: resourcePath,
                    depth: depth
                )
                _ = assetClip
                return
            }

            if element.fcpAsVideo != nil {
                resolveAsset(
                    ref: rawRequiredRef(element),
                    at: address,
                    sourceKind: .video,
                    expandsAllChannels: false
                )
                walkHostChildren(
                    element,
                    address: address,
                    inheritedActive: inheritedActive,
                    hostActive: active,
                    ancestry: containerAncestry + ["video"],
                    resourcePath: resourcePath,
                    depth: depth
                )
                return
            }

            if element.fcpAsAudio != nil {
                resolveAsset(
                    ref: rawRequiredRef(element),
                    at: address,
                    sourceKind: .audio,
                    expandsAllChannels: false
                )
                walkHostChildren(
                    element,
                    address: address,
                    inheritedActive: inheritedActive,
                    hostActive: active,
                    ancestry: containerAncestry + ["audio"],
                    resourcePath: resourcePath,
                    depth: depth
                )
                return
            }

            if let audition = element.fcpAsAudition {
                let candidates = Array(audition.clips)
                for (index, addressedCandidate) in address.addressing(candidates).enumerated() {
                    let candidate = addressedCandidate.element
                    walkElement(
                        candidate,
                        address: addressedCandidate.address,
                        parentAddress: address,
                        inheritedActive: active,
                        containerAncestry: containerAncestry + ["audition"],
                        resourcePath: resourcePath,
                        depth: depth + 1,
                        auditionCandidateIndex: index,
                        activeAuditionCandidate: index == 0
                    )
                }
                if audition.clips.isEmpty {
                    addEdge(source: address, destination: nil, ref: nil, disposition: .provenNonFile)
                }
                return
            }

            if let refClip = element.fcpAsRefClip {
                resolveRefClip(
                    refClip,
                    element: element,
                    address: address,
                    active: active,
                    ancestry: containerAncestry,
                    resourcePath: resourcePath,
                    depth: depth
                )
                walkHostChildren(
                    element,
                    address: address,
                    inheritedActive: inheritedActive,
                    hostActive: active,
                    ancestry: containerAncestry + ["ref-clip"],
                    resourcePath: resourcePath,
                    depth: depth
                )
                return
            }

            if let mcClip = element.fcpAsMCClip {
                resolveMulticam(
                    mcClip,
                    element: element,
                    address: address,
                    active: active,
                    ancestry: containerAncestry,
                    resourcePath: resourcePath,
                    depth: depth
                )
                walkHostChildren(
                    element,
                    address: address,
                    inheritedActive: inheritedActive,
                    hostActive: active,
                    ancestry: containerAncestry + ["mc-clip"],
                    resourcePath: resourcePath,
                    depth: depth
                )
                return
            }

            if element.fcpAsTransition != nil {
                // A transition has no `ref`; its filter-video/filter-audio children own any
                // effect-resource references and were recorded above.
                addEdge(source: address, destination: nil, ref: nil, disposition: .provenNonFile)
                append(issue: .init(
                    code: .transitionHandlesUnproven,
                    nodeAddress: address,
                    ref: element.fcpRef,
                    message: "Transition is retained, but adjacent media handles are not proven",
                    isBlocking: false
                ))
                return
            }

            if element.fcpAsTitle != nil {
                resolveNonFileReference(of: element, at: address, referenceIsRequired: true)
                walkHostChildren(
                    element,
                    address: address,
                    inheritedActive: inheritedActive,
                    hostActive: active,
                    ancestry: containerAncestry + ["title"],
                    resourcePath: resourcePath,
                    depth: depth
                )
                return
            }

            if element.fcpAsGap != nil || element.fcpAsCaption != nil || element.fcpAsLiveDrawing != nil {
                addEdge(source: address, destination: nil, ref: nil, disposition: .provenNonFile)
                walkHostChildren(
                    element,
                    address: address,
                    inheritedActive: inheritedActive,
                    hostActive: active,
                    ancestry: containerAncestry + [element.name ?? "non-file"],
                    resourcePath: resourcePath,
                    depth: depth
                )
                return
            }

            if element.fcpAsClip != nil || element.fcpAsSyncClip != nil || element.fcpAsSpine != nil {
                let children = structuralChildren(of: element)
                if children.isEmpty {
                    addEdge(source: address, destination: nil, ref: nil, disposition: .provenNonFile)
                } else {
                    walkHostChildren(
                        element,
                        address: address,
                        inheritedActive: inheritedActive,
                        hostActive: active,
                        ancestry: containerAncestry + [element.name ?? "container"],
                        resourcePath: resourcePath,
                        depth: depth
                    )
                }
                return
            }

            addEdge(source: address, destination: nil, ref: element.fcpRef, disposition: .unsupported)
            append(issue: .init(
                code: .unsupportedReachableElement,
                nodeAddress: address,
                ref: element.fcpRef,
                resourceID: element.fcpRef,
                message: "Reachable story element <\(element.name ?? "unknown")> has no restoration disposition"
            ))
        }

        private func walkHostChildren(
            _ element: any OFKXMLElement,
            address: ProjectNodeAddress,
            inheritedActive: Bool,
            hostActive: Bool,
            ancestry: [String],
            resourcePath: Set<String>,
            depth: Int
        ) {
            let children = structuralChildren(of: element)
            for addressedChild in address.addressing(children) {
                let child = addressedChild.element
                let connected = (child.fcpLane ?? 0) != 0
                walkElement(
                    child,
                    address: addressedChild.address,
                    parentAddress: address,
                    inheritedActive: connected ? inheritedActive : hostActive,
                    containerAncestry: ancestry,
                    resourcePath: resourcePath,
                    depth: depth + 1
                )
            }
        }

        private func resolveAsset(
            ref: String?,
            at address: ProjectNodeAddress,
            sourceKind: MediaChannel.Kind?,
            expandsAllChannels: Bool
        ) {
            guard let ref, !ref.isEmpty else {
                missingReference(at: address, ref: nil)
                return
            }
            guard let resource = uniqueResource(ref: ref, at: address) else { return }
            let resourceAddress = address.appending(resource)
            addNode(
                element: resource,
                address: resourceAddress,
                parentAddress: address,
                active: true,
                restoration: true,
                containerAncestry: ["asset-resource"]
            )
            guard let asset = resource.fcpAsAsset else {
                addEdge(source: address, destination: resourceAddress, ref: ref, disposition: .unsupported)
                append(issue: .init(
                    code: .invalidContainerResource,
                    nodeAddress: address,
                    ref: ref,
                    resourceID: ref,
                    message: "Media leaf ref \(ref) does not resolve to an asset resource"
                ))
                return
            }

            addEdge(source: address, destination: resourceAddress, ref: ref, disposition: .resolvedMedia)
            mediaLeafAddresses[address] = ref
            if let sourceKind {
                validateSourceID(
                    at: address,
                    resourceID: ref,
                    asset: asset,
                    kind: sourceKind
                )
            } else if !expandsAllChannels {
                append(issue: .init(
                    code: .projectionFailure,
                    nodeAddress: address,
                    ref: ref,
                    resourceID: ref,
                    message: "Asset channel expansion policy was not explicit"
                ))
            }
        }

        private func resolveRefClip(
            _ refClip: RefClip,
            element: any OFKXMLElement,
            address: ProjectNodeAddress,
            active: Bool,
            ancestry: [String],
            resourcePath: Set<String>,
            depth: Int
        ) {
            let ref = rawRequiredRef(element)
            guard let ref, !ref.isEmpty else {
                missingReference(at: address, ref: nil)
                return
            }
            guard !resourcePath.contains(ref) else {
                cycle(at: address, ref: ref)
                return
            }
            guard let resource = uniqueResource(ref: ref, at: address) else { return }
            let resourceAddress = address.appending(resource)
            addNode(
                element: resource,
                address: resourceAddress,
                parentAddress: address,
                active: active,
                restoration: true,
                containerAncestry: ancestry + ["ref-clip-resource"]
            )
            guard let sequence = resource.fcpAsMedia?.sequence else {
                addEdge(source: address, destination: resourceAddress, ref: ref, disposition: .unsupported)
                append(issue: .init(
                    code: .invalidContainerResource,
                    nodeAddress: address,
                    ref: ref,
                    resourceID: ref,
                    message: "ref-clip resource \(ref) has no sequence"
                ))
                return
            }
            addEdge(source: address, destination: resourceAddress, ref: ref, disposition: .resolvedContainer)
            let sequenceAddress = resourceAddress.appending(sequence.element)
            addContainer(
                element: sequence.element,
                address: sequenceAddress,
                parentAddress: resourceAddress,
                active: active,
                ancestry: ancestry + ["ref-clip"]
            )
            let spineAddress = sequenceAddress.appending(sequence.spine.element)
            addContainer(
                element: sequence.spine.element,
                address: spineAddress,
                parentAddress: sequenceAddress,
                active: active,
                ancestry: ancestry + ["ref-clip", "sequence"]
            )
            walkElements(
                structuralChildren(of: sequence.spine.element),
                parentAddress: spineAddress,
                inheritedActive: active,
                containerAncestry: ancestry + ["ref-clip", "sequence", "spine"],
                resourcePath: resourcePath.union([ref]),
                depth: depth + 1
            )
            _ = refClip
        }

        private func resolveMulticam(
            _ mcClip: MCClip,
            element: any OFKXMLElement,
            address: ProjectNodeAddress,
            active: Bool,
            ancestry: [String],
            resourcePath: Set<String>,
            depth: Int
        ) {
            let ref = rawRequiredRef(element)
            guard let ref, !ref.isEmpty else {
                missingReference(at: address, ref: nil)
                return
            }
            guard !resourcePath.contains(ref) else {
                cycle(at: address, ref: ref)
                return
            }
            guard let resource = uniqueResource(ref: ref, at: address) else { return }
            let resourceAddress = address.appending(resource)
            addNode(
                element: resource,
                address: resourceAddress,
                parentAddress: address,
                active: active,
                restoration: true,
                containerAncestry: ancestry + ["multicam-resource"]
            )
            guard let multicam = resource.fcpAsMedia?.multicam else {
                addEdge(source: address, destination: resourceAddress, ref: ref, disposition: .unsupported)
                append(issue: .init(
                    code: .invalidContainerResource,
                    nodeAddress: address,
                    ref: ref,
                    resourceID: ref,
                    message: "mc-clip resource \(ref) has no multicam"
                ))
                return
            }
            addEdge(source: address, destination: resourceAddress, ref: ref, disposition: .resolvedContainer)
            let multicamAddress = resourceAddress.appending(multicam.element)
            addContainer(
                element: multicam.element,
                address: multicamAddress,
                parentAddress: resourceAddress,
                active: active,
                ancestry: ancestry + ["mc-clip"]
            )
            let sources = Array(mcClip.sources)
            let selected = multicam.audioVideoMCAngles(forMulticamSources: sources)
            let activeAngleIDs = Set([
                selected.audioMCAngle?.angleID,
                selected.videoMCAngle?.angleID,
            ].compactMap { $0 })
            let nestedPath = resourcePath.union([ref])
            let angles = Array(multicam.angles)
            validateMulticamSources(
                sources,
                angles: angles,
                at: address,
                resourceID: ref
            )
            for addressedAngle in multicamAddress.addressing(angles.map(\.element)) {
                guard let angle = addressedAngle.element.fcpAsMCAngle else { continue }
                let angleAddress = addressedAngle.address
                let isSelected = activeAngleIDs.contains(angle.angleID)
                addNode(
                    element: angle.element,
                    address: angleAddress,
                    parentAddress: multicamAddress,
                    active: active && isSelected,
                    restoration: true,
                    multicamAngleID: angle.angleID,
                    activeMulticamAngle: isSelected,
                    containerAncestry: ancestry + ["mc-clip", "multicam"]
                )
                addEdge(
                    source: multicamAddress,
                    destination: angleAddress,
                    ref: nil,
                    disposition: .resolvedContainer
                )
                walkElements(
                    structuralChildren(of: angle.element),
                    parentAddress: angleAddress,
                    inheritedActive: active && isSelected,
                    containerAncestry: ancestry + ["mc-clip", "multicam", "mc-angle"],
                    resourcePath: nestedPath,
                    depth: depth + 1
                )
            }
        }

        private func validateMulticamSources(
            _ sources: [MulticamSource],
            angles: [Media.Multicam.Angle],
            at address: ProjectNodeAddress,
            resourceID: String
        ) {
            for source in sources {
                guard let angleID = source.angleID, !angleID.isEmpty else {
                    addEdge(
                        source: address,
                        destination: nil,
                        ref: nil,
                        disposition: .missingReference
                    )
                    append(issue: .init(
                        code: .missingReference,
                        nodeAddress: address,
                        ref: resourceID,
                        message: "mc-source has no angleID in multicam resource \(resourceID)"
                    ))
                    continue
                }
                let matches = angles.filter { $0.angleID == angleID }
                if matches.isEmpty {
                    addEdge(
                        source: address,
                        destination: nil,
                        ref: angleID,
                        disposition: .missingReference
                    )
                    append(issue: .init(
                        code: .missingResource,
                        nodeAddress: address,
                        ref: angleID,
                        message: "mc-source angleID \(angleID) does not exist in multicam resource \(resourceID)"
                    ))
                } else if matches.count > 1 {
                    addEdge(
                        source: address,
                        destination: nil,
                        ref: angleID,
                        disposition: .ambiguousReference
                    )
                    append(issue: .init(
                        code: .ambiguousResource,
                        nodeAddress: address,
                        ref: angleID,
                        message: "mc-source angleID \(angleID) is declared \(matches.count) times"
                    ))
                }
            }
        }

        private func resolveNonFileReference(
            of element: any OFKXMLElement,
            at address: ProjectNodeAddress,
            referenceIsRequired: Bool
        ) {
            guard let ref = element.fcpRef, !ref.isEmpty else {
                if referenceIsRequired {
                    missingReference(at: address, ref: nil)
                    return
                }
                addEdge(source: address, destination: nil, ref: nil, disposition: .provenNonFile)
                return
            }
            guard let resource = uniqueResource(ref: ref, at: address) else { return }
            let resourceAddress = address.appending(resource)
            addNode(
                element: resource,
                address: resourceAddress,
                parentAddress: address,
                active: true,
                restoration: true,
                containerAncestry: ["non-file-resource"]
            )
            addEdge(source: address, destination: resourceAddress, ref: ref, disposition: .provenNonFile)
        }

        private func recordEffectReferences(
            in element: any OFKXMLElement,
            parentAddress: ProjectNodeAddress,
            active: Bool,
            containerAncestry: [String]
        ) {
            let children = element.childElements.filter {
                Self.dependencySupportElementNames.contains($0.name ?? "")
            }
            for addressedChild in parentAddress.addressing(children) {
                let child = addressedChild.element
                let childAddress = addressedChild.address
                addNode(
                    element: child,
                    address: childAddress,
                    parentAddress: parentAddress,
                    active: active,
                    restoration: true,
                    containerAncestry: containerAncestry + ["dependency-support"]
                )
                addEdge(
                    source: parentAddress,
                    destination: childAddress,
                    ref: nil,
                    disposition: .resolvedContainer
                )
                if Self.effectReferenceElementNames.contains(child.name ?? "") {
                    resolveNonFileReference(
                        of: child,
                        at: childAddress,
                        referenceIsRequired: true
                    )
                } else {
                    recordEffectReferences(
                        in: child,
                        parentAddress: childAddress,
                        active: active && child.fcpGetEnabled(default: true),
                        containerAncestry: containerAncestry + [child.name ?? "dependency-support"]
                    )
                }
            }
        }

        private func validateSourceID(
            at address: ProjectNodeAddress,
            resourceID: String,
            asset: Asset,
            kind: MediaChannel.Kind
        ) {
            let raw = nodesByAddress[address]?.sourceChannelFacts.declaredSourceID
            let sourceIndex: Int
            if raw == nil {
                sourceIndex = 1
            } else if let parsed = raw.flatMap(Int.init), parsed > 0 {
                sourceIndex = parsed
            } else {
                append(issue: .init(
                    code: .invalidSourceID,
                    nodeAddress: address,
                    ref: resourceID,
                    resourceID: resourceID,
                    message: "\(kind.rawValue) srcID must be a positive integer; only an absent srcID defaults to 1"
                ))
                return
            }
            let channels = AssetChannelExpansion.channels(
                from: asset,
                kind: kind,
                sourceIndex: sourceIndex
            )
            guard !channels.isEmpty else {
                append(issue: .init(
                    code: .sourceIndexOutOfRange,
                    nodeAddress: address,
                    ref: resourceID,
                    resourceID: resourceID,
                    message: "\(kind.rawValue) srcID \(sourceIndex) is outside asset \(resourceID) channels"
                ))
                return
            }
        }

        private func uniqueResource(
            ref: String,
            at address: ProjectNodeAddress
        ) -> (any OFKXMLElement)? {
            let matches = resources.childElements.filter { $0.fcpID == ref }
            if matches.isEmpty {
                addEdge(source: address, destination: nil, ref: ref, disposition: .missingReference)
                append(issue: .init(
                    code: .missingResource,
                    nodeAddress: address,
                    ref: ref,
                    resourceID: ref,
                    message: "Referenced resource \(ref) does not exist"
                ))
                return nil
            }
            if matches.count > 1 {
                addEdge(source: address, destination: nil, ref: ref, disposition: .ambiguousReference)
                append(issue: .init(
                    code: .ambiguousResource,
                    nodeAddress: address,
                    ref: ref,
                    resourceID: ref,
                    message: "Referenced resource \(ref) is declared \(matches.count) times"
                ))
                return nil
            }
            return matches[0]
        }

        private func missingReference(at address: ProjectNodeAddress, ref: String?) {
            addEdge(source: address, destination: nil, ref: ref, disposition: .missingReference)
            append(issue: .init(
                code: .missingReference,
                nodeAddress: address,
                ref: ref,
                resourceID: ref,
                message: "Reachable media element has no resource ref"
            ))
        }

        private func cycle(at address: ProjectNodeAddress, ref: String) {
            addEdge(source: address, destination: nil, ref: ref, disposition: .cycle)
            append(issue: .init(
                code: .resourceCycle,
                nodeAddress: address,
                ref: ref,
                resourceID: ref,
                message: "Resource reference cycle detected at \(ref)"
            ))
        }

        func merge(
            restorationWindows: [MediaUsageWindow],
            activeWindows: [MediaUsageWindow]
        ) {
            var restorationByID: [ProjectUsageID: MediaUsageWindow] = [:]
            var activeByID: [ProjectUsageID: MediaUsageWindow] = [:]
            index(windows: restorationWindows, into: &restorationByID, view: "restoration")
            index(windows: activeWindows, into: &activeByID, view: "active")

            for (id, activeWindow) in activeByID where restorationByID[id] == nil {
                append(issue: .init(
                    code: .activeUsageMissingFromRestoration,
                    nodeAddress: id.nodeAddress,
                    ref: activeWindow.channel.resourceID,
                    resourceID: activeWindow.channel.resourceID,
                    message: "Active usage \(id.description) is absent from restoration view"
                ))
            }

            for id in Set(restorationByID.keys).union(activeByID.keys) {
                guard let window = restorationByID[id] ?? activeByID[id] else { continue }
                if let restorationWindow = restorationByID[id],
                   let activeWindow = activeByID[id],
                   (restorationWindow.channel != activeWindow.channel
                    || restorationWindow.retiming != activeWindow.retiming
                    || restorationWindow.lanePath != activeWindow.lanePath)
                {
                    append(issue: .init(
                        code: .conflictingUsageProjection,
                        nodeAddress: id.nodeAddress,
                        ref: window.channel.resourceID,
                        resourceID: window.channel.resourceID,
                        message: "Active and restoration projections disagree for \(id.description)"
                    ))
                }
                usagesByID[id] = ProjectRestorationUsage(
                    id: id,
                    nodeAddress: id.nodeAddress,
                    resourceID: window.channel.resourceID,
                    mediaKind: window.channel.kind,
                    sourceIndex: window.channel.sourceIndex,
                    sourceChannelFacts: window.sourceChannelFacts,
                    retiming: window.retiming,
                    isActive: activeByID[id] != nil,
                    isRestoration: restorationByID[id] != nil,
                    lanePath: window.lanePath,
                    retimingSegmentOrdinal: id.retimingSegmentOrdinal,
                    nativeStart: window.channel.nativeStart,
                    nativeDuration: window.channel.nativeDuration
                )
                markNodePath(for: id.nodeAddress, active: activeByID[id] != nil)
            }

            for (leafAddress, resourceID) in mediaLeafAddresses {
                let hasUsage = restorationByID.keys.contains { id in
                    id.nodeAddress == leafAddress || leafAddress.isAncestor(of: id.nodeAddress)
                }
                if !hasUsage {
                    append(issue: .init(
                        code: .projectionFailure,
                        nodeAddress: leafAddress,
                        ref: resourceID,
                        resourceID: resourceID,
                        message: "Reachable media leaf \(resourceID) produced no restoration usage"
                    ))
                }
            }

            for usage in usagesByID.values where transitionNeighborAddresses.contains(where: {
                $0 == usage.nodeAddress || $0.isAncestor(of: usage.nodeAddress)
            }) {
                copyFullResourceIDs.insert(usage.resourceID)
            }
        }

        private func index(
            windows: [MediaUsageWindow],
            into index: inout [ProjectUsageID: MediaUsageWindow],
            view: String
        ) {
            for window in windows {
                guard let address = window.projectNodeAddress,
                      let segmentOrdinal = window.retimingSegmentOrdinal
                else {
                    append(issue: .init(
                        code: .projectionFailure,
                        nodeAddress: rootAddress,
                        ref: window.channel.resourceID,
                        resourceID: window.channel.resourceID,
                        message: "\(view) projection emitted media without stable Project provenance"
                    ))
                    continue
                }
                let id = ProjectUsageID(
                    nodeAddress: address,
                    mediaKind: window.channel.kind,
                    sourceIndex: window.channel.sourceIndex,
                    retimingSegmentOrdinal: segmentOrdinal
                )
                if index[id] != nil {
                    append(issue: .init(
                        code: .conflictingUsageProjection,
                        nodeAddress: address,
                        ref: window.channel.resourceID,
                        resourceID: window.channel.resourceID,
                        message: "\(view) projection emitted duplicate usage identity \(id.description)"
                    ))
                } else {
                    index[id] = window
                }
            }
        }

        private func markNodePath(for leaf: ProjectNodeAddress, active: Bool) {
            for (address, node) in nodesByAddress
            where address == leaf || address.isAncestor(of: leaf) {
                nodesByAddress[address] = ProjectRestorationNode(
                    address: node.address,
                    parentAddress: node.parentAddress,
                    elementName: node.elementName,
                    structuralKind: node.structuralKind,
                    ref: node.ref,
                    lane: node.lane,
                    isEnabled: node.isEnabled,
                    auditionCandidateIndex: node.auditionCandidateIndex,
                    isActiveAuditionCandidate: node.isActiveAuditionCandidate,
                    multicamAngleID: node.multicamAngleID,
                    isActiveMulticamAngle: node.isActiveMulticamAngle,
                    containerAncestry: node.containerAncestry,
                    isActivePlaybackMember: node.isActivePlaybackMember || active,
                    isRestorationMember: true,
                    sourceChannelFacts: node.sourceChannelFacts
                )
            }
        }

        func finish() -> ProjectRestorationGraph {
            let blockingEdges = edges.contains(where: { $0.disposition.blocksCompleteness })
            let blockingIssues = issues.contains(where: \.isBlocking)
            let allRestorationStable = usagesByID.values.allSatisfy(\.isRestoration)
            let activeSubset = usagesByID.values.allSatisfy { !$0.isActive || $0.isRestoration }
            let complete = !blockingEdges && !blockingIssues && allRestorationStable && activeSubset

            return ProjectRestorationGraph(
                projectStableID: projectStableID,
                rootAddress: rootAddress,
                nodes: nodesByAddress.values.sorted { $0.address.description < $1.address.description },
                edges: Array(Set(edges)).sorted {
                    let lhs = "\($0.sourceAddress.description)|\($0.destinationAddress?.description ?? "")|\($0.ref ?? "")|\($0.disposition.rawValue)"
                    let rhs = "\($1.sourceAddress.description)|\($1.destinationAddress?.description ?? "")|\($1.ref ?? "")|\($1.disposition.rawValue)"
                    return lhs < rhs
                },
                usages: usagesByID.values.sorted { $0.id.description < $1.id.description },
                issues: Array(Set(issues)).sorted {
                    let lhs = "\($0.nodeAddress.description)|\($0.code.rawValue)|\($0.ref ?? "")|\($0.message)"
                    let rhs = "\($1.nodeAddress.description)|\($1.code.rawValue)|\($1.ref ?? "")|\($1.message)"
                    return lhs < rhs
                },
                requiresCopyFullResourceIDs: copyFullResourceIDs,
                isComplete: complete
            )
        }

        private func addContainer(
            element: any OFKXMLElement,
            address: ProjectNodeAddress,
            parentAddress: ProjectNodeAddress,
            active: Bool,
            ancestry: [String] = []
        ) {
            addNode(
                element: element,
                address: address,
                parentAddress: parentAddress,
                active: active,
                restoration: true,
                containerAncestry: ancestry
            )
            addEdge(
                source: parentAddress,
                destination: address,
                ref: nil,
                disposition: .resolvedContainer
            )
        }

        private func addNode(
            element: any OFKXMLElement,
            address: ProjectNodeAddress,
            parentAddress: ProjectNodeAddress?,
            active: Bool,
            restoration: Bool,
            auditionCandidateIndex: Int? = nil,
            activeAuditionCandidate: Bool? = nil,
            multicamAngleID: String? = nil,
            activeMulticamAngle: Bool? = nil,
            containerAncestry: [String] = []
        ) {
            let existing = nodesByAddress[address]
            nodesByAddress[address] = ProjectRestorationNode(
                address: address,
                parentAddress: parentAddress,
                elementName: element.name ?? "unknown",
                structuralKind: element.fcpElementType?.rawValue,
                ref: element.fcpRef,
                lane: element.fcpLane,
                isEnabled: element.fcpGetEnabled(default: true),
                auditionCandidateIndex: auditionCandidateIndex ?? existing?.auditionCandidateIndex,
                isActiveAuditionCandidate: activeAuditionCandidate ?? existing?.isActiveAuditionCandidate,
                multicamAngleID: multicamAngleID ?? existing?.multicamAngleID,
                isActiveMulticamAngle: activeMulticamAngle ?? existing?.isActiveMulticamAngle,
                containerAncestry: containerAncestry.isEmpty
                    ? (existing?.containerAncestry ?? [])
                    : containerAncestry,
                isActivePlaybackMember: active || (existing?.isActivePlaybackMember ?? false),
                isRestorationMember: restoration || (existing?.isRestorationMember ?? false),
                sourceChannelFacts: ProjectSourceChannelFacts.reading(
                    element,
                    expandsAllAssetChannels: element.fcpAsAssetClip != nil
                )
            )
        }

        private func addEdge(
            source: ProjectNodeAddress,
            destination: ProjectNodeAddress?,
            ref: String?,
            disposition: ProjectRestorationEdgeDisposition
        ) {
            edges.append(.init(
                sourceAddress: source,
                destinationAddress: destination,
                ref: ref,
                disposition: disposition
            ))
        }

        private func append(issue: ProjectRestorationIssue) {
            issues.append(issue)
            if let resourceID = issue.resourceID, issue.isBlocking {
                copyFullResourceIDs.insert(resourceID)
            }
        }

        private func rawRequiredRef(_ element: any OFKXMLElement) -> String? {
            element.stringValue(forAttributeNamed: "ref")
        }

        private static let effectReferenceElementNames: Set<String> = [
            "filter-video",
            "filter-audio",
        ]

        /// Non-story wrappers that can carry effect-resource references or audio-source facts.
        /// They are traversed by `recordEffectReferences` and excluded from the story walk so
        /// the same reached node is not subsequently mislabeled as unsupported.
        private static let dependencySupportElementNames: Set<String> = [
            "filter-video",
            "filter-audio",
            "filter-video-mask",
            "audio-channel-source",
            "audio-role-source",
            "sync-source",
            "mc-source",
        ]

        private func structuralChildren(
            of element: any OFKXMLElement
        ) -> [any OFKXMLElement] {
            element.childElements.filter { child in
                if Self.dependencySupportElementNames.contains(child.name ?? "") {
                    return false
                }
                if let type = child.fcpElementType {
                    return type.isStoryElement && !type.isLeafAnnotation
                }
                let parentIsStrictStoryContainer = element.fcpAsSpine != nil
                    || element.fcpAsAudition != nil
                    || element.fcpAsMCAngle != nil
                if parentIsStrictStoryContainer { return true }
                return child.fcpRef != nil
                    || child.stringValue(forAttributeNamed: "offset") != nil
                    || child.stringValue(forAttributeNamed: "start") != nil
                    || child.stringValue(forAttributeNamed: "duration") != nil
                    || child.stringValue(forAttributeNamed: "lane") != nil
            }
        }
    }
}
