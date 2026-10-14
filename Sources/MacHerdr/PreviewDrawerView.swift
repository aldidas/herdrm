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

    /// Extensions ⌘K routes to the preview instead of nvim.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    static let htmlExtensions: Set<String> = ["html", "htm"]

    static func handles(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext) || htmlExtensions.contains(ext)
    }
}

struct PreviewDrawerStack: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let session = model.visiblePreview {
                PreviewWebView(path: session.path, dark: colorScheme == .dark)
                    .id(session.id)
                Button { model.closePreview() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Close preview (⌘E)")
            }
        }
        .background(Theme.terminalBackground)
    }
}

private struct PreviewWebView: NSViewRepresentable {
    let path: String
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(path: path, dark: dark)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
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
            guard isMarkdown, let path, webView.url?.lastPathComponent == "viewer.html" else { return }
            runRender(url: URL(fileURLWithPath: path), in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
