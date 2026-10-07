import HerdrKit
import SwiftUI

/// Tabs of the selected space, mirroring herdr's TUI tab strip.
struct SpaceTabBar: View {
    @ObservedObject var model: AppModel
    let space: SpaceRef
    @State private var renameText = ""
    @State private var draggingTabID: String?
    @State private var tabDrop: (id: String, after: Bool)?

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
        .onChange(of: model.tabToRename) { _, tab in
            if let tab { renameText = tab.customLabel ?? tab.label }
        }
        .alert("Rename Tab", isPresented: Binding(
            get: { model.tabToRename != nil },
            set: { if !$0 { model.tabToRename = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { model.tabToRename = nil }
        }
    }

    private func tabCell(_ tab: TabInfo, selected: Bool, canClose: Bool) -> some View {
        HStack(spacing: 6) {
            StatusRing(status: AgentStatus(wire: tab.agentStatusRaw), size: 9)
            Text(tab.customLabel ?? tab.label)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
            // Reserves the close button's slot; the real button sits above the drag host.
            if canClose { Color.clear.frame(width: 9, height: 9) }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(selected ? Theme.terminalBackground : Color.clear)
        .opacity(draggingTabID == tab.tabID ? 0.4 : 1)
        .overlay(alignment: (tabDrop?.after ?? false) ? .trailing : .leading) {
            if tabDrop?.id == tab.tabID {
                Rectangle().fill(Theme.accent).frame(width: 2)
                    .transaction { $0.animation = nil }
            }
        }
        // AppKit host: click selects, double-click renames, a few points of movement
        // start a drag (SwiftUI gestures and .onDrag fight over mouseDown on macOS).
        .overlay {
            SidebarRowDragHost(
                entryID: tab.tabID,
                pasteboardType: SidebarRowDragNSView.tabPasteboardType,
                menuItems: menuItems(for: tab, canClose: canClose),
                onClick: { model.selectTab(tab, deviceID: space.deviceID) },
                onDoubleClick: { model.tabToRename = tab },
                allowsDrag: canClose,
                horizontal: true,
                onDragStart: { draggingTabID = $0 },
                onDragEnd: {
                    draggingTabID = nil
                    tabDrop = nil
                },
                onDropHover: { after in tabDrop = (tab.tabID, after) },
                onHoverExit: { if tabDrop?.id == tab.tabID { tabDrop = nil } },
                onDrop: { sourceID, after in
                    draggingTabID = nil
                    tabDrop = nil
                    guard sourceID != tab.tabID else { return }
                    model.moveTab(sourceID, onto: tab.tabID, in: space, placeAfter: after)
                }
            )
        }
        .overlay(alignment: .trailing) {
            if canClose {
                Button {
                    model.requestCloseTab(tab, deviceID: space.deviceID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 7)
                .help("Close Tab")
            }
        }
    }

    private func menuItems(for tab: TabInfo, canClose: Bool) -> [SidebarContextMenuItem] {
        var items: [SidebarContextMenuItem] = [
            .item(title: String(localized: "Rename Tab…"), action: { model.tabToRename = tab }),
        ]
        if canClose {
            items.append(.separator)
            items.append(.destructive(title: String(localized: "Close Tab"), action: {
                model.requestCloseTab(tab, deviceID: space.deviceID)
            }))
        }
        return items
    }

    private func commitRename() {
        guard let tab = model.tabToRename else { return }
        let label = renameText.trimmingCharacters(in: .whitespaces)
        model.tabToRename = nil
        guard !label.isEmpty, let device = model.device(space.deviceID) else { return }
        let service = model.service(for: device)
        Task { @MainActor in
            do { try await service.renameTab(tabID: tab.tabID, label: label) } catch {
                model.actionError = error.localizedDescription
            }
        }
    }
}
