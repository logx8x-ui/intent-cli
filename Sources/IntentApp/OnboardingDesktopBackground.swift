import AppKit
import ImageIO
import ScreenCaptureKit

/// Resolves the user's desktop, including macOS video/dynamic wallpapers whose
/// desktopImageURL is absent or cannot be opened as a normal NSImage.
@MainActor
enum OnboardingDesktopBackground {
    static func load(for screen: NSScreen) async -> NSImage? {
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return NSImage(cgImage: image, size: screen.frame.size)
        }
        // Never interrupt selection with a Screen Recording prompt. On existing
        // installations we can snapshot only the desktop's background layers.
        guard CGPreflightScreenCaptureAccess(), #available(macOS 14.0, *),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !Task.isCancelled, let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let excluded = content.windows.filter { window in
                let owner = window.owningApplication?.bundleIdentifier ?? ""
                return window.windowLayer >= 0 || owner == "com.apple.finder"
                    || owner == "com.apple.notificationcenterui" || owner.localizedCaseInsensitiveContains("widget")
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: excluded),
                configuration: configuration)
            guard !Task.isCancelled else { return nil }
            return NSImage(cgImage: image, size: screen.frame.size)
        } catch { return nil }
    }
}
