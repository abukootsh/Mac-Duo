import AppKit
import Combine
import DuoCore
import LidSensorKit
import QuartzCore

/// Watches the lid and drives the overlay.
///
/// A timer polls the sensor (slowly while the lid is far open, quickly near
/// the start angle). While the overlay is up, a display link eases a spring
/// towards the latest reading at the screen refresh rate, so the sensor's
/// 10 Hz steps do not show.
@MainActor
final class LidEngine: ObservableObject {

    @Published private(set) var angle: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var isActive = false

    private let settings: Settings
    private let sensor = LidSensor()
    private let renderer = DepthRenderer()
    private let overlay = Overlay()
    private lazy var capture = ScreenCapture(device: renderer?.device)

    private var trigger: LidTrigger
    private var spring = Spring()
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var lastPublish: CFTimeInterval = 0
    private var failedReads = 0
    private var isSuspended = false
    private var isClosingOut = false
    private var closingOutStarted: CFTimeInterval = 0
    /// Set once a frozen (non-live) run has its picture.
    private var isFrozen = false
    private var screenshotTask: Task<Void, Never>?
    private var preview: PreviewSweep?
    private var builtInFrame: CGRect?
    private var subscriptions = Set<AnyCancellable>()

    private static let idleInterval: TimeInterval = 1.0 / 8
    private static let activeInterval: TimeInterval = 1.0 / 30

    /// A scripted close-and-open so the panel can show the effect without
    /// moving the lid. It feeds the same path as the sensor.
    private struct PreviewSweep {
        let started: CFTimeInterval
        let open: Double
        let shut: Double

        func angle(at now: CFTimeInterval) -> Double? {
            let t = now - started
            switch t {
            case ..<0.3: return open
            case ..<1.7: return open + (shut - open) * (t - 0.3) / 1.4
            case ..<2.5: return shut
            case ..<3.1: return shut + (open - shut) * (t - 2.5) / 0.6
            default: return nil
            }
        }
    }

    init(settings: Settings) {
        self.settings = settings
        trigger = LidTrigger(configuration: .init(
            startAngle: settings.startAngle, timeoutEnabled: settings.isTimeoutEnabled
        ))
        settings.$isEnabled.removeDuplicates().sink { [weak self] enabled in
            if !enabled { self?.tearDown(resetTrigger: true) }
        }.store(in: &subscriptions)
    }

