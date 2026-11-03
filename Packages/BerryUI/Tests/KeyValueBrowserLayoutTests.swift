import AppKit
import BerryKeyValueKit
import SwiftUI
import Testing

@testable import BerryUI

@MainActor
@Suite("Redis browser layout", .serialized)
struct KeyValueBrowserLayoutTests {
    @Test func wrappingTheToolbarPreservesThePatternFieldAndFocus() async throws {
        let view = KeyValueBrowserView(
            capabilities: .init(numberedDatabases: true), initialDatabase: 0,
            onScan: { _, _ in .init(entries: [], nextCursor: nil) },
            onGet: { _ in .none }, onTTL: { _ in nil },
            preview: { _ in "" }, onWrite: { _ in nil }, onSelectDatabase: { _ in nil }
        )
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let field = try #require(findPatternField(in: host))
        #expect(window.makeFirstResponder(field))
        let responder = try #require(window.firstResponder)
        for width in [480.0, 900, 600, 900] {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(findPatternField(in: host) === field)
            #expect(window.firstResponder === responder)
        }
    }

    private func findPatternField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let field = findPatternField(in: child) { return field }
        }
        return nil
    }
}
