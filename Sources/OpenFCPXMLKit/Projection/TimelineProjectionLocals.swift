//
// TimelineProjectionLocals.swift
// OpenFCPXMLKit • https://github.com/TheAcharya/OpenFCPXMLKit
// © 2026 • Licensed under MIT License
//


//
//	Task-local sink for clip marker/keyword annotations during a projection walk.
//

import Foundation

extension FinalCutPro.FCPXML {
    /// Collects ``ProjectedClipAnnotations`` without threading callbacks through every walk.
    final class ClipAnnotationCollector: @unchecked Sendable {
        private(set) var items: [ProjectedClipAnnotations] = []

        func append(_ item: ProjectedClipAnnotations) {
            items.append(item)
        }
    }

    /// Collects structural projection failures while building a restoration graph.
    ///
    /// The ordinary projector remains fail-fast. Graph construction installs this
    /// task-local collector so one unsupported subtree becomes an explicit issue
    /// without hiding the rest of the selected Project closure.
    final class ProjectRestorationDiagnosticCollector: @unchecked Sendable {
        private(set) var issues: [ProjectRestorationIssue] = []

        func append(_ issue: ProjectRestorationIssue) {
            issues.append(issue)
        }
    }

    enum TimelineProjectionLocals {
        @TaskLocal static var clipAnnotationCollector: ClipAnnotationCollector?
        @TaskLocal static var restorationDiagnosticCollector: ProjectRestorationDiagnosticCollector?
    }
}
