//
//  FCPXMLProjectionEdgeCaseCorpusTests.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Projection edge-case corpus: J/L cuts, timeMap, nested ref/spine.
//

import Testing
import SwiftTimecode
@testable import OpenFCPXMLKit

@Suite("Projection edge-case corpus")
struct FCPXMLProjectionEdgeCaseCorpusTests {
    private let projector = FinalCutPro.FCPXML.TimelineProjector()

    private func parseInlineFCPXML(_ xml: String) throws -> FinalCutPro.FCPXML {
        let data = try #require(xml.data(using: .utf8))
        return try FinalCutPro.FCPXML(fileContent: data)
    }

    // MARK: - J/L + timeMap

    @Test("J/L cut with timeMap scales audio occupancy independently")
    func jlCutWithTimeMapScalesAudioIndependently() async throws {
        // Video occupancy normalized onto duration=5s at offset=2s → [2,7).
        // timeMap 0→10 remapped / 0→20 media → scale 2 on video.
        // Audio: audioStart=9s audioDuration=7s → timeline [1,8), also timeMap-normalized.
        let fcpxml = try parseInlineFCPXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                    <asset id="r2" name="ClipA" hasVideo="1" hasAudio="1" videoSources="1" audioSources="1" duration="60s">
                        <media-rep kind="original-media" src="file:///tmp/a.mov"/>
                    </asset>
                </resources>
                <library>
                    <event name="E">
                        <project name="P">
                            <sequence format="r1" duration="20s" tcStart="0s">
                                <spine>
                                    <asset-clip ref="r2" offset="2s" name="JLRetime" start="10s" duration="5s"
                                        audioStart="9s" audioDuration="7s">
                                        <timeMap>
                                            <timept time="0s" value="0s" interp="linear"/>
                                            <timept time="10s" value="20s" interp="linear"/>
                                        </timeMap>
                                    </asset-clip>
                                </spine>
                            </sequence>
                        </project>
                    </event>
                </library>
            </fcpxml>
            """)

        let source = try #require(fcpxml.allReportTimelineSources().first)
        let windows = try await projector.project(from: source, fcpxml: fcpxml, options: .trackAnalysis)
        let video = try #require(windows.first { $0.channel.kind == .video })
        let audio = try #require(windows.first { $0.channel.kind == .audio })

        #expect(abs(video.timelineIn.doubleValue - 2) < 0.001)
        #expect(abs(video.timelineOut.doubleValue - 7) < 0.001)
        #expect(abs(video.retiming.scale - 2) < 0.05)

        #expect(abs(audio.timelineIn.doubleValue - 1) < 0.001)
        #expect(abs(audio.timelineOut.doubleValue - 8) < 0.001)
        #expect(abs(audio.retiming.scale - 2) < 0.05)
        #expect(video.timelineIn != audio.timelineIn)
    }

    @Test("AudioStart-only J-cut from XML emits earlier audio window")
    func audioStartOnlyJCutFromXML() async throws {
        let fcpxml = try parseInlineFCPXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                    <asset id="r2" name="ClipA" hasVideo="1" hasAudio="1" videoSources="1" audioSources="1" duration="60s">
                        <media-rep kind="original-media" src="file:///tmp/a.mov"/>
                    </asset>
                </resources>
                <library>
                    <event name="E">
                        <project name="P">
                            <sequence format="r1" duration="10s" tcStart="0s">
                                <spine>
                                    <asset-clip ref="r2" offset="2s" name="JOnly" start="10s" duration="5s"
                                        audioStart="9s"/>
                                </spine>
                            </sequence>
                        </project>
                    </event>
                </library>
            </fcpxml>
            """)

        let source = try #require(fcpxml.allReportTimelineSources().first)
        let windows = try await projector.project(from: source, fcpxml: fcpxml, options: .init())
        let video = try #require(windows.first { $0.channel.kind == .video })
        let audio = try #require(windows.first { $0.channel.kind == .audio })

