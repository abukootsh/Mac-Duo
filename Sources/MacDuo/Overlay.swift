import AppKit
import QuartzCore

/// A borderless window above everything, menu bar and full-screen spaces
/// included. It never takes focus, and clicks pass through to the apps below.
final class PassThroughWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(frame: NSRect, level: NSWindow.Level) {
        self.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
}

private final class MetalView: NSView {
    init(metalLayer: CAMetalLayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The overlay window for one run of the effect.
@MainActor
final class Overlay {

    private(set) var window: PassThroughWindow?
    private var fading: PassThroughWindow?
    /// ScreenCaptureKit only lists apps that own a window, and the capture has
    /// to name this app to exclude the overlay. This window is one point wide
    /// and practically invisible.
    private var presence: PassThroughWindow?
    private var revealed = false

    var isVisible: Bool { window != nil }

    func keepPresence() {
        guard presence == nil else { return }
        let window = PassThroughWindow(frame: NSRect(x: 0, y: 0, width: 1, height: 1), level: .normal)
        window.alphaValue = 0.004
        window.orderFrontRegardless()
        presence = window
    }

    /// Puts up a transparent window that hosts `layer`; `reveal()` fades it in.
    func show(on screen: NSScreen, layer: CAMetalLayer) {
        dismiss(animated: false)
        let view = MetalView(metalLayer: layer, scale: screen.backingScaleFactor)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        let window = PassThroughWindow(
            frame: screen.frame,
            level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        )
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        self.window = window
        revealed = false
    }

    func reveal(duration: TimeInterval = 0.07) {
        guard let window, !revealed else { return }
        revealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func dismiss(animated: Bool) {
        if let fading {
            fading.orderOut(nil)
            self.fading = nil
        }
        guard let window else { return }
        self.window = nil
        guard animated else {
            window.orderOut(nil)
            return
        }
        fading = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                if self?.fading === window { self?.fading = nil }
            }
        }
    }
}
