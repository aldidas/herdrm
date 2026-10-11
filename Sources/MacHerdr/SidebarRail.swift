import HerdrKit
import SwiftUI

/// What is left of the sidebar when it is collapsed, as in herdr's TUI: a
/// narrow strip of numbered status rings. Spaces on top, then every agent in
/// scope (as the sidebar's Agents section lists them). Clicking a row selects it without expanding.
struct SidebarRail: View {
    static let width: CGFloat = 36

    @ObservedObject var model: AppModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TitlebarMetrics.height + 8)
                .windowTitlebarInteraction()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(model.visibleSpaces.enumerated()), id: \.element.id) { index, entry in
                        spaceRow(index: index, entry: entry)
                    }
                    let agents = model.agentsInScope
                    if !agents.isEmpty {
                        Rectangle()
                            .fill(Theme.sidebarBorder)
                            .frame(height: 1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                        ForEach(Array(agents.enumerated()), id: \.element.id) { index, entry in
                            agentRow(index: index, entry: entry)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        .background(Theme.sidebarBackground.ignoresSafeArea())
        .accessibilityIdentifier("sidebar.rail")
    }

    private func spaceRow(index: Int, entry: AppModel.SpaceEntry) -> some View {
        let ring = model.attention(in: entry).ring
        return railRow(
            number: index + 1,
            selected: model.selectedSpace == entry.ref,
            help: entry.workspace.label,
            id: "sidebar.rail.space.\(index + 1)"
        ) {
            StatusRing(status: ring.status, unreadDone: ring.unreadDone, size: 10)
        } action: {
            model.selectSpace(entry.ref)
        }
    }

    private func agentRow(index: Int, entry: AppModel.AgentEntry) -> some View {
        let selected = !model.isFileManagerActive
            && model.selectedPane == entry.ref
            && model.selectedShellID == nil
        return railRow(
            number: index + 1,
            selected: selected,
            help: entry.title,
            id: "sidebar.rail.agent.\(index + 1)"
        ) {
            StatusRing(status: entry.agent.status, unreadDone: model.isUnread(entry), size: 10)
        } action: {
            model.selectAgent(entry.ref)
        }
    }

    private func railRow<Ring: View>(
        number: Int,
        selected: Bool,
        help: String,
        id: String,
        @ViewBuilder ring: () -> Ring,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("\(number)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(selected ? Theme.text : Theme.textTertiary)
                    .frame(minWidth: 9, alignment: .trailing)
                ring()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(id)
        .accessibilityLabel(help)
    }
}
