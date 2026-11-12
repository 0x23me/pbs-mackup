import AppKit
import SwiftUI

/// For development: `PBSMackup --render settings <file.png> [backup|server|key]` draws a window's
/// content into an image and exits, without the menu bar item and without touching the
/// Keychain or the launchd job. The backed-up folders can be set with PBS_MACKUP_RENDER_SOURCES.
enum Render {
    static var active = false

    static func run(_ arguments: [String]) -> Never {
        active = true
        guard arguments.count >= 2 else { print("usage: PBSMackup --render settings|timeline <file.png>"); exit(64) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let view: AnyView = arguments[0] == "timeline" ? AnyView(TimelineView()) : AnyView(SettingsView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // The window's own backdrop is not part of what a view draws into an image.
        window.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let content = window.contentView!
            let image = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[1]))
            exit(0)
        }
        app.run()
        exit(0)
    }
}
