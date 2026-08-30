//
//  ProjectRestorationGraphTests.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

import Foundation
import Testing
@testable import OpenFCPXMLKit

@Suite("Project restoration graph")
struct ProjectRestorationGraphTests {
    @Test("Stable usage identity and source-channel facts form a complete graph")
    func stableUsageIdentityAndSourceFacts() throws {
        let fcpxml = try parseInlineFCPXML(basicXML)
        let before = fcpxml.xml.xmlData
        let source = try #require(fcpxml.allReportTimelineSources().first)

        let graph = try fcpxml.projectRestorationGraph(from: source)
        let rebuilt = try fcpxml.projectRestorationGraph(from: source)

        #expect(graph.projectStableID == "PROJECT-STABLE-ID")
        #expect(graph.isComplete)
        #expect(!graph.usages.isEmpty)
        #expect(graph.activeUsages.map(\.id).allSatisfy { graph.restorationUsages.map(\.id).contains($0) })
        #expect(Set(graph.usages.map(\.id)).count == graph.usages.count)
        #expect(rebuilt.nodes.map(\.address) == graph.nodes.map(\.address))
        #expect(rebuilt.usages.map(\.id) == graph.usages.map(\.id))

        let repeatedAssetClipUsages = graph.usages.filter {
            $0.resourceID == "r2" && $0.nodeAddress.components.last?.elementName == "asset-clip"
        }
        #expect(Set(repeatedAssetClipUsages.map(\.nodeAddress)).count == 2)

        let videoLeafUsages = graph.usages.filter {
            $0.nodeAddress.components.last?.elementName == "video"
        }
        #expect(videoLeafUsages.count == 2)
        let defaultVideoLeaf = try #require(videoLeafUsages.first {
            $0.sourceChannelFacts.declaredSourceID == nil
        })
        #expect(defaultVideoLeaf.sourceIndex == 1)
        let explicitVideoLeaf = try #require(videoLeafUsages.first {
            $0.sourceChannelFacts.declaredSourceID == "2"
        })
        #expect(explicitVideoLeaf.sourceIndex == 2)

        let audioLeafUsages = graph.usages.filter {
            $0.nodeAddress.components.last?.elementName == "audio"
        }
        #expect(audioLeafUsages.count == 1)
        let audioLeaf = try #require(audioLeafUsages.first)
        #expect(audioLeaf.sourceIndex == 1)
        #expect(audioLeaf.sourceChannelFacts.sourceChannels == "1, 2")
        #expect(audioLeaf.sourceChannelFacts.outputChannels == "L, R")
        #expect(audioLeaf.sourceChannelFacts.audioChannelSources.count == 1)
        #expect(audioLeaf.sourceChannelFacts.audioChannelSources[0].sourceChannels == "1, 2")

        let assetClip = try #require(graph.nodes.first { $0.elementName == "asset-clip" })
        #expect(assetClip.sourceChannelFacts.expandsAllAssetChannels)
        let assetClipSourceIndexes = Set(graph.usages.filter {
            $0.nodeAddress.components.last?.elementName == "asset-clip"
        }.map(\.sourceIndex))
        #expect(assetClipSourceIndexes == [1, 2])
        #expect(fcpxml.xml.xmlData == before)
    }

    @Test("Restoration contains disabled, audition alternatives, and every multicam angle")
    func restorationSelectionFacts() throws {
        let fcpxml = try parseInlineFCPXML(selectionXML)
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(graph.isComplete)
        let resources = Dictionary(grouping: graph.usages, by: \.resourceID)
        #expect(resources["r2"]?.contains(where: \.isRestoration) == true)
        #expect(resources["r3"]?.contains(where: \.isRestoration) == true)
        #expect(resources["r4"]?.contains(where: \.isRestoration) == true)
        #expect(resources["r4"]?.contains(where: \.isActive) == false)

        let auditionNodes = graph.nodes.filter { $0.auditionCandidateIndex != nil }
        #expect(auditionNodes.count == 2)
        #expect(auditionNodes.first { $0.auditionCandidateIndex == 0 }?.isActiveAuditionCandidate == true)
        #expect(auditionNodes.first { $0.auditionCandidateIndex == 1 }?.isActiveAuditionCandidate == false)

        let angles = graph.nodes.filter { $0.multicamAngleID != nil }
        #expect(Set(angles.compactMap(\.multicamAngleID)) == Set(["angle-a", "angle-b"]))
        #expect(angles.first { $0.multicamAngleID == "angle-b" }?.isActiveMulticamAngle == true)
        #expect(angles.first { $0.multicamAngleID == "angle-a" }?.isActiveMulticamAngle == false)
    }

    @Test("Restoration retains fully covered connected media")
    func restorationRetainsOccludedConnectedMedia() throws {
        let fcpxml = try parseInlineFCPXML(connectedOcclusionXML)
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(graph.isComplete)
        let restorationIDs = Set(graph.restorationUsages.map(\.resourceID))
        #expect(restorationIDs.isSuperset(of: ["r2", "r3", "r4"]))
        let lowerConnected = try #require(graph.nodes.first {
            $0.ref == "r3" && $0.lane == 1
        })
        #expect(lowerConnected.isRestorationMember)
        #expect(graph.restorationUsages.contains {
            $0.resourceID == "r3"
                && ($0.nodeAddress == lowerConnected.address
                    || lowerConnected.address.isAncestor(of: $0.nodeAddress))
        })
    }

    @Test("Nested compound, sync, and generic containers retain usage-specific addresses")
    func nestedContainerAddresses() throws {
        let fcpxml = try parseInlineFCPXML(nestedXML)
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(graph.isComplete)
        let usages = graph.usages.filter { $0.resourceID == "r2" }
        #expect(usages.count == 2)
        #expect(Set(usages.map(\.id)).count == 2)
        #expect(Set(usages.map(\.nodeAddress)).count == 2)
        for usage in usages {
            #expect(usage.nodeAddress.components.map(\.elementName).contains("ref-clip"))
            #expect(usage.nodeAddress.components.map(\.elementName).contains("sync-clip"))
            #expect(usage.nodeAddress.components.map(\.elementName).contains("clip"))
            #expect(usage.nodeAddress.parent != nil)
        }
    }

    @Test("Byte-identical sibling usages keep distinct deterministic addresses")
    func identicalSiblingAddresses() throws {
        let repeatedLeaf = "<video ref=\"r2\" lane=\"1\" offset=\"0s\" start=\"0s\" duration=\"1s\"/>"
        let fcpxml = try parseInlineFCPXML(documentXML(
            story: "<asset-clip ref=\"r3\" offset=\"0s\" start=\"0s\" duration=\"1s\">"
                + repeatedLeaf + repeatedLeaf + "</asset-clip>",
            resources: asset(id: "r2") + asset(id: "r3")
        ))
        let source = try #require(fcpxml.allReportTimelineSources().first)

        let first = try fcpxml.projectRestorationGraph(from: source)
        let second = try fcpxml.projectRestorationGraph(from: source)
        let usages = first.restorationUsages.filter { $0.resourceID == "r2" }

        #expect(first.isComplete)
        #expect(usages.count == 2)
        #expect(Set(usages.map(\.nodeAddress)).count == 2)
        #expect(first.usages.map(\.id) == second.usages.map(\.id))
    }

    @Test("Missing, duplicate, and unknown reachable structure is explicit")
    func malformedClosureIsIncomplete() throws {
        let fcpxml = try parseInlineFCPXML(malformedXML)
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(!graph.isComplete)
        let codes = Set(graph.issues.map(\.code))
        #expect(codes.contains(.ambiguousResource))
        #expect(codes.contains(.missingReference))
        #expect(codes.contains(.unsupportedReachableElement))
        #expect(graph.edges.contains { $0.disposition == .ambiguousReference })
        #expect(graph.edges.contains { $0.disposition == .missingReference })
        #expect(graph.edges.contains { $0.disposition == .unsupported })
    }

    @Test("Resource cycles and traversal depth limits do not disappear or crash")
    func cycleAndDepthLimit() throws {
        let cycleDocument = try parseInlineFCPXML(cycleXML)
        let cycleSource = try #require(cycleDocument.allReportTimelineSources().first)
        let cycleGraph = try cycleDocument.projectRestorationGraph(from: cycleSource)
        #expect(!cycleGraph.isComplete)
        #expect(cycleGraph.issues.contains { $0.code == .resourceCycle })
        #expect(cycleGraph.edges.contains { $0.disposition == .cycle })

        let nestedOpen = (0..<66).map { index in
            "<clip name=\"c\(index)\" offset=\"0s\" duration=\"1s\">"
        }.joined()
        let nestedClose = String(repeating: "</clip>", count: 66)
        let depthDocument = try parseInlineFCPXML(documentXML(story: nestedOpen + nestedClose))
        let depthSource = try #require(depthDocument.allReportTimelineSources().first)
        let depthGraph = try depthDocument.projectRestorationGraph(from: depthSource)
        #expect(!depthGraph.isComplete)
        #expect(depthGraph.issues.contains { $0.code == .depthLimit })
        #expect(depthGraph.edges.contains { $0.disposition == .depthLimit })
    }

    @Test("Invalid source IDs never expand a video or audio leaf to every channel")
    func invalidSourceIDsAreIssues() throws {
        let fcpxml = try parseInlineFCPXML(invalidSourceXML)
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(!graph.isComplete)
        #expect(graph.issues.filter { $0.code == .invalidSourceID }.count == 3)
        #expect(graph.issues.filter { $0.code == .sourceIndexOutOfRange }.count == 1)
        #expect(graph.usages.isEmpty)
        #expect(graph.requiresCopyFullResourceIDs == Set(["r2"]))
    }

    @Test("A reached media leaf without usable projected endpoints is explicit")
    func unusableMediaProjectionIsExplicit() throws {
        let fcpxml = try parseInlineFCPXML(documentXML(
            story: "<asset-clip ref=\"r2\" offset=\"0s\" start=\"0s\" duration=\"0s\"/>",
            resources: asset(id: "r2")
        ))
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(!graph.isComplete)
        #expect(graph.issues.contains {
            $0.code == .projectionFailure && $0.resourceID == "r2"
        })
        #expect(graph.requiresCopyFullResourceIDs.contains("r2"))
    }

    @Test("Transitions remain non-file nodes and require adjacent media copy-full")
    func transitionPreservesAdjacentMedia() throws {
        let fcpxml = try parseInlineFCPXML(transitionXML)
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(graph.isComplete)
        #expect(graph.edges.contains {
            $0.ref == "rTransition" && $0.disposition == .provenNonFile
        })
        #expect(graph.issues.contains {
            $0.code == .transitionHandlesUnproven && !$0.isBlocking
        })
        #expect(graph.requiresCopyFullResourceIDs == Set(["r2", "r3"]))
    }

    @Test("Direct and nested effect references are proven non-file exactly once")
    func nestedEffectReferencesAreExplicit() throws {
        let fcpxml = try parseInlineFCPXML(effectReferencesXML)
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(graph.isComplete)
        let effectRefs = graph.edges.filter {
            $0.disposition == .provenNonFile && $0.ref?.hasPrefix("rEffect") == true
        }
        #expect(Set(effectRefs.compactMap(\.ref)) == Set(["rEffect1", "rEffect2", "rEffect3"]))
        #expect(effectRefs.count == 3)
        #expect(graph.nodes.contains { $0.elementName == "filter-video-mask" })
        #expect(graph.nodes.contains { $0.elementName == "audio-channel-source" })
        #expect(!graph.issues.contains { $0.code == .unsupportedReachableElement })
    }

    @Test("A video reference to an effect is proven non-file")
    func videoEffectReferenceIsProvenNonFile() throws {
        let fcpxml = try parseInlineFCPXML(documentXML(
            story: """
            <video ref="rGenerator" offset="0s" start="0s" duration="2s"/>
            <asset-clip ref="r2" offset="2s" start="0s" duration="2s"/>
            """,
            resources: """
            <effect id="rGenerator" name="Generator" uid=".../Generators.localized/Test.localized/Test.motn"/>
            \(asset(id: "r2"))
            """
        ))
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(graph.isComplete)
        #expect(graph.edges.contains {
            $0.ref == "rGenerator" && $0.disposition == .provenNonFile
        })
        #expect(!graph.usages.contains { $0.resourceID == "rGenerator" })
        #expect(!graph.requiresCopyFullResourceIDs.contains("rGenerator"))
        #expect(!graph.issues.contains {
            $0.resourceID == "rGenerator"
                && ($0.code == .invalidContainerResource || $0.code == .projectionFailure)
        })
        #expect(graph.usages.contains { $0.resourceID == "r2" })
    }

    @Test("A missing multicam angle is an explicit blocking edge")
    func missingMulticamAngleIsExplicit() throws {
        let fcpxml = try parseInlineFCPXML(documentXML(
            story: """
            <mc-clip ref="r6" offset="0s" start="0s" duration="2s">
                <mc-source angleID="missing-angle" srcEnable="all"/>
            </mc-clip>
            """,
            resources: """
            <media id="r6"><multicam format="r1">
                <mc-angle angleID="angle-a"><asset-clip ref="r2" offset="0s" start="0s" duration="2s"/></mc-angle>
            </multicam></media>
            \(asset(id: "r2"))
            """
        ))
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let graph = try fcpxml.projectRestorationGraph(from: source)

        #expect(!graph.isComplete)
        #expect(graph.edges.contains {
            $0.ref == "missing-angle" && $0.disposition == .missingReference
        })
        #expect(graph.issues.contains {
            $0.code == .missingResource && $0.ref == "missing-angle"
        })
    }

    private var basicXML: String {
        documentXML(story: """
            <asset-clip ref="r2" offset="0s" start="0s" duration="2s"/>
            <asset-clip ref="r2" offset="2s" start="2s" duration="2s"/>
            <video ref="r2" offset="4s" start="4s" duration="1s"/>
            <audio ref="r2" offset="5s" start="5s" duration="1s" srcCh="1, 2" outCh="L, R">
                <audio-channel-source srcCh="1, 2" outCh="L, R"/>
            </audio>
            <video ref="r2" srcID="2" offset="6s" start="6s" duration="1s"/>
            """, resources: """
            <asset id="r2" name="AV" start="0s" duration="20s" hasVideo="1" hasAudio="1" videoSources="2" audioSources="2" audioChannels="2" audioRate="48000">
                <media-rep kind="original-media" src="file:///tmp/av.mov"/>
            </asset>
            """)
    }

    private var selectionXML: String {
        documentXML(story: """
            <audition offset="0s">
                <asset-clip ref="r2" offset="0s" start="0s" duration="2s"/>
                <asset-clip ref="r3" offset="0s" start="0s" duration="2s"/>
            </audition>
            <asset-clip ref="r4" offset="2s" start="0s" duration="2s" enabled="0"/>
            <mc-clip ref="r6" offset="4s" start="0s" duration="2s">
                <mc-source angleID="angle-b" srcEnable="all"/>
            </mc-clip>
            """, resources: """
            \(asset(id: "r2"))
            \(asset(id: "r3"))
            \(asset(id: "r4"))
            <media id="r6"><multicam format="r1">
                <mc-angle angleID="angle-a"><asset-clip ref="r2" offset="0s" start="0s" duration="2s"/></mc-angle>
                <mc-angle angleID="angle-b"><asset-clip ref="r3" offset="0s" start="0s" duration="2s"/></mc-angle>
            </multicam></media>
            """)
    }

    private var nestedXML: String {
        documentXML(story: """
            <ref-clip ref="r5" offset="0s" start="0s" duration="2s"/>
            <ref-clip ref="r5" offset="2s" start="0s" duration="2s"/>
            """, resources: """
            \(asset(id: "r2"))
            <media id="r5"><sequence format="r1" duration="2s" tcStart="0s"><spine>
                <sync-clip offset="0s" start="0s" duration="2s"><clip offset="0s" start="0s" duration="2s">
                    <video ref="r2" offset="0s" start="0s" duration="2s"/>
                </clip></sync-clip>
            </spine></sequence></media>
            """)
    }

    private var connectedOcclusionXML: String {
        documentXML(story: """
            <asset-clip ref="r2" offset="0s" start="0s" duration="4s">
                <asset-clip ref="r3" lane="1" offset="0s" start="0s" duration="4s"/>
                <asset-clip ref="r4" lane="2" offset="0s" start="0s" duration="4s"/>
            </asset-clip>
            """, resources: """
            \(asset(id: "r2"))
            \(asset(id: "r3"))
            \(asset(id: "r4"))
            """)
    }

    private var transitionXML: String {
        documentXML(story: """
            <asset-clip ref="r2" offset="0s" start="0s" duration="2s"/>
            <transition offset="1s" duration="1s"><filter-video ref="rTransition"/></transition>
            <asset-clip ref="r3" offset="2s" start="0s" duration="2s"/>
            """, resources: """
            \(asset(id: "r2"))
            \(asset(id: "r3"))
            <effect id="rTransition" name="Cross Dissolve" uid=".../Transitions.localized/Dissolves.localized/Cross Dissolve.localized/Cross Dissolve.motr"/>
            """)
    }

    private var effectReferencesXML: String {
        documentXML(story: """
            <asset-clip ref="r2" offset="0s" start="0s" duration="2s">
                <filter-video ref="rEffect1"/>
                <filter-video-mask>
                    <mask-shape name="Mask"/>
                    <filter-video ref="rEffect2"/>
                </filter-video-mask>
                <audio-channel-source srcCh="1" outCh="L">
                    <filter-audio ref="rEffect3"/>
                </audio-channel-source>
            </asset-clip>
            """, resources: """
            \(asset(id: "r2"))
            <effect id="rEffect1" name="Direct" uid="effect.direct"/>
            <effect id="rEffect2" name="Masked" uid="effect.masked"/>
            <effect id="rEffect3" name="Audio" uid="effect.audio"/>
            """)
    }

    private var malformedXML: String {
        documentXML(story: """
            <asset-clip ref="r2" offset="0s" start="0s" duration="1s"/>
            <asset-clip offset="1s" start="0s" duration="1s"/>
            <mystery-clip offset="2s" duration="1s"/>
            """, resources: """
            \(asset(id: "r2"))
            \(asset(id: "r2"))
            """)
    }

    private var cycleXML: String {
        documentXML(story: """
            <ref-clip ref="r5" offset="0s" start="0s" duration="1s"/>
            """, resources: """
            <media id="r5"><sequence format="r1" duration="1s" tcStart="0s"><spine>
                <ref-clip ref="r5" offset="0s" start="0s" duration="1s"/>
            </spine></sequence></media>
            """)
    }

    private var invalidSourceXML: String {
        documentXML(story: """
            <video ref="r2" srcID="0" offset="0s" start="0s" duration="1s"/>
            <audio ref="r2" srcID="bogus" offset="1s" start="0s" duration="1s"/>
            <video ref="r2" srcID="2" offset="2s" start="0s" duration="1s"/>
            <audio ref="r2" srcID="" offset="3s" start="0s" duration="1s"/>
            """, resources: asset(id: "r2"))
    }

    private func asset(id: String) -> String {
        """
        <asset id="\(id)" name="\(id)" start="0s" duration="20s" hasVideo="1" hasAudio="1" videoSources="1" audioSources="1" audioChannels="2" audioRate="48000">
            <media-rep kind="original-media" src="file:///tmp/\(id).mov"/>
        </asset>
        """
    }

    private func documentXML(story: String, resources: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="1/24s" width="1920" height="1080"/>
                \(resources)
            </resources>
            <library><event name="E"><project name="P" uid="PROJECT-STABLE-ID">
                <sequence format="r1" duration="100s" tcStart="0s"><spine>\(story)</spine></sequence>
            </project></event></library>
        </fcpxml>
        """
    }
}
