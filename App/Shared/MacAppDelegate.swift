#if os(macOS)
import AppKit

/// Sets the Dock icon explicitly at launch. A rebuilt, ad-hoc-signed bundle can show a blank Dock tile even though
/// `AppIcon.icns` is in the bundle and `CFBundleIconFile` is set, because LaunchServices caches the first icon it saw.
///
/// The icon art is an opaque, full-bleed square, and an image set through `applicationIconImage` is shown as-is, so it is
/// drawn into a rounded tile on the macOS icon grid (824 pt body in a 1024 pt canvas) to sit with the other Dock icons.
final class SignalHiveAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let art = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = Self.tile(art)
    }

    static func tile(_ art: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { canvas in
            let body = canvas.insetBy(dx: 100, dy: 100)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).addClip()
            art.draw(in: body)
            return true
        }
    }
}
#endif