        #expect(video.timelineIn == Fraction(2, 1))
        #expect(video.timelineOut == Fraction(7, 1))
        #expect(audio.timelineIn == Fraction(1, 1))
        #expect(audio.timelineOut == Fraction(6, 1))
        #expect(audio.mediaIn == Fraction(9, 1))
    }

    // MARK: - Nested ref + timeMap / JL

    @Test("Nested ref-clip with outer timeMap and inner J/L cut")
    func nestedRefClipOuterTimeMapInnerJL() async throws {
        let fcpxml = try parseInlineFCPXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                    <asset id="r2" name="Leaf" hasVideo="1" hasAudio="1" videoSources="1" audioSources="1" duration="60s">
                        <media-rep kind="original-media" src="file:///tmp/leaf.mov"/>
                    </asset>
                    <media id="r3" name="Compound">
                        <sequence format="r1" duration="10s" tcStart="0s">
                            <spine>
                                <asset-clip ref="r2" offset="0s" name="Inner" start="10s" duration="5s"
                                    audioStart="9s" audioDuration="7s"/>
                            </spine>
                        </sequence>
                    </media>
                </resources>
                <library>
                    <event name="E">
                        <project name="P">
                            <sequence format="r1" duration="10s" tcStart="0s">
                                <spine>
                                    <ref-clip ref="r3" offset="0s" name="Outer" duration="4s">
                                        <timeMap>
                                            <timept time="0s" value="0s" interp="linear"/>
                                            <timept time="4s" value="8s" interp="linear"/>
                                        </timeMap>
                                    </ref-clip>
                                </spine>
                            </sequence>
                        </project>
                    </event>
                </library>
            </fcpxml>
            """)

        let source = try #require(fcpxml.allReportTimelineSources().first)
        let windows = try await projector.project(from: source, fcpxml: fcpxml, options: .trackAnalysis)
        let video = windows.filter { $0.channel.kind == .video }
        let audio = windows.filter { $0.channel.kind == .audio }
        #expect(!video.isEmpty)
        #expect(!audio.isEmpty)
        // Outer 2x map compresses nested occupancy onto ~4s timeline.
        #expect(video.contains { $0.timelineOut.doubleValue <= 4.1 + 0.05 })
        #expect(audio.contains { abs($0.timelineIn.doubleValue - $0.timelineOut.doubleValue) > 0.01 })
    }

    @Test("Nested secondary spine with timeMap child")
    func nestedSecondarySpineWithTimeMapChild() async throws {
        let fcpxml = try parseInlineFCPXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                    <asset id="r2" name="A" hasVideo="1" videoSources="1" duration="60s">
                        <media-rep kind="original-media" src="file:///tmp/a.mov"/>
                    </asset>
                    <asset id="r3" name="B" hasVideo="1" videoSources="1" duration="60s">
                        <media-rep kind="original-media" src="file:///tmp/b.mov"/>
                    </asset>
                </resources>
                <library>
                    <event name="E">
                        <project name="P">
                            <sequence format="r1" duration="20s" tcStart="0s">
                                <spine>
                                    <asset-clip ref="r2" offset="0s" name="Primary" start="0s" duration="10s">
                                        <spine lane="1" offset="2s">
                                            <asset-clip ref="r3" offset="0s" name="NestedRetime" start="0s" duration="4s">
                                                <timeMap>
                                                    <timept time="0s" value="0s" interp="linear"/>
                                                    <timept time="4s" value="8s" interp="linear"/>
                                                </timeMap>
                                            </asset-clip>
                                        </spine>
                                    </asset-clip>
                                </spine>
                            </sequence>
                        </project>
                    </event>
                </library>
            </fcpxml>
            """)

        let source = try #require(fcpxml.allReportTimelineSources().first)
        let windows = try await projector.project(from: source, fcpxml: fcpxml, options: .init())
        let nested = try #require(windows.first { $0.clipDisplayName == "NestedRetime" })
        #expect(nested.lanePath.components == [1])
        // Nested clip at parent abs 0+2=2, duration 4 → [2,6), scale ~2.
        #expect(abs(nested.timelineIn.doubleValue - 2) < 0.05)
        #expect(abs(nested.timelineOut.doubleValue - 6) < 0.05)
        #expect(abs(nested.retiming.scale - 2) < 0.1)
    }

    @Test("Generic clip timeMap segments compose as one container layer")
    func genericClipTimeMapSegmentsComposeAsOneContainerLayer() async throws {
        let fcpxml = try parseInlineFCPXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="1/24s" width="1920" height="1080"/>
                    <asset id="r2" name="Leaf" hasVideo="1" videoSources="1" duration="60s">
                        <media-rep kind="original-media" src="file:///tmp/leaf.mov"/>
                    </asset>
                </resources>
                <library><event name="E"><project name="P">
                    <sequence format="r1" duration="20s" tcStart="0s">
                        <spine>
                            <clip offset="10s" name="Container" start="30s" duration="6s">
                                <timeMap>
                                    <timept time="30s" value="40s" interp="linear"/>
                                    <timept time="32s" value="44s" interp="linear"/>
                                    <timept time="36s" value="48s" interp="linear"/>
                                </timeMap>
                                <video ref="r2" offset="40s" name="Leaf" start="40s" duration="8s"/>
                            </clip>
                        </spine>
                    </sequence>
                </project></event></library>
            </fcpxml>
            """)

        let source = try #require(fcpxml.allReportTimelineSources().first)
        let windows = try await projector.project(from: source, fcpxml: fcpxml, options: .init())

        #expect(windows.count == 2)
        #expect(windows.map(\.channel.resourceID) == ["r2", "r2"])
        #expect(windows.map(\.timelineIn) == [Fraction(10, 1), Fraction(12, 1)])
        #expect(windows.map(\.timelineOut) == [Fraction(12, 1), Fraction(16, 1)])
        #expect(windows.map(\.mediaIn) == [Fraction(40, 1), Fraction(44, 1)])
        #expect(windows.map(\.mediaOut) == [Fraction(44, 1), Fraction(48, 1)])
    }

    @Test("Generic clip freeze retains its nested video leaf")
    func genericClipFreezeRetainsNestedVideoLeaf() async throws {
        let fcpxml = try parseInlineFCPXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="1/24s" width="1920" height="1080"/>
                    <asset id="r2" name="Leaf" hasVideo="1" videoSources="1" duration="60s">
                        <media-rep kind="original-media" src="file:///tmp/frozen-leaf.mov"/>
                    </asset>
                </resources>
                <library><event name="E"><project name="P">
                    <sequence format="r1" duration="20s" tcStart="0s">
                        <spine>
                            <clip offset="10s" name="Frozen Container" start="30s" duration="4s">
                                <timeMap>
                                    <timept time="30s" value="40s" interp="linear"/>
                                    <timept time="34s" value="40s" interp="linear"/>
                                </timeMap>
                                <video ref="r2" offset="40s" name="Leaf" start="40s" duration="10s"/>
                            </clip>
                        </spine>
                    </sequence>
                </project></event></library>
            </fcpxml>
            """)

        let source = try #require(fcpxml.allReportTimelineSources().first)
        let windows = try await projector.project(from: source, fcpxml: fcpxml, options: .init())
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.channel.resourceID == "r2")
        #expect(window.timelineIn == Fraction(10, 1))
        #expect(window.timelineOut == Fraction(14, 1))
        #expect(window.mediaIn == Fraction(40, 1))
        #expect(window.mediaOut == Fraction(40, 1))
        #expect(window.retiming.scale == 0)
        #expect(window.retiming.isHold)
    }

    @Test("Explicit lane zero and omitted lane share primary content retiming")
    func explicitLaneZeroMatchesOmittedLaneRetiming() async throws {
        let fcpxml = try parseInlineFCPXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="1/24s" width="1920" height="1080"/>
                    <asset id="r2" name="Leaf" hasVideo="1" videoSources="1" duration="60s">
                        <media-rep kind="original-media" src="file:///tmp/leaf.mov"/>
                    </asset>
                </resources>
                <library><event name="E">
                    <project name="Omitted Lane"><sequence format="r1" duration="4s" tcStart="0s"><spine>
                        <clip offset="0s" start="10s" duration="4s">
                            <timeMap>
                                <timept time="10s" value="20s" interp="linear"/>
                                <timept time="14s" value="24s" interp="linear"/>
                            </timeMap>
                            <video ref="r2" offset="20s" start="20s" duration="4s"/>
                        </clip>
                    </spine></sequence></project>
                    <project name="Explicit Lane Zero"><sequence format="r1" duration="4s" tcStart="0s"><spine>
                        <clip offset="0s" start="10s" duration="4s">
                            <timeMap>
                                <timept time="10s" value="20s" interp="linear"/>
                                <timept time="14s" value="24s" interp="linear"/>
                            </timeMap>
                            <video ref="r2" lane="0" offset="20s" start="20s" duration="4s"/>
                        </clip>
                    </spine></sequence></project>
                </event></library>
            </fcpxml>
            """)

        let sources = fcpxml.allReportTimelineSources()
        let omittedSource = try #require(sources.first { $0.displayName == "Omitted Lane" })
        let laneZeroSource = try #require(sources.first { $0.displayName == "Explicit Lane Zero" })
        let omitted = try #require(
            try await projector.project(from: omittedSource, fcpxml: fcpxml, options: .init()).first
        )
        let laneZero = try #require(
            try await projector.project(from: laneZeroSource, fcpxml: fcpxml, options: .init()).first
        )

        #expect(omitted.channel.resourceID == laneZero.channel.resourceID)
        #expect(omitted.timelineIn == laneZero.timelineIn)
        #expect(omitted.timelineOut == laneZero.timelineOut)
        #expect(omitted.mediaIn == laneZero.mediaIn)
        #expect(omitted.mediaOut == laneZero.mediaOut)
        #expect(omitted.retiming.scale == laneZero.retiming.scale)
        #expect(omitted.retiming.isReversed == laneZero.retiming.isReversed)
        #expect(omitted.lanePath == .primary)
        #expect(laneZero.lanePath == .primary)
    }

    @Test("TimelineSample generic clip retimings retain direct asset leaves")
    func timelineSampleGenericClipRetimingsRetainDirectAssetLeaves() async throws {
        let fcpxml = try requireFCPXMLSample(named: "TimelineSample")
        let source = try #require(fcpxml.allReportTimelineSources().first)
        let options = FinalCutPro.FCPXML.TimelineProjectionOptions(
            includeDisabled: true,
            auditions: .all,
            mcClipAngles: .all,
            excludeFullyOccluded: false,
            includeAnnotations: false,
            includeMarkerAnnotations: false,
            includeKeywordAnnotations: false,
            expandAllSourceChannels: true
        )

        let windows = try await projector.project(from: source, fcpxml: fcpxml, options: options)
        let projectedIDs = Set(windows.map(\.channel.resourceID))
        let expectedIDs: Set<String> = [
            "r8", "r11", "r12", "r13", "r15", "r16", "r31", "r40", "r49", "r50",
        ]

        #expect(expectedIDs.isSubset(of: projectedIDs))
        for resourceID in expectedIDs {
            let matchingWindows = windows.filter { $0.channel.resourceID == resourceID }
            #expect(!matchingWindows.isEmpty)
            #expect(matchingWindows.allSatisfy { $0.retiming.hasUsableProjectionEndpoints })
            #expect(matchingWindows.allSatisfy {
                FinalCutPro.FCPXML.ProjectionTiming.compare($0.mediaIn, $0.mediaOut) != .equal
            })
        }
    }
}
