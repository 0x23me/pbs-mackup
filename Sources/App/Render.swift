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

/// For development: `PBSMackup --shot settings|timeline <file.png> [server|key]` starts the app
/// as usual, opens that window as the menu would, writes a picture of the window and quits.
/// PBS_MACKUP_RENDER_OPEN names the folder the Backups window shows (`me.pxar/Documents`),
/// PBS_MACKUP_RENDER_WAIT the seconds to wait for the window's content (6).
enum Shot {
    static let request: (window: String, file: String)? = {
        let arguments = CommandLine.arguments
        guard let at = arguments.firstIndex(of: "--shot"), arguments.count > at + 2 else { return nil }
        return (arguments[at + 1], arguments[at + 2])
    }()

    /// Called once by the menu bar item, which is the first view on screen.
    @MainActor static func take(_ open: OpenWindowAction) {
        guard let request else { return }
        open(id: request.window)
        NSApp.activate(ignoringOtherApps: true)
        let wait = Double(ProcessInfo.processInfo.environment["PBS_MACKUP_RENDER_WAIT"] ?? "") ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            let window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix(request.window) == true }
            guard let window, let image = picture(of: window) else { print("no picture of \(request.window)"); exit(1) }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: request.file))
            exit(0)
        }
    }

    /// The window as it is on screen, with its frame and shadow. A program may always read its
    /// own windows. The SDK no longer declares the function, the system still has it.
    private static func picture(of window: NSWindow) -> CGImage? {
        typealias Function = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let including: UInt32 = 1 << 3, bestResolution: UInt32 = 1 << 3
        return unsafeBitCast(symbol, to: Function.self)(.null, including, UInt32(window.windowNumber), bestResolution)?
            .takeRetainedValue()
    }
}
