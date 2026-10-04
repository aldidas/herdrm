import AppKit
import HerdrKit
import SwiftUI

/// herdr's keybindings, in front of the terminals. In herdr's own TUI the
/// client reads `prefix+key` chords; HerdrM's terminals attach to a single pane
/// and would hand them straight to the process inside, so this monitor reads
/// `~/.config/herdr/config.toml` `[keys]` and acts on them first. Direct
/// chords (`ctrl+1..9` for workspaces) work whatever has focus.
@MainActor
final class HerdrKeyRouter {
    private var machine = KeyPrefixMachine()
    private var keymap = HerdrKeymap.defaults
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    private weak var model: AppModel?

    func install(window: NSWindow, model: AppModel) {
        remove()
        self.window = window
        self.model = model
        reloadKeymap()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.machine.cancel() }
        })
        // Pick up config edits whenever the app comes back to the front.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.reloadKeymap() }
        })
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func reloadKeymap() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/herdr/config.toml")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            keymap = HerdrKeymap.parse(text)
        } else {
            keymap = .defaults
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
              let model, let chord = Self.chord(from: event)
        else { return event }
        // Dialog text fields keep their keys (and drop a half-typed prefix).
        if window.firstResponder is NSText {
            machine.cancel()
            return event
        }
        switch machine.handle(chord, keymap: keymap) {
        case .passThrough, .sendLiteralPrefix:
            // The literal-prefix case is the second press of the prefix key
            // itself: deliver it to the terminal as an ordinary keystroke.
            return event
        case .swallow:
            return nil
        case .perform(let action, let index):
            model.perform(action, index: index)
            return nil
        }
    }

    /// Digits by key code so `ctrl+1` does not depend on how AppKit reports
    /// control-modified characters.
    private static let digitKeyCodes: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]

    static func chord(from event: NSEvent) -> KeyChord? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        if let digit = digitKeyCodes[event.keyCode] {
            key = digit
        } else {
            switch event.keyCode {
            case 48: key = "tab"
            case 36, 76: key = "enter"
            case 53: key = "esc"
            case 49: key = "space"
            case 126: key = "up"
            case 125: key = "down"
            case 123: key = "left"
            case 124: key = "right"
            default:
                guard let characters = event.charactersIgnoringModifiers?.lowercased(),
                      characters.count == 1
                else { return nil }
                key = characters == "-" ? "minus" : characters
            }
        }
        return KeyChord(
            key: key,
            ctrl: flags.contains(.control),
            alt: flags.contains(.option),
            shift: flags.contains(.shift),
            cmd: flags.contains(.command)
        )
    }
}

/// Installs a `HerdrKeyRouter` on the hosting window.
private struct HerdrKeybindingsInstaller: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> InstallerView { InstallerView(model: model) }
    func updateNSView(_ nsView: InstallerView, context: Context) {}

    final class InstallerView: NSView {
        private let router = HerdrKeyRouter()
        private let model: AppModel

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                router.install(window: window, model: model)
            } else {
                router.remove()
            }
        }
    }
}

extension View {
    func herdrKeybindings(model: AppModel) -> some View {
        background(HerdrKeybindingsInstaller(model: model).frame(width: 0, height: 0))
    }
}
