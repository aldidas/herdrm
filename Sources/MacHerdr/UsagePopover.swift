import HerdrKit
import SwiftUI

/// What the titlebar info button shows for the selected agent or terminal.
struct TitlebarInfo {
    let agentKind: String?
    let title: String
    let spaceName: String
    let device: Device
    let status: AgentStatus?
    let cwd: String?
    let usage: AgentUsage?
}

/// The info panel opened from the titlebar's trailing button: the entry's
/// details, then one progress bar per window the agent's plugin publishes
/// (5h, 7d, …) and the context fill. In-window like `DevicePopover`, since
/// NSPopover is unreliable on macOS 26.
struct UsagePopover: View {
    let info: TitlebarInfo
    let showsDevice: Bool

    private var statusLabel: (text: String, status: AgentStatus)? {
        guard let status = info.status else { return nil }
        switch status {
        case .working: return (String(localized: "Working"), status)
        case .blocked: return (String(localized: "Needs input"), status)
        case .done: return (String(localized: "Done"), status)
        case .idle: return (String(localized: "Idle"), status)
        case .unknown: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            details
            Divider()
            usageSection
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(info.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let label = statusLabel {
                    Text(label.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.statusColor(label.status))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Theme.statusColor(label.status).opacity(0.13), in: Capsule())
                }
            }
            HStack(spacing: 6) {
                if let kind = info.agentKind { AgentKindBadge(kind: kind) }
                Text("\u{b7}").foregroundStyle(Theme.textGhost)
                Text(info.spaceName)
                    .lineLimit(1)
                if showsDevice { DeviceChip(device: info.device) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            if let cwd = info.cwd, !cwd.isEmpty {
                Text((cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("USAGE")
                    .font(.system(size: 10.5, weight: .medium))
                    .kerning(0.3)
                    .foregroundStyle(Theme.textTertiary)
                if let usage = info.usage {
                    if let account = usage.account {
                        Text(account)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.statsAccount)
                    }
                    if let model = usage.model {
                        Text(model)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("No usage reported")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if let usage = info.usage {
                ForEach(usage.windows, id: \.label) { UsageBar(window: $0) }
                if let context = usage.context { UsageBar(window: context) }
            }
        }
    }
}

private struct UsageBar: View {
    let window: UsageWindow

    private var tint: Color {
        switch window.percent {
        case 90...: return Theme.danger
        case 70...: return Theme.warning
        default: return Theme.working
        }
    }

    private var accessibilityText: String {
        var text = "\(window.title) \(Int(window.percent.rounded()))% used"
        if let reset = window.resetsIn { text += ", resets in \(reset)" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(Int(window.percent.rounded()))% used")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.itemWash)
                    Capsule().fill(tint).frame(width: max(4, proxy.size.width * window.percent / 100))
                }
            }
            .frame(height: 6)
            if let reset = window.resetsIn {
                Text("resets in \(reset)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
