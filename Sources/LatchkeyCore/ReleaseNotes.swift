import Foundation

/// `CHANGELOG.md`, read into releases: the app's What's New window and the update feed show a release from it.
/// The file's shape: `## VERSION (DATE)` (or `## Unreleased`) per release, `### Title` per section, and `- ` items whose
/// continuation lines are indented. Anything else (the `# Changelog` title, prose between headings) is skipped.
public struct ReleaseNotes: Sendable, Equatable {
    public struct Release: Sendable, Equatable {
        /// `0.4.0`, or `Unreleased`.
        public var version: String
        /// `2026-11-18`, when the heading has one.
        public var date: String?
        public var sections: [Section]
    }

    public struct Section: Sendable, Equatable {
        public var title: String
        /// Each item as one line of Markdown (its continuation lines joined with spaces).
        public var items: [String]
    }

    /// Newest first, as the file lists them.
    public var releases: [Release]

    public init(markdown: String) {
        var releases: [Release] = []
        var item: String?
        func endItem() {
            guard let text = item else { return }
            item = nil
            guard !releases.isEmpty, !releases[releases.count - 1].sections.isEmpty else { return }
            releases[releases.count - 1].sections[releases[releases.count - 1].sections.count - 1].items.append(text)
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## ") {
                endItem()
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if let open = heading.firstIndex(of: "("), heading.hasSuffix(")") {
                    releases.append(Release(version: heading[..<open].trimmingCharacters(in: .whitespaces),
                                            date: String(heading[heading.index(after: open)..<heading.index(before: heading.endIndex)]),
                                            sections: []))
                } else {
                    releases.append(Release(version: heading, date: nil, sections: []))
                }
            } else if line.hasPrefix("### ") {
                endItem()
                guard !releases.isEmpty else { continue }
                releases[releases.count - 1].sections.append(Section(title: line.dropFirst(4).trimmingCharacters(in: .whitespaces), items: []))
            } else if line.hasPrefix("- ") {
                endItem()
                item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("  "), let text = item {
                item = text + " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                endItem()
            }
        }
        endItem()
        self.releases = releases
    }

    /// The release with this version, if the file has it.
    public func release(_ version: String) -> Release? { releases.first { $0.version == version } }
}
