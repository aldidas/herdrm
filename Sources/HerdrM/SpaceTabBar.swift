import HerdrKit
import SwiftUI

/// Tabs of the selected space, mirroring herdr's TUI tab strip.
struct SpaceTabBar: View {
    @ObservedObject var model: AppModel
    let space: SpaceRef
    @State private var renaming: TabInfo?
    @State private var renameText = ""

    var body: some View {
        let tabs = model.tabs(in: space)
        let active = model.activeTabID(in: space)
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabCell(tab, selected: tab.tabID == active, canClose: tabs.count > 1)
            }
            Button {
                model.newTab(in: space)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab")
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .background(Theme.statusBarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .alert("Rename Tab", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func tabCell(_ tab: TabInfo, selected: Bool, canClose: Bool) -> some View {
        HStack(spacing: 6) {
            StatusRing(status: AgentStatus(wire: tab.agentStatusRaw), size: 9)
            Text(tab.customLabel ?? tab.label)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
            if canClose {
                Button {
                    model.requestCloseTab(tab, deviceID: space.deviceID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(selected ? Theme.terminalBackground : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            renameText = tab.customLabel ?? tab.label
            renaming = tab
        }
        .onTapGesture { model.selectTab(tab, deviceID: space.deviceID) }
    }

    private func commitRename() {
        guard let tab = renaming else { return }
        let label = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !label.isEmpty, let device = model.device(space.deviceID) else { return }
        let service = model.service(for: device)
        Task { @MainActor in
            do { try await service.renameTab(tabID: tab.tabID, label: label) } catch {
                model.actionError = error.localizedDescription
            }
        }
    }
}
