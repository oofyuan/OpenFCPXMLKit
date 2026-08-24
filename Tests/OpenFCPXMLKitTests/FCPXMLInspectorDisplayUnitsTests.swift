//
//  FCPXMLInspectorDisplayUnitsTests.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//

//
//	Locks report Settings to Final Cut Pro Inspector units.
//

import Testing
@testable import OpenFCPXMLKit

@Suite("Inspector display units")
struct FCPXMLInspectorDisplayUnitsTests {
    private typealias EffectsCollector = FinalCutPro.FCPXML.EffectsCollector
    private typealias ExtractedElement = FinalCutPro.FCPXML.ExtractedElement
    private typealias ExtractedEffect = FinalCutPro.FCPXML.ExtractedEffect
    private typealias ReportFormatting = FinalCutPro.FCPXML.ReportFormatting
    private typealias TransformAdjustment = FinalCutPro.FCPXML.TransformAdjustment

    @Test("Built-in Inspector settings match FCP pixel, percent, and degree display")
    func builtInInspectorSettingsMatchFCPDisplay() async throws {
        let fcpxml = try parseInlineFCPXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="100/2400s" width="2048" height="930"/>
                <format id="r3" name="FFVideoFormat2048x1152p24" frameDuration="100/2400s" width="2048" height="1152"/>
                <asset id="r2" name="Shot" uid="A1" start="0s" duration="10s" hasVideo="1" format="r3" videoSources="1"/>
            </resources>
            <library>
                <event name="E" uid="E1">
                    <project name="P" uid="P1">
                        <sequence format="r1" duration="10s" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
                                <asset-clip ref="r2" offset="0s" name="Inspector Clip" duration="5s" format="r3">
                                    <adjust-conform type="fill"/>
                                    <adjust-blend amount="0.3987" mode="colorDodge"/>
                                    <adjust-transform position="-8.84241 -14.0753" scale="1.28 1.28" rotation="12.5"/>
                                    <adjust-volume amount="-3dB"/>
                                </asset-clip>
                                <asset-clip ref="r2" offset="5s" name="Keyed Clip" duration="5s" format="r3">
                                    <adjust-transform>
                                        <param name="position">
                                            <keyframeAnimation>
                                                <keyframe time="0s" value="-8.84241 -14.0753"/>
                                                <keyframe time="5s" value="-91.3978 40.8602"/>
                                            </keyframeAnimation>
                                        </param>
                                    </adjust-transform>
                                    <filter-video name="Draw Mask">
                                        <param name="Position" value="217.606 46.7851"/>
                                    </filter-video>
                                </asset-clip>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """)

        var options = FinalCutPro.FCPXML.ReportOptions.roleInventoryOnly
        options.includeEffects = true
        let report = try await fcpxml.buildReport(options: options)
        let rows = try #require(report.effects?.rows)
        let inspectorRows = rows.filter { $0.clipName == "Inspector Clip" }
        let keyedRows = rows.filter { $0.clipName == "Keyed Clip" }

        #expect(inspectorRows.contains { $0.effect == "Spatial Conform" && $0.settings == "Fill" })
        #expect(inspectorRows.contains { $0.settings == "Opacity 39.9%" })
        #expect(inspectorRows.contains { $0.settings == "Blend Mode Color Dodge" })
        #expect(inspectorRows.contains { $0.settings == "Position -82.2 px, -130.9 px" })
        #expect(inspectorRows.contains { $0.settings == "Scale 128.0%" })
        #expect(inspectorRows.contains { $0.settings == "Rotation 12.5°" })
        #expect(inspectorRows.contains { $0.effect == "volume" && $0.settings == "-3.0 dB" })
        #expect(!inspectorRows.contains { $0.settings.contains("Position -8.8") })

        #expect(keyedRows.contains { $0.settings == "Position -82.2 px, -130.9 px" })
        #expect(keyedRows.contains { $0.settings == "Position -850.0 px, 380.0 px" })
        #expect(keyedRows.contains { $0.effect == "Draw Mask" && $0.settings.contains("217.606 46.7851") })
        #expect(!keyedRows.contains { $0.effect == "Draw Mask" && $0.settings.contains("px") })

        let inventory = try #require(
            report.roleInventory?.selectedRoles.first { $0.clipName == "Inspector Clip" }
        )
        #expect(inventory.effects.contains("Position -82.2 px, -130.9 px"))
        #expect(inventory.effects.contains("Scale 128.0%"))
        #expect(inventory.effects.contains("Opacity 39.9%"))
    }

    @Test("Collector converts keyframed transform position with sequence height")
    func collectorConvertsKeyframedTransformPositionWithSequenceHeight() throws {
        let fcpxml = try parseInlineFCPXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="100/2400s" width="2048" height="930"/>
            </resources>
            <library>
                <event name="E" uid="E1">
                    <project name="P" uid="P1">
                        <sequence format="r1" duration="5s" tcStart="0s" tcFormat="NDF">
                            <spine>
                                <asset-clip offset="0s" name="Clip" duration="5s" format="r1">
                                    <adjust-transform>
                                        <param name="position">
                                            <keyframeAnimation>
                                                <keyframe time="0s" value="-8.84241 -14.0753"/>
                                            </keyframeAnimation>
                                        </param>
                                    </adjust-transform>
                                </asset-clip>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """)

        let element = try #require(firstDescendantElement(in: fcpxml.root.element, named: "asset-clip"))
        let host = ExtractedElement(
            element: element,
            breadcrumbs: [],
            resources: fcpxml.root.resources
        )
        let transforms = EffectsCollector.effects(on: host).filter { $0.kind == .transform }
        let position = try #require(transforms.first)
        if case .transformCenter(let point) = position.settings {
            #expect(abs(point.x - (-82.234413)) < 0.001)
            #expect(abs(point.y - (-130.90029)) < 0.001)
        } else {
            Issue.record("Expected converted Inspector pixels from keyframed position")
        }
        #expect(ReportFormatting.effectSettingsDisplay(for: position) == "Position -82.2 px, -130.9 px")
    }

    @Test("Draw Mask Position param is not treated as adjust-transform sequence-height units")
    func drawMaskPositionParamIsNotConvertedAsAdjustTransform() throws {
        let xml = FinalCutPro.FCPXML.Point(x: 217.606, y: 46.7851)
        let ifMisconverted = TransformAdjustment.inspectorPixels(
            fromXMLPosition: xml,
            sequenceHeight: 930
        )
        #expect(abs(ifMisconverted.x - 2023.7358) < 0.01)

        let formatted = ReportFormatting.effectSettingsDisplay(
            for: .namedValues([.init(name: "Position", value: "217.606 46.7851")])
        )
        #expect(formatted == "Position 217.606 46.7851")
        #expect(!formatted.contains("px"))
    }
}
