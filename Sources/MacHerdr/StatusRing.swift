import HerdrKit
import SwiftUI

/// herdr's status dot: an outline ring when idle, a spinner while working,
/// a filled amber disc when blocked, a green ring when done (filled blue
/// while the finish is still unread).
struct StatusRing: View {
    let status: AgentStatus
    var unreadDone: Bool = false
    var size: CGFloat = 11

    var body: some View {
        Group {
            switch status {
            case .working:
                SpinnerView(color: Theme.working)
            case .blocked:
                Circle().fill(Theme.warning)
            case .done where unreadDone:
                Circle().fill(Theme.working)
            case .done:
                Circle().strokeBorder(Theme.success, lineWidth: 1.4)
            case .idle, .unknown:
                Circle().strokeBorder(Theme.textGhost, lineWidth: 1.4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