    // MARK: Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        guard isSensorAvailable else {
            log.notice("no lid angle sensor")
            return
        }
        if let reading = sensor.angle() {
            angle = reading
            trigger.reset(angle: reading)
        }
        builtInFrame = NSScreen.builtIn?.frame
        // Shows the system prompt once and lists the app under Screen Recording.
        if !capture.hasPermission { CGRequestScreenCaptureAccess() }
        overlay.keepPresence()
        observeSystem()
        setPollInterval(Self.idleInterval)
        // Lets scripts play the preview without the panel.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.abukotsh.MacDuo.preview"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPreview() }
        }
        Task {
            // Give the presence window a moment to be listed, so the filter
            // can exclude this app.
            try? await Task.sleep(for: .milliseconds(500))
            await capture.prepareFilter()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        tearDown(resetTrigger: false)
    }

    /// Plays the effect once on whatever is on screen.
    func runPreview() {
        guard settings.isEnabled, isSensorAvailable, !isSuspended, preview == nil, !isActive else { return }
        let start = settings.startAngle
        preview = PreviewSweep(
            started: CACurrentMediaTime(),
            open: max(start + 9, min(start + 35, 130)),
            shut: max(start - settings.fullEffectSpan * 1.15, 5)
        )
        trigger.reset(angle: preview?.open)
        setPollInterval(Self.activeInterval)
    }

    private func tearDown(resetTrigger: Bool) {
        stopDisplayLink()
        screenshotTask?.cancel()
        screenshotTask = nil
        overlay.dismiss(animated: false)
        renderer?.release()
        capture.stop()
        isClosingOut = false
        isFrozen = false
        preview = nil
        isActive = false
        if resetTrigger { trigger.reset(angle: angle) }
    }

    // MARK: Polling

    private func setPollInterval(_ interval: TimeInterval) {
        guard interval != pollInterval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !isSuspended else { return }
        let now = CACurrentMediaTime()

        let reading: Double
        if let sweep = preview {
            guard let scripted = sweep.angle(at: now) else {
                preview = nil
                if isActive { setActive(false) }
                trigger.reset(angle: sensor.angle() ?? angle)
                return
            }
            reading = scripted
        } else if let value = sensor.angle() {
            failedReads = 0
            reading = value
        } else {
            failedReads += 1
            if failedReads > 30, isActive { setActive(false) }
            return
        }

        if now - lastPublish > 0.08 {
            lastPublish = now
            angle = reading
        }
        guard settings.isEnabled else { return }

        trigger.configuration.startAngle = settings.startAngle
        trigger.configuration.timeoutEnabled = settings.isTimeoutEnabled
        let wanted = trigger.update(angle: reading, at: now) && builtInFrame != nil
        if wanted != isActive {
            log.notice("\(wanted ? "start" : "end", privacy: .public) at \(reading, format: .fixed(precision: 1))°")
            setActive(wanted)
        } else if isActive, !overlay.isVisible {
            present()
        } else if !isActive, !isClosingOut {
            // Start the stream while the lid is still closing, since it takes
            // a moment to deliver its first frame.
            if trigger.wantsPrewarm(at: now), capture.hasPermission {
                capture.start()
            } else {
                capture.stop()
            }
        }

        let near = reading <= settings.startAngle + 90
        setPollInterval(preview != nil || isActive || near ? Self.activeInterval : Self.idleInterval)
    }

    // MARK: Effect

    private var progress: Double {
        min(max((settings.startAngle - spring.value) / max(settings.fullEffectSpan, 1), 0), 1)
    }

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            isClosingOut = false
            spring.reset(to: angle)
            if let reading = trigger.angle { spring.reset(to: reading) }
            setPollInterval(Self.activeInterval)
            present()
        } else if overlay.isVisible, displayLink != nil {
            // Ease the picture back to flat, then fade it out.
            isClosingOut = true
            closingOutStarted = CACurrentMediaTime()
        } else {
            finish()
        }
    }

    /// Debug aid: `MACDUO_TEST_PATTERN=1` draws a generated grid instead of the
    /// screen, so the renderer can be checked without Screen Recording access.
    private static let usesTestPattern = ProcessInfo.processInfo.environment["MACDUO_TEST_PATTERN"] == "1"

    private func present() {
        if Self.usesTestPattern { return presentTestPattern() }
        guard settings.isEnabled, isActive, capture.hasPermission,
              let renderer, let screen = NSScreen.builtIn,
              renderer.begin(screenSize: screen.frame.size, scale: screen.backingScaleFactor) else { return }
        isFrozen = false
        overlay.show(on: screen, layer: renderer.makeLayer())
        capture.start()
        startDisplayLink()

        if let frame = capture.takeFrame() {
            log.notice("present: stream frame ready")
            adopt(frame)
        } else {
            // A fast close can beat the stream's first frame.
            screenshotTask?.cancel()
            screenshotTask = Task { [weak self] in
                let image = await self?.capture.screenshot()
                log.notice("present: screenshot \(image != nil)")
                guard let image, !Task.isCancelled,
                      let self, self.isActive, let renderer = self.renderer, !renderer.hasPicture else { return }
                renderer.ingest(image)
                self.overlay.reveal()
                if !self.settings.isLive { self.freeze() }
            }
        }
    }

    private func presentTestPattern() {
        guard isActive, let renderer, let screen = NSScreen.builtIn,
              renderer.begin(screenSize: screen.frame.size, scale: screen.backingScaleFactor) else { return }
        overlay.show(on: screen, layer: renderer.makeLayer())
        isFrozen = true
        startDisplayLink()
        let size = screen.frame.size
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill()
            NSColor.white.setStroke()
            for x in stride(from: 0, to: rect.width, by: 80) { NSBezierPath.strokeLine(from: .init(x: x, y: 0), to: .init(x: x, y: rect.height)) }
            for y in stride(from: 0, to: rect.height, by: 80) { NSBezierPath.strokeLine(from: .init(x: 0, y: y), to: .init(x: rect.width, y: y)) }
            ("Mac Duo" as NSString).draw(at: .init(x: rect.midX - 180, y: rect.midY),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 96), .foregroundColor: NSColor.white])
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        renderer.ingest(cg)
        overlay.reveal()
    }

    private func adopt(_ frame: StreamFrame) {
        renderer?.ingest(frame)
        overlay.reveal()
        if !settings.isLive { freeze() }
    }

    /// Holds the current picture and stops capturing.
    private func freeze() {
        isFrozen = true
        screenshotTask?.cancel()
        capture.stop()
    }

    private func finish() {
        isClosingOut = false
        stopDisplayLink()
        screenshotTask?.cancel()
        overlay.dismiss(animated: true)
        capture.stop()
    }

    // MARK: Animation

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = overlay.window else { return }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrame = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, 1.0 / 240), 1.0 / 20)
        lastFrame = now

        if !isFrozen, let frame = capture.takeFrame() { adopt(frame) }

        let target = isClosingOut ? settings.startAngle : (trigger.angle ?? angle)
        spring.step(toward: target, dt: dt)

        if isClosingOut {
            let settled = spring.value >= target - 0.05
            if settled || now - closingOutStarted > 1.2 {
                // Land exactly flat so the fade reveals an identical screen.
                spring.reset(to: target)
                draw()
                finish()
                return
            }
        }
        draw()
    }

    private func draw() {
        guard let renderer, let screen = NSScreen.builtIn else { return }
        let corners = DepthProjection.corners(
            startAngle: settings.startAngle,
            currentAngle: spring.value,
            viewingDistance: settings.viewingDistance,
            lean: settings.lean,
            width: Double(screen.frame.width),
            height: Double(screen.frame.height)
        )
        renderer.render(corners: corners, progress: progress, tuning: settings.tuning)
    }

    // MARK: System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSuspended = true
                self?.tearDown(resetTrigger: false)
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSuspended = false
                // A fresh baseline, so waking with a nearly shut lid does not
                // read as a close.
                self.trigger.reset(angle: self.sensor.angle())
                self.setPollInterval(Self.idleInterval)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Also posted for brightness changes; only a layout change matters.
                let frame = NSScreen.builtIn?.frame
                guard frame != self.builtInFrame else { return }
                self.builtInFrame = frame
                self.tearDown(resetTrigger: true)
                self.capture.invalidate()
                Task { await self.capture.prepareFilter() }
            }
        }
    }
}
