import AppKit
import HerdrKit
import SwiftUI
import WebKit

/// A rendered preview (markdown + mermaid, or a plain HTML file) shown in the same
/// drawer slot as the nvim drawer. One per herdr tab.
struct PreviewSession: Identifiable, Equatable {
    let id = UUID()
    let key: EditorDrawerKey
    var path: String
    var isVisible: Bool
    /// Fills the whole detail area (and hides the sidebar); the terminal underneath keeps its size.
    var isZoomed = false

    /// Extensions ⌘K routes to the preview instead of nvim.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    static let htmlExtensions: Set<String> = ["html", "htm"]

    static func handles(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext) || htmlExtensions.contains(ext)
    }
}

/// Page zoom shared by every preview, persisted; driven by the Terminal menu (⌘+ ⌘− ⌘0).
enum PreviewZoom {
    static let key = "preview.zoom"
    static let `default` = 1.0
    static let range = 0.5...3.0

    /// True when the key window's focus is inside a preview web view, which is how
    /// ⌘+/−/0 are told apart from the terminal's own font-size bindings.
    static var previewHasFocus: Bool {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if current is WKWebView { return true }
            responder = current.nextResponder
        }
        return false
    }

    static func step(by delta: Double) {
        guard previewHasFocus else { return }
        let current = UserDefaults.standard.object(forKey: key) as? Double ?? `default`
        let next = ((current + delta) * 100).rounded() / 100
        UserDefaults.standard.set(min(max(next, range.lowerBound), range.upperBound), forKey: key)
    }

    static func reset() {
        guard previewHasFocus else { return }
        UserDefaults.standard.set(`default`, forKey: key)
    }
}

/// ⌘F find-in-page for the visible preview. A singleton because only one preview is
/// on screen at a time and the menu commands live outside the view tree.
@MainActor
final class PreviewFinder: ObservableObject {
    static let shared = PreviewFinder()

    @Published var isVisible = false
    @Published var query = ""
    @Published var notFound = false
    @Published var focusToken = 0
    weak var webView: WKWebView?

    func show() {
        isVisible = true
        focusToken += 1 // re-focuses the field when the bar is already open
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        notFound = false
        webView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
        webView?.window?.makeFirstResponder(webView)
    }

    func next(backwards: Bool = false) {
        guard let webView, !query.isEmpty else { notFound = false; return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(query, configuration: config) { [weak self] result in
            self?.notFound = !result.matchFound
        }
    }
}

private struct PreviewFindBar: View {
    @ObservedObject var finder: PreviewFinder
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $finder.query)
                .textFieldStyle(.plain)
                .frame(width: 160)
                .focused($fieldFocused)
                .onSubmit { finder.next(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: finder.query) { _, _ in finder.next() }
                .onExitCommand { finder.hide() }
            if finder.notFound {
                Text("Not found").font(.caption).foregroundStyle(.secondary)
            }
            Button { finder.next(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G)")
            Button { finder.next() } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G)")
            Button { finder.hide() } label: { Image(systemName: "xmark") }
                .help("Close find (Esc)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
        .onAppear { fieldFocused = true }
        .onChange(of: finder.focusToken) { _, _ in fieldFocused = true }
    }
}

struct PreviewDrawerStack: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PreviewZoom.key) private var zoom = PreviewZoom.default
    /// Whether keyboard focus is inside the web view; unfocused previews dim like split panes.
    @State private var focused = false
    @ObservedObject private var finder = PreviewFinder.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let session = model.visiblePreview {
                PreviewWebView(path: session.path, dark: colorScheme == .dark, zoom: zoom, onFocusChange: { focused = $0 }) { model.navigatePreview(to: $0) }
                    .id(session.id)
                Rectangle()
                    .fill(Theme.terminalBackground.opacity(focused || finder.isVisible ? 0 : 0.6))
                    .animation(.easeInOut(duration: 0.15), value: focused || finder.isVisible)
                    .allowsHitTesting(false)
                Button { model.closePreview() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Close preview (⌘E)")
                .overlay(alignment: .leading) {
                    Button { model.togglePreviewZoom() } label: {
                        Image(systemName: session.isZoomed
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help(session.isZoomed ? "Unzoom preview (⇧⌘↩)" : "Zoom preview (⇧⌘↩)")
                    .offset(x: -30)
                }
                if finder.isVisible {
                    PreviewFindBar(finder: finder)
                        .padding(.top, 6)
                        .padding(.trailing, 70)
                }
            }
        }
        .background(Theme.terminalBackground)
    }
}

