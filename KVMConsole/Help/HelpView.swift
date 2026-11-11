import SwiftUI

/// The KVM Console Help window: topics in the sidebar, searchable, and the
/// selected topic on the right.
struct HelpView: View {
    @Bindable private var help = HelpCenter.shared

    private var topics: [HelpTopic] { HelpTopic.search(help.searchText) }

    var body: some View {
        NavigationSplitView {
            List(topics, selection: $help.selection) { topic in
                Label(topic.title, systemImage: topic.symbol)
                    .tag(topic.id)
            }
            .overlay {
                if topics.isEmpty {
                    ContentUnavailableView.search(text: help.searchText)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let id = help.selection, let topic = HelpTopic.topic(id) {
                HelpTopicView(topic: topic)
                    .id(topic.id)
            } else {
                ContentUnavailableView("Choose a Topic", systemImage: "questionmark.circle")
            }
        }
        .searchable(text: $help.searchText, placement: .sidebar, prompt: "Search Help")
        .onChange(of: help.searchText) {
            // Keep the detail pane on a topic that matches the search.
            let matches = topics
            if let first = matches.first, !matches.contains(where: { $0.id == help.selection }) {
                help.selection = first.id
            }
        }
        // Links between topics use help:<topic-id>.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == HelpTopic.linkScheme else { return .systemAction }
            let id = url.absoluteString.dropFirst(HelpTopic.linkScheme.count + 1)
            help.show(String(id))
            return .handled
        })
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .navigationTitle(topic.title)
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text).font(.title2.bold()).padding(.top, 10)
        case .paragraph(let text):
            inline(text)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item)
                    }
                }
            }
        case .steps(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inline(item)
                    }
                }
            }
        case .note(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(.tint)
                inline(text)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .shortcuts(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.keys)
                            .font(.body.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            .gridColumnAlignment(.trailing)
                        inline(row.action)
                    }
                }
            }
        }
    }

    private func inline(_ markdown: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        return Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
