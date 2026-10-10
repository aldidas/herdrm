import AppKit
import HerdrKit
import SwiftUI

/// `[ main | divider | drawer ]` with the drawer on the right.
///
/// Like `SplitContainer`, `main` keeps one structural position: opening the drawer only
/// changes `main`'s trailing padding, never the view tree, so attached terminals are not
/// rebuilt. The drawer keeps its full width while closed (just invisible and inert), so
/// its terminal never sees a zero-column resize.
struct DrawerSplit<Main: View, Drawer: View>: View {
    let isOpen: Bool
    @Binding var ratio: Double
    @ViewBuilder var main: () -> Main
    @ViewBuilder var drawer: () -> Drawer

    /// Ratio when the current drag began; `translation` is a delta.
    @State private var dragStartRatio: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let drawerWidth = total * EditorDrawerLayout.clamp(ratio)
            ZStack(alignment: .trailing) {
                main()
                    .padding(.trailing, isOpen ? drawerWidth + 1 : 0)
                drawer()
                    .frame(width: drawerWidth)
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(isOpen)
                if isOpen {
                    divider(total: total)
                        .padding(.trailing, drawerWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(.clear)
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard total > 0 else { return }
                                let start = dragStartRatio ?? EditorDrawerLayout.clamp(ratio)
                                if dragStartRatio == nil { dragStartRatio = start }
                                // The drawer is on the right: dragging left grows it.
                                ratio = EditorDrawerLayout.clamp(start - value.translation.width / total)
                            }
                            .onEnded { _ in dragStartRatio = nil }
                    )
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
            )
    }
}

/// One kept-alive nvim terminal per drawer session. Hidden drawers stay in the
/// hierarchy (opacity 0, surface hidden) so their nvim — and its buffers — survive.
struct EditorDrawerStack: View {
    @ObservedObject var model: AppModel
    @AppStorage(TerminalDefaults.fontNameKey) private var fontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var thinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var fontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var lineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage(TerminalThemeSetting.key) private var themeName = ""
    @AppStorage("terminal.mouseReporting") private var mouseReporting = true
    @AppStorage("terminal.copyOnSelect") private var copyOnSelect = true
    @Environment(\.colorScheme) private var colorScheme

    /// The user's captured login environment (PATH, SHELL, …), like the SSH terminal
    /// command uses: the app's own launch environment is too sparse to find nvim.
    private var baseEnvironment: [String: String] {
        var environment = (ShellEnvironment.cached ?? .empty).launchEnvironment(binary: nil)
        for key in ["TERM", "COLUMNS", "LINES"] { environment.removeValue(forKey: key) }
        return environment
    }

    var body: some View {
        ZStack {
            ForEach(model.editorDrawers.all) { session in
                let visible = model.visibleEditorDrawerID == session.id
                ShellTerminalView(
                    sessionID: session.id,
                    fontName: fontName,
                    fontSize: fontSize,
                    thinStrokes: thinStrokes,
                    fontWeight: fontWeight,
                    lineSpacing: lineSpacing,
                    dark: colorScheme == .dark,
                    themeName: themeName,
                    mouseReporting: mouseReporting,
                    copyOnSelect: copyOnSelect,
                    isVisible: visible,
                    onExit: { code in model.editorDrawerExited(session.id, code: code) },
                    command: NvimCommand.launch(
                        directory: session.directory,
                        socketPath: session.socketPath,
                        file: session.initialFile,
                        baseEnvironment: baseEnvironment
                    )
                )
                // Stable id, not keyed on colorScheme: a new id would kill nvim.
                .id("drawer-\(session.id)")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.terminalBackground)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
            }
        }
        .background(Theme.terminalBackground)
    }
}