private struct PreviewWebView: NSViewRepresentable {
    let path: String
    let dark: Bool
    let zoom: Double
    let onFocusChange: (Bool) -> Void
    let onOpen: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        PreviewFinder.shared.webView = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.observeFocus()
        if view.pageZoom != zoom { view.pageZoom = zoom }
        context.coordinator.show(path: path, dark: dark)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        Task { @MainActor in
            if PreviewFinder.shared.webView === view { PreviewFinder.shared.webView = nil }
            PreviewFinder.shared.isVisible = false
        }
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onOpen: (String) -> Void = { _ in }
        var onFocusChange: (Bool) -> Void = { _ in }
        private var focusObservation: NSKeyValueObservation?
        private weak var observedWindow: NSWindow?

        /// Reports whether the window's first responder sits inside the web view
        /// (WebKit focuses an inner content view, not the `WKWebView` itself).
        func observeFocus() {
            guard let window = webView?.window, window !== observedWindow else { return }
            observedWindow = window
            focusObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    guard let self, let webView = self.webView else { return }
                    let inside = (window.firstResponder as? NSView)?.isDescendant(of: webView) ?? false
                    self.onFocusChange(inside)
                }
            }
        }
        private var path: String?
        private var dark = false
        private var modified: Date?
        private var viewerLoaded = false
        private var timer: Timer?

        func show(path: String, dark: Bool) {
            let changed = path != self.path || dark != self.dark
            self.path = path
            self.dark = dark
            if changed { modified = nil; viewerLoaded = false }
            reloadIfNeeded(force: changed)
            if timer == nil {
                // Polling survives editors that save by rename, which breaks file watches.
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reloadIfNeeded(force: false) }
                }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            focusObservation = nil
        }

        private var isMarkdown: Bool {
            guard let path else { return false }
            return PreviewSession.markdownExtensions.contains((path as NSString).pathExtension.lowercased())
        }

        private func reloadIfNeeded(force: Bool) {
            guard let path, let webView else { return }
            let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            guard force || date != modified else { return }
            modified = date
            let url = URL(fileURLWithPath: path)
            if isMarkdown {
                renderMarkdown(url: url, in: webView)
            } else {
                webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
            }
        }

        private func renderMarkdown(url: URL, in webView: WKWebView) {
            guard let viewer = Bundle.main.url(forResource: "viewer", withExtension: "html") else { return }
            if viewerLoaded {
                runRender(url: url, in: webView)
            } else {
                viewerLoaded = true
                webView.loadFileURL(viewer, allowingReadAccessTo: URL(fileURLWithPath: "/"))
                // `runRender` fires from `didFinish`.
            }
        }

        private func runRender(url: URL, in webView: WKWebView) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let base = url.deletingLastPathComponent().absoluteString
            // JSON-encode the strings so no markdown can break out of the call.
            func literal(_ value: String) -> String {
                (try? JSONEncoder().encode([value])).flatMap { String(data: $0, encoding: .utf8) }
                    .map { String($0.dropFirst().dropLast()) } ?? "\"\""
            }
            webView.evaluateJavaScript("render(\(literal(text)), \(dark), \(literal(base)))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            observeFocus() // the view has a window by now even if the first update came too early
            guard isMarkdown, let path, webView.url?.lastPathComponent == "viewer.html" else { return }
            runRender(url: URL(fileURLWithPath: path), in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url, action.targetFrame?.isMainFrame ?? true else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "file" {
                guard action.navigationType == .linkActivated else {
                    decisionHandler(.allow)
                    return
                }
                let target = url.standardizedFileURL.path
                if target == path.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) {
                    decisionHandler(.allow) // in-page anchor
                } else if !FileManager.default.fileExists(atPath: target) {
                    decisionHandler(.cancel)
                    notify("File not found", target)
                } else if PreviewSession.handles(target) {
                    decisionHandler(.cancel)
                    onOpen(target) // re-renders through the viewer, never the raw file
                } else {
                    decisionHandler(.cancel)
                }
            } else if ["about", "data", "blob", "javascript"].contains(scheme) {
                decisionHandler(.allow)
            } else if action.navigationType == .linkActivated,
                      ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url) // outbound links leave the viewer
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel) // redirects / scripted navigation away
            }
        }

        private func notify(_ title: String, _ message: String) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            if let window = webView?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}
