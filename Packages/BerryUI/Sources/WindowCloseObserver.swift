import AppKit
import SwiftUI

/// Runs `onClose` when the window this view sits in is about to close, on
/// AppKit's `NSWindow.willCloseNotification`
/// (https://developer.apple.com/documentation/appkit/nswindow/willclosenotification),
/// which is posted for a close by the user and by the app alike.
///
/// A window's workspace cannot rely on being deallocated instead: its view
/// model and the AI panel controller hold closures that capture each other,
/// so neither is released when the window goes away.
struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onClose: onClose)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onClose = onClose
    }

    final class ObserverView: NSView {
        var onClose: @MainActor () -> Void
        private weak var observedWindow: NSWindow?

        init(onClose: @escaping @MainActor () -> Void) {
            self.onClose = onClose
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not decoded from a nib")
        }

        /// Observes only the window the view is in now, so another window
        /// closing, or this view moving to a new window, is not mistaken for
        /// this window's close. The selector form needs no removal when the
        /// view goes away: since macOS 10.11 the notification center drops
        /// such an observer itself
        /// (https://developer.apple.com/documentation/foundation/notificationcenter/addobserver(_:selector:name:object:)).
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            if let observedWindow { center.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow) }
            observedWindow = window
            guard let window else { return }
            center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }
}
