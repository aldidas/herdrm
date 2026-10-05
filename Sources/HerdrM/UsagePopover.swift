import HerdrKit
import SwiftUI

/// The usage panel opened from the titlebar's agent badge: one progress bar
/// per window the agent's plugin publishes (5h, 7d, …) and the context fill.
/// In-window like `DevicePopover`, since NSPopover is unreliable on macOS 26.
struct UsagePopover: View {
    let agentKind: String
    let usage: AgentUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("USAGE")
                    .font(.system(size: 10.5, weight: .medium))
                    .kerning(0.3)
                    .foregroundStyle(Theme.textTertiary)
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
            }
            ForEach(usage.windows, id: \.label) { UsageBar(window: $0) }
            if let context = usage.context { UsageBar(window: context) }
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
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
        var text = "\(window.title) \(Int(window.percent.rounded()))%"
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
                Text("\(Int(window.percent.rounded()))%")
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
