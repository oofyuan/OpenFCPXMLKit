//
//  FCPXMLRoleInventoryDuplicateFramesTests.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Unit tests for inventory Duplicate Frames source-range reuse math.
//

import Foundation
import SwiftTimecode
import Testing
@testable import OpenFCPXMLKit

@Suite("Role inventory duplicate frames")
struct FCPXMLRoleInventoryDuplicateFramesTests {
    @Test("Union duration merges overlapping media reuse intervals")
    func unionDurationMergesOverlappingReuseIntervals() {
        let intervals = [
            FinalCutPro.FCPXML.TimelineOccupancyIndex.Interval(start: 0, end: 2),
            FinalCutPro.FCPXML.TimelineOccupancyIndex.Interval(start: 1, end: 3),
            FinalCutPro.FCPXML.TimelineOccupancyIndex.Interval(start: 5, end: 6)
        ]
        #expect(
            FinalCutPro.FCPXML.TimelineOccupancyIndex.unionDuration(intervals) == 4
        )
    }
    
    @Test("Column exclusion resolves Duplicate Frames alias")
    func columnExclusionResolvesDuplicateFramesAlias() {
        #expect(
            FinalCutPro.FCPXML.ReportColumnExclusion.resolveColumn("Duplicate Frames")
                == .duplicateFrames
        )
    }
    
    @Test("Unretimed same-start clip is a full duplicate; later start overlaps 02:18")
    func unretimedClip50StyleFullAndPartialOverlap() async throws {
        // 130/24s = 00:00:05:10. Third clip starts 64/24s later → overlap 66/24s = 00:00:02:18.
        let fcpxml = try parseInlineFCPXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                <asset id="r2" name="Clip50" uid="A1" start="0s" duration="20s" hasVideo="1" format="r1" videoSources="1"/>
            </resources>
            <library>
                <event name="E" uid="E1">
                    <project name="P" uid="P1">
                        <sequence format="r1" duration="40s" tcStart="0s" tcFormat="NDF">
                            <spine>
                                <asset-clip ref="r2" offset="0s" name="Clip50" start="10s" duration="130/24s" format="r1"/>
                                <asset-clip ref="r2" offset="10s" name="Clip50" start="10s" duration="130/24s" format="r1"/>
                                <asset-clip ref="r2" offset="20s" name="Clip50" start="304/24s" duration="130/24s" format="r1"/>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """)
        
        let rows = try await inventoryRows(from: fcpxml)
        #expect(rows.count == 3)
        #expect(rows[0].sourceIn == rows[1].sourceIn)
        #expect(rows[0].duplicateFrames == "00:00:05:10")
        #expect(rows[1].duplicateFrames == "00:00:05:10")
        #expect(rows[2].duplicateFrames == "00:00:02:18")
    }
    
    @Test("Retimed clips with different Source In do not inherit the whole timeMap as duplicates")
    func retimedClipsWithDifferentSourceInAreNotWholeMapDuplicates() async throws {
        let fcpxml = try parseInlineFCPXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                <asset id="r2" name="Shot" uid="A1" start="0s" duration="120s" hasVideo="1" format="r1" videoSources="1"/>
            </resources>
            <library>
                <event name="E" uid="E1">
                    <project name="P" uid="P1">
                        <sequence format="r1" duration="20s" tcStart="0s" tcFormat="NDF">
                            <spine>
                                <asset-clip ref="r2" offset="0s" name="Shot" start="10s" duration="2s" format="r1">
                                    <timeMap>
                                        <timept time="0s" value="0s" interp="smooth2"/>
                                        <timept time="20s" value="100s" interp="smooth2"/>
                                    </timeMap>
                                </asset-clip>
                                <asset-clip ref="r2" offset="5s" name="Shot" start="40s" duration="2s" format="r1">
                                    <timeMap>
                                        <timept time="0s" value="0s" interp="smooth2"/>
                                        <timept time="20s" value="100s" interp="smooth2"/>
                                    </timeMap>
                                </asset-clip>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """)
        
        let rows = try await inventoryRows(from: fcpxml)
        #expect(rows.count == 2)
        #expect(rows[0].sourceIn != rows[1].sourceIn)
        #expect(rows[0].speedChangeSettings.contains("500"))
        #expect(rows[1].speedChangeSettings.contains("500"))
        #expect(rows[0].duplicateFrames == "")
        #expect(rows[1].duplicateFrames == "")
    }
    
    @Test("Retimed clips overlapping in Source In/Out report that overlap, not the map span")
    func retimedClipsOverlappingSourceInReportSliceNotMapSpan() async throws {
        let fcpxml = try parseInlineFCPXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                <asset id="r2" name="Shot" uid="A1" start="0s" duration="120s" hasVideo="1" format="r1" videoSources="1"/>
            </resources>
            <library>
                <event name="E" uid="E1">
                    <project name="P" uid="P1">
                        <sequence format="r1" duration="20s" tcStart="0s" tcFormat="NDF">
                            <spine>
                                <asset-clip ref="r2" offset="0s" name="Shot" start="10s" duration="2s" format="r1">
                                    <timeMap>
                                        <timept time="0s" value="0s" interp="smooth2"/>
                                        <timept time="20s" value="100s" interp="smooth2"/>
                                    </timeMap>
                                </asset-clip>
                                <asset-clip ref="r2" offset="5s" name="Shot" start="12s" duration="2s" format="r1">
                                    <timeMap>
                                        <timept time="0s" value="0s" interp="smooth2"/>
                                        <timept time="20s" value="100s" interp="smooth2"/>
                                    </timeMap>
                                </asset-clip>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """)
        
        let rows = try await inventoryRows(from: fcpxml)
        #expect(rows.count == 2)
        // Source duration is 2s × 5 = 10s (00:00:10:00). Overlap of [10,20) and [12,22) is 8s.
        #expect(rows[0].duplicateFrames == "00:00:08:00")
        #expect(rows[1].duplicateFrames == "00:00:08:00")
        #expect(rows[0].duplicateFrames != rows[0].sourceDuration)
        #expect(!rows[0].duplicateFrames.hasPrefix("00:01:"))
    }
    
    @Test("Stacked same-name clips at the same Timeline In still count as duplicates")
    func stackedSameNameClipsAtSameTimelineInAreDuplicates() async throws {
        let fcpxml = try parseInlineFCPXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                <asset id="r2" name="Stack" uid="A1" start="0s" duration="20s" hasVideo="1" format="r1" videoSources="1"/>
            </resources>
            <library>
                <event name="E" uid="E1">
                    <project name="P" uid="P1">
                        <sequence format="r1" duration="10s" tcStart="0s" tcFormat="NDF">
                            <spine>
                                <asset-clip ref="r2" offset="0s" name="Stack" start="10s" duration="5s" format="r1"/>
                                <asset-clip ref="r2" offset="0s" name="Stack" start="10s" duration="5s" lane="1" format="r1"/>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """)
        
        let rows = try await inventoryRows(from: fcpxml)
        #expect(rows.count == 2)
        #expect(rows[0].sourceIn == rows[1].sourceIn)
        #expect(rows[0].duplicateFrames == "00:00:05:00")
        #expect(rows[1].duplicateFrames == "00:00:05:00")
    }
    
    @Test("A single J-cut clip's video and audio rows are not duplicates of each other")
    func jCutVideoAndAudioRowsAreNotSelfDuplicates() async throws {
        let fcpxml = try parseInlineFCPXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="100/2400s" width="1920" height="1080"/>
                <asset id="r2" name="Solo" uid="A1" start="0s" duration="30s" hasVideo="1" hasAudio="1" format="r1" videoSources="1" audioSources="1"/>
            </resources>
            <library>
                <event name="E" uid="E1">
                    <project name="P" uid="P1">
                        <sequence format="r1" duration="20s" tcStart="0s" tcFormat="NDF">
                            <spine>
                                <asset-clip ref="r2" offset="5s" name="Solo" start="10s" duration="5s" audioStart="8s" audioDuration="8s" format="r1" tcFormat="NDF"/>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """)
        
        let rows = try await inventoryRows(from: fcpxml)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.duplicateFrames.isEmpty })
    }
    
    private func inventoryRows(
        from fcpxml: FinalCutPro.FCPXML
    ) async throws -> [FinalCutPro.FCPXML.RoleClipReportRow] {
        var options = FinalCutPro.FCPXML.ReportOptions.roleInventoryOnly
        options.includeSpeedChangeSettingsInRoleInventory = true
        let report = try await fcpxml.buildReport(options: options)
        return try #require(report.roleInventory?.selectedRoles)
    }
}
