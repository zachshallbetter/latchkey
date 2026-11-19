import LatchkeyCore
import SwiftUI

/// What changed in this version, from the CHANGELOG.md bundled with the app: shown once after each update, and from
/// **Latchkey › What's New in Latchkey…** and Settings › About. Earlier versions fold below it.
struct WhatsNewView: View {
    static let changelogPage = URL(string: "https://latchkey.snackstud.io/changelog.html")!

    /// The bundled changelog, read once.
    static let notes: ReleaseNotes? = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map(ReleaseNotes.init(markdown:))

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    @Environment(\.dismiss) private var dismiss
    @State private var showEarlier = false

    private var releases: [ReleaseNotes.Release] { (Self.notes?.releases ?? []).filter { $0.version != "Unreleased" } }
    private var current: ReleaseNotes.Release? { Self.notes?.release(Self.version) ?? releases.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in Latchkey \(current?.version ?? Self.version)").font(.title3.weight(.semibold))
                    if let date = current?.date { Text(date).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let current {
                        ReleaseBody(release: current)
                    } else {
                        Text("Release notes aren't included in this build.").foregroundStyle(.secondary)
                    }
                    let earlier = releases.filter { $0.version != current?.version }
                    if !earlier.isEmpty {
                        DisclosureGroup("Earlier versions", isExpanded: $showEarlier) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(earlier, id: \.version) { r in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("\(r.version)\(r.date.map { "  ·  \($0)" } ?? "")").font(.headline)
                                        ReleaseBody(release: r)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Link("Full Changelog", destination: Self.changelogPage)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .focusEffectDisabled()
    }
}

/// One release's sections, each a short list. Items are Markdown with inline code and bold, as CHANGELOG.md writes them.
private struct ReleaseBody: View {
    let release: ReleaseNotes.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(release.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(Self.inline(item)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
