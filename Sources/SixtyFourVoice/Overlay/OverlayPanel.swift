import AppKit

/// Borderless, transparent, click-through panel that never takes focus. It is only as big as the largest notch
/// plus a margin for shadow and overshoot; `OverlayController` moves it every display frame.
final class OverlayPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        // Above normal, floating and full-screen windows (and the menu bar), below the screen saver.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isExcludedFromWindowsMenu = true
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Never let AppKit nudge us below the menu bar or back onto a screen: we position ourselves.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension NSScreen {
    var overlayDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The screen containing `point` (AppKit global coordinates), else the nearest one.
    static func overlayScreen(containing point: NSPoint) -> NSScreen? {
        if let hit = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) { return hit }
        return screens.min { a, b in
            distance(point, a.frame) < distance(point, b.frame)
        }
    }

    private static func distance(_ p: NSPoint, _ r: NSRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}

/// Converts between AppKit's global space (origin bottom-left of the primary display, y up) and the top-left
/// space used by ScreenCaptureKit, Accessibility and `PlacementEngine`.
enum OverlayScreenSpace {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func topLeft(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    static func topLeft(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func appKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func appKit(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight - p.y) }
}
