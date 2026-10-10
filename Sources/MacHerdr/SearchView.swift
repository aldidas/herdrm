import HerdrKit
import SwiftUI

/// Command-palette style search over agents, terminals, and spaces across all devices (⌘K).
struct SearchSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @State private var fileHits: [RepoFileHit] = []
    @State private var fileRoot = ""
    @State private var tab: SearchTab

    init(model: AppModel) {
        self.model = model
        _tab = State(initialValue: model.fileSearchTarget == nil ? .agents : .files)
    }

    enum SearchTab: Int, CaseIterable, Identifiable {
        case files = 1, terminals, agents, spaces

        var id: Int { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .files: return "Files"
            case .terminals: return "Terminals"
            case .agents: return "Agents"
            case .spaces: return "Spaces"
            }
        }

        var placeholder: LocalizedStringKey {
            switch self {
            case .files: return "Search files…"
            case .terminals: return "Search terminals…"
            case .agents: return "Search agents…"
            case .spaces: return "Search spaces…"
            }
        }
    }
    @FocusState private var fieldFocused: Bool

    enum Result: Identifiable {
        case agent(AppModel.AgentEntry)
        case terminal(AppModel.TerminalEntry)
        case space(AppModel.SpaceEntry)
        case file(RepoFileHit)

        var tab: SearchTab {
            switch self {
            case .agent: return .agents
            case .terminal: return .terminals
            case .space: return .spaces
            case .file: return .files
            }
        }

        var id: String {
            switch self {
            case .agent(let entry): return "agent-\(entry.id)"
            case .terminal(let entry): return "terminal-\(entry.id)"
            case .space(let entry): return "space-\(entry.id)"
            case .file(let hit): return "file-\(hit.id)"
            }
        }
    }

    private var results: [Result] { allResults.filter { $0.tab == tab } }

    private var allResults: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let agents = model.devices.flatMap { device in
            model.session(device.id).agents.map { model.agentEntry(device: device, agent: $0) }
        }.filter { entry in
            q.isEmpty
                || entry.title.lowercased().contains(q)
                || entry.agent.title.lowercased().contains(q)
                || entry.agent.agent.lowercased().contains(q)
                || (entry.agent.name?.lowercased().contains(q) ?? false)
                || (entry.tabLabel?.lowercased().contains(q) ?? false)
                || (entry.agent.terminalTitleStripped ?? entry.agent.terminalTitle)?
                    .lowercased().contains(q) == true
                || entry.device.name.lowercased().contains(q)
                || model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID)
                    .lowercased().contains(q)
        }
        let spaces = model.devices.flatMap { device in
            model.session(device.id).workspaces.map { AppModel.SpaceEntry(device: device, workspace: $0) }
        }.filter { entry in
            q.isEmpty
                || entry.workspace.label.lowercased().contains(q)
                || entry.device.name.lowercased().contains(q)
        }
        let terminals = model.devices.flatMap { model.terminalEntries(for: $0) }.filter { entry in
            q.isEmpty
                || entry.title.lowercased().contains(q)
                || (entry.pane.cwd?.lowercased().contains(q) ?? false)
                || (entry.tab?.label.lowercased().contains(q) ?? false)
                || entry.device.name.lowercased().contains(q)
                || model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID)
                    .lowercased().contains(q)
        }
        // Sidebar follows herdr tab order so drag-reorder sticks. ⌘K still
        // ranks by urgency: needs input, unread, working, then the rest.
        let ranked = agents.sorted {
            let r0 = searchRank($0)
            let r1 = searchRank($1)
            if r0 != r1 { return r0 < r1 }
            return ($0.agent.revision ?? 0) > ($1.agent.revision ?? 0)
        }
        return ranked.map(Result.agent) + terminals.map(Result.terminal) + spaces.map(Result.space)
            + fileHits.map(Result.file)
    }

    private func searchRank(_ entry: AppModel.AgentEntry) -> Int {
        switch entry.agent.status {
        case .blocked: return 0
        case .done where model.isUnread(entry): return 1
        case .working: return 2
        case .done: return 3
        case .idle: return 4
        case .unknown: return 5
        }
    }

    private static let resultsHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                TextField(tab.placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .onSubmit { chooseHighlighted() }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            tabBar

            Rectangle().fill(Theme.hairline).frame(height: 1)

            // Fixed height, content pinned to the top: a sheet sized to its content
            // is re-centered by the system whenever the result list shrinks, so
            // the whole sheet would jump while typing.
            ZStack(alignment: .top) {
                if results.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 1) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                    row(result, isHighlighted: index == highlighted)
                                        .onTapGesture { choose(result) }
                                        .onHover { if $0 { highlighted = index } }
                                }
                            }
                            .padding(8)
                        }
                        // anchor: nil moves the minimum to reveal the row — a no-op when it
                        // is already visible, so hovering never yanks the scroll position.
                        .onChange(of: highlighted) { _, index in
                            guard results.indices.contains(index) else { return }
                            proxy.scrollTo(results[index].id, anchor: nil)
                        }
                        // Reopening ⌘K starts at the top even if the sheet was left
                        // scrolled to the bottom.
                        .onAppear {
                            if let first = results.first { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
            }
            .frame(height: Self.resultsHeight, alignment: .top)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack(spacing: 12) {
                hint("↑↓", "navigate")
                hint("↩", "open")
                Spacer()
                hint("esc", "cancel")
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(width: 480)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onChange(of: tab) { _, _ in highlighted = 0 }
        .task(id: query) { await loadFiles() }
    }

    /// Files for the current space: changed files on an empty query, fuzzy matches
    /// otherwise. Keystrokes cancel the previous task, so a stale result never lands.
    private func loadFiles() async {
        guard let target = model.fileSearchTarget else {
            fileHits = []
            return
        }
        let found = await model.repoFiles.hits(query: query, directory: target.directory)
        guard !Task.isCancelled else { return }
        fileRoot = found?.root ?? ""
        fileHits = found?.hits ?? []
    }

    private var tabBar: some View {
        let counts = Dictionary(grouping: allResults, by: \.tab).mapValues(\.count)
        return HStack(spacing: 2) {
            ForEach(SearchTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 12, weight: item == tab ? .medium : .regular))
                        if let count = counts[item], count > 0 {
                            Text("\(count)").font(.system(size: 10.5)).foregroundStyle(Theme.textGhost)
                        }
                        Text("⌘\(item.rawValue)").font(.system(size: 10)).foregroundStyle(Theme.textGhost)
                    }
                    .foregroundStyle(item == tab ? Theme.text : Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(item == tab ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(item.rawValue)")), modifiers: .command)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textGhost)
        }
    }

    @ViewBuilder
    private func row(_ result: Result, isHighlighted: Bool) -> some View {
        HStack(spacing: 9) {
            switch result {
            case .agent(let entry):
                if let resource = BrandIconLoader.agentIcon(for: entry.agent.agent) {
                    BrandIcon(resource: resource, size: 13)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                }
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                AgentStatusGlyph(status: entry.agent.status, unreadDone: model.isUnread(entry))
                Spacer(minLength: 8)
                if entry.agent.status == .blocked {
                    Text("needs input")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                }
                trailing(
                    "\(entry.agent.agent) · \(model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID))",
                    device: entry.device
                )
            case .terminal(let entry):
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing(
                    String(localized: "Terminal · \(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))"),
                    device: entry.device
                )
            case .space(let entry):
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(entry.workspace.label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing(String(localized: "Space · \(model.agentCount(in: entry)) agents"), device: entry.device)
            case .file(let hit):
                Image(systemName: hit.isChanged ? "doc.badge.ellipsis" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text((hit.path as NSString).lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text((hit.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                if let added = hit.added, let deleted = hit.deleted {
                    Text("+\(added) −\(deleted)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                } else if hit.isChanged {
                    Text("new")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailing(_ text: String, device: Device) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            if model.showsDeviceBadges {
                DeviceChip(device: device)
            }
        }
    }

    private func chooseHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        choose(results[highlighted])
    }

    private func choose(_ result: Result) {
        switch result {
        case .agent(let entry):
            model.reveal(entry.ref)
        case .terminal(let entry):
            model.reveal(entry.ref)
        case .space(let entry):
            if let filter = model.deviceFilter, filter != entry.device.id {
                model.setDeviceFilter(nil)
            }
            model.selectSpace(entry.ref)
        case .file(let hit):
            if let target = model.fileSearchTarget {
                model.openFile(path: fileRoot + "/" + hit.path, in: target.space, directory: target.directory)
            }
        }
        dismiss()
    }
}
