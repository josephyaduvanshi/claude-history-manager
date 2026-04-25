import SwiftUI
import AppKit

// MARK: - Window chrome accessor
//
// Walks up to the underlying NSWindow once it's available, sets the title
// bar transparent, hides the title text, and enables fullSizeContentView so
// our custom `TitleBar` view can extend up through the title bar Y range
// (where the traffic-light buttons draw on top of it).

struct WindowChromeAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// NSView subclass that applies the chrome tweaks the moment it lands in
    /// a window. `viewDidMoveToWindow` is the canonical hook; much more
    /// reliable than dispatching async on view creation, which can race the
    /// window-attach phase and find `view.window == nil`.
    private final class WindowChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = self.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
        }
    }
}
