//
//  LanePath.swift
//  OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
//  © 2026 • Licensed under MIT License
//


//
//	Nested storyline lane path for timeline projection.
//

import Foundation

extension FinalCutPro.FCPXML {
    /// Ordered nest of storyline lanes from the outermost sequence to a media usage site.
    ///
    /// An empty path is the primary spine. Secondary storylines append lane numbers
    /// outermost-first (for example `[1]` then `[1, -1]` for a nested secondary lane).
    public struct LanePath: Hashable, Sendable, Equatable {
        /// Nested lane numbers, outermost first.
        public var components: [Int]

        /// Primary spine (no nested lanes).
        public static let primary = LanePath(components: [])

        public init(components: [Int] = []) {
            self.components = components
        }

        /// Returns a path with a connected lane appended; omitted and explicit lane `0`
        /// both remain on the primary storyline.
        public func appending(_ lane: Int?) -> LanePath {
            guard let lane, lane != 0 else { return self }
            return LanePath(components: components + [lane])
        }
    }
}
