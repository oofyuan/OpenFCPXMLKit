//
//  FCPXMLTimeCoordinateContractTests.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

import Foundation
import SwiftTimecode
import Testing
@testable import OpenFCPXMLKit

@Suite("Authoritative time coordinate contract")
struct FCPXMLTimeCoordinateContractTests {
    private let projector = FinalCutPro.FCPXML.TimelineProjector()

    @Test("FCPXML 1.13 and 1.14 high conform rates map bidirectionally")
    func highConformSourceFrameRatesMapBidirectionally() throws {
        let pairs: [(
            rawValue: String,
            source: FinalCutPro.FCPXML.ConformRate.SourceFrameRate,
            timecode: TimecodeFrameRate
        )] = [
            ("90", .fps90, .fps90),
            ("100", .fps100, .fps100),
            ("119.88", .fps119_88, .fps119_88),
            ("120", .fps120, .fps120),
        ]

        for pair in pairs {
            #expect(FinalCutPro.FCPXML.ConformRate.SourceFrameRate(rawValue: pair.rawValue)
                == pair.source)
            #expect(pair.source.timecodeFrameRate == pair.timecode)
            #expect(FinalCutPro.FCPXML.ConformRate.SourceFrameRate(
                timecodeFrameRate: pair.timecode
            ) == pair.source)
        }
    }

    @Test("119.88 conform projects large nonzero source endpoints exactly")
    func conform11988PreservesLargeSourceEndpoints() async throws {
        let sourceStart = Fraction(987_654_321, 120_000)
        let sourceDuration = Fraction(12_012_000_000, 120_000)
        let sourceEnd = try #require(FinalCutPro.FCPXML.ProjectionTiming.adding(
            sourceStart,
            sourceDuration
        ))
        let windows = try await project("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.14">
                <resources>
                    <format id="r1" frameDuration="1/30s" width="1920" height="1080"/>
                    <format id="r2" frameDuration="1001/120000s" width="1920" height="1080"/>
                    <asset id="r3" format="r2" start="987654321/120000s" duration="12012000000/120000s" hasVideo="1" videoSources="1">
                        <media-rep kind="original-media" src="file:///tmp/high-rate-conform.mov"/>
                    </asset>
                </resources>
                <library><event name="E"><project name="P">
                    <sequence format="r1" duration="100000s" tcStart="0s">
                        <spine>
                            <asset-clip ref="r3" offset="0s" start="987654321/120000s" duration="100000s">
                                <conform-rate srcFrameRate="119.88"/>
                            </asset-clip>
                        </spine>
                    </sequence>
                </project></event></library>
            </fcpxml>
            """)

        let video = try #require(windows.first { $0.channel.kind == .video })
        #expect(video.timelineIn == .zero)
        #expect(video.timelineOut == Fraction(100_000, 1))
        #expect(video.mediaIn == sourceStart)
        #expect(video.mediaOut == sourceEnd)
        #expect(video.channel.nativeStart == sourceStart)
        #expect(video.channel.nativeDuration == sourceDuration)
    }

    @Test("30 to 29.97 conform preserves a large source origin")
    func conform30To2997PreservesSourceOrigin() async throws {
        let windows = try await project(assetClipFixture(
            sourceFrameDuration: "1/30s",
            sourceFrameRate: "30",
            sourceStart: "3000s",
            sourceDuration: "1/10s",
            timelineDuration: "3003/30000s"
        ))

        let video = try #require(windows.first { $0.channel.kind == .video })
        #expect(video.timelineIn == .zero)
        #expect(video.timelineOut == Fraction(3003, 30000))
        #expect(video.mediaIn == Fraction(3000, 1))
        #expect(video.mediaOut == Fraction(30001, 10))
        #expect(video.channel.nativeStart == Fraction(3000, 1))
    }

    @Test("60 to 29.97 conform preserves a large source origin")
    func conform60To2997PreservesSourceOrigin() async throws {
        let windows = try await project(assetClipFixture(
            sourceFrameDuration: "1/60s",
            sourceFrameRate: "60",
            sourceStart: "6000s",
            sourceDuration: "1/20s",
            timelineDuration: "3003/30000s"
        ))

        let video = try #require(windows.first { $0.channel.kind == .video })
        #expect(video.timelineOut == Fraction(3003, 30000))
        #expect(video.mediaIn == Fraction(6000, 1))
        #expect(video.mediaOut == Fraction(120001, 20))
    }

    @Test("Parent conform maps occupancy without scaling child source")
    func parentConformDoesNotScaleChildSource() async throws {
        let windows = try await project("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
                    <format id="r2" frameDuration="1/30s" width="1920" height="1080"/>
                    <asset id="r3" format="r2" start="100s" duration="10s" hasVideo="1" videoSources="1">
                        <media-rep kind="original-media" src="file:///tmp/child.mov"/>
                    </asset>
                </resources>
                <library><event name="E"><project name="P">
                    <sequence format="r1" duration="3003/30000s" tcStart="0s">
                        <spine>
                            <clip offset="10s" start="50s" duration="3003/30000s">
                                <conform-rate srcFrameRate="30"/>
                                <video ref="r3" offset="50s" start="100s" duration="1/10s"/>
                            </clip>
                        </spine>
                    </sequence>
                </project></event></library>
            </fcpxml>
            """)

        let video = try #require(windows.first { $0.channel.kind == .video })
        #expect(video.timelineIn == Fraction(10, 1))
        #expect(video.timelineOut == Fraction(101001, 10000))
        #expect(video.mediaIn == Fraction(100, 1))
        #expect(video.mediaOut == Fraction(1001, 10))
    }

    @Test("Conformed A/V clip compares audioStart in the raw source domain")
    func conformDoesNotInventAudioSplit() async throws {
        let windows = try await project("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
                    <format id="r2" frameDuration="1/30s" width="1920" height="1080"/>
                    <asset id="r3" format="r2" start="3000s" duration="1/10s" hasVideo="1" hasAudio="1" videoSources="1" audioSources="1" audioChannels="2" audioRate="48000">
                        <media-rep kind="original-media" src="file:///tmp/av.mov"/>
                    </asset>
                </resources>
                <library><event name="E"><project name="P">
                    <sequence format="r1" duration="3003/30000s" tcStart="0s">
                        <spine>
                            <asset-clip ref="r3" offset="0s" start="3000s" duration="3003/30000s" audioStart="3000s" audioDuration="1/10s">
                                <conform-rate srcFrameRate="30"/>
                            </asset-clip>
                        </spine>
                    </sequence>
                </project></event></library>
            </fcpxml>
            """)

        let video = try #require(windows.first { $0.channel.kind == .video })
        let audio = try #require(windows.first { $0.channel.kind == .audio })
        #expect(video.timelineIn == audio.timelineIn)
        #expect(video.timelineOut == audio.timelineOut)
        #expect(video.mediaIn == audio.mediaIn)
        #expect(video.mediaOut == audio.mediaOut)
        #expect(audio.mediaIn == Fraction(3000, 1))
        #expect(audio.mediaOut == Fraction(30001, 10))
    }

    @Test("timeMap adjusted and original axes stay distinct under conform")
    func timeMapAxesRemainDistinctUnderConform() async throws {
        let windows = try await project("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
                    <format id="r2" frameDuration="1/30s" width="1920" height="1080"/>
                    <asset id="r3" format="r2" start="100s" duration="20s" hasVideo="1" videoSources="1">
                        <media-rep kind="original-media" src="file:///tmp/map.mov"/>
                    </asset>
                </resources>
                <library><event name="E"><project name="P">
                    <sequence format="r1" duration="4s" tcStart="0s">
                        <spine>
                            <asset-clip ref="r3" offset="0s" start="100s" duration="4s">
                                <conform-rate srcFrameRate="30"/>
                                <timeMap>
                                    <timept time="0s" value="100s"/>
                                    <timept time="2s" value="102s"/>
                                    <timept time="4s" value="101s"/>
                                </timeMap>
                            </asset-clip>
                        </spine>
                    </sequence>
                </project></event></library>
            </fcpxml>
            """)

        let video = windows.filter { $0.channel.kind == .video }
        #expect(video.count == 2)
        #expect(video[0].timelineIn == .zero)
        #expect(video[0].timelineOut == Fraction(2, 1))
        #expect(video[0].mediaIn == Fraction(100, 1))
        #expect(video[0].mediaOut == Fraction(102, 1))
        #expect(video[1].timelineIn == Fraction(2, 1))
        #expect(video[1].timelineOut == Fraction(4, 1))
        #expect(video[1].mediaIn == Fraction(101, 1))
        #expect(video[1].mediaOut == Fraction(102, 1))
        #expect(video[1].retiming.mediaStart == Fraction(102, 1))
        #expect(video[1].retiming.mediaEnd == Fraction(101, 1))
        #expect(video[1].retiming.isReversed)
    }

    @Test("ref-clip carries usage conform across the resource-tree boundary")
    func refClipConformMapsNestedSequence() async throws {
        let windows = try await project("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.11">
                <resources>
                    <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
                    <format id="r2" frameDuration="1/30s" width="1920" height="1080"/>
                    <asset id="r3" format="r2" start="100s" duration="10s" hasVideo="1" videoSources="1">
                        <media-rep kind="original-media" src="file:///tmp/ref.mov"/>
                    </asset>
                    <media id="r4" name="Nested">
                        <sequence format="r2" duration="1/10s" tcStart="50s">
                            <spine><video ref="r3" offset="50s" start="100s" duration="1/10s"/></spine>
                        </sequence>
                    </media>
                </resources>
                <library><event name="E"><project name="P">
                    <sequence format="r1" duration="3003/30000s" tcStart="0s">
                        <spine>
                            <ref-clip ref="r4" offset="0s" start="50s" duration="3003/30000s">
                                <conform-rate srcFrameRate="30"/>
                            </ref-clip>
                        </spine>
                    </sequence>
                </project></event></library>
            </fcpxml>
            """)

        let video = try #require(windows.first { $0.channel.kind == .video })
        #expect(video.timelineIn == .zero)
        #expect(video.timelineOut == Fraction(3003, 30000))
        #expect(video.mediaIn == Fraction(100, 1))
        #expect(video.mediaOut == Fraction(1001, 10))
    }

    private func project(_ xml: String) async throws -> [FinalCutPro.FCPXML.MediaUsageWindow] {
        let fcpxml = try parseInlineFCPXML(xml)
        let source = try #require(fcpxml.allReportTimelineSources().first)
        return try await projector.project(
            from: source,
            fcpxml: fcpxml,
            options: .activeMediaUsage
        )
    }

    private func assetClipFixture(
        sourceFrameDuration: String,
        sourceFrameRate: String,
        sourceStart: String,
        sourceDuration: String,
        timelineDuration: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
                <format id="r2" frameDuration="\(sourceFrameDuration)" width="1920" height="1080"/>
                <asset id="r3" format="r2" start="\(sourceStart)" duration="\(sourceDuration)" hasVideo="1" videoSources="1">
                    <media-rep kind="original-media" src="file:///tmp/conform.mov"/>
                </asset>
            </resources>
            <library><event name="E"><project name="P">
                <sequence format="r1" duration="\(timelineDuration)" tcStart="0s">
                    <spine>
                        <asset-clip ref="r3" offset="0s" start="\(sourceStart)" duration="\(timelineDuration)">
                            <conform-rate srcFrameRate="\(sourceFrameRate)"/>
                        </asset-clip>
                    </spine>
                </sequence>
            </project></event></library>
        </fcpxml>
        """
    }
}
