import Foundation

/// Decides, sample by sample, whether the depth effect should be on.
///
/// The effect starts when a lid that was open above the start angle is being
/// closed and crosses it. It ends when the lid is opened back above the start
/// angle, or, with the timeout on, once the lid has held still for a while.
/// A lid that merely rests below the start angle never starts it.
public struct LidTrigger: Sendable {

    public struct Configuration: Sendable {
        public var startAngle: Double
        public var timeoutEnabled: Bool
        /// Degrees above the start angle that release a resting lid.
        public var hysteresis: Double = 4
        /// Closing faster than this (deg/s) counts as a deliberate close.
        public var closingSpeed: Double = 2
        /// Opening faster than this (deg/s) counts as a deliberate reversal.
        public var openingSpeed: Double = 2
        /// How long after the last closing movement the effect may still start.
        public var closingMemory: TimeInterval = 1.5
        /// The hysteresis release waits at least this long after a start.
        public var minimumDuration: TimeInterval = 0.35
        /// A lid held at or above the start angle this long has been opened.
        public var openDwell: TimeInterval = 1
        /// Rise above the run's lowest reading needed before opening speed
        /// alone releases. Keeps a whole-degree sensor from flapping.
        public var minimumReleaseRise: Double = 1.5
        /// Movement within this many degrees counts as holding still.
        public var stillTolerance: Double = 2
        /// How long the lid must hold still for the timeout to end the effect.
        public var stillDuration: TimeInterval = 2
        /// Closing faster than this (deg/s) starts warming up the capture.
        public var prewarmSpeed: Double = 8
        /// How long the warm-up lingers after the lid stops moving.
        public var prewarmLinger: TimeInterval = 2
        /// Highest angle above the start angle at which the warm-up runs.
        public var prewarmCeiling: Double = 70

        public init(startAngle: Double, timeoutEnabled: Bool) {
            self.startAngle = startAngle
            self.timeoutEnabled = timeoutEnabled
        }
    }

    public var configuration: Configuration {
        didSet {
            if configuration.timeoutEnabled != oldValue.timeoutEnabled {
                stillSince = nil
                timedOut = false
            }
        }
    }

    public private(set) var isActive = false
    /// Smoothed angular velocity in degrees per second, negative when closing.
    public private(set) var velocity: Double = 0
    public private(set) var angle: Double?

    private var lastChange: (angle: Double, time: TimeInterval)?
    private var lastClosing: TimeInterval = -.infinity
    private var lastFastClosing: TimeInterval = -.infinity
    private var peak: Double = 0
    private var lowest: Double = 0
    private var startedAt: TimeInterval = 0
    private var aboveSince: TimeInterval?
    private var stillSince: (angle: Double, time: TimeInterval)?
    /// Set when the timeout ends a run; cleared once the lid rises above the
    /// start angle again.
    private var timedOut = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Forgets all motion history, for example after waking from sleep.
    public mutating func reset(angle: Double? = nil) {
        isActive = false
        velocity = 0
        self.angle = angle
        lastChange = nil
        lastClosing = -.infinity
        lastFastClosing = -.infinity
        peak = 0
        aboveSince = nil
        stillSince = nil
        timedOut = false
    }

    /// Feeds one reading and returns whether the effect should be on.
    @discardableResult
    public mutating func update(angle: Double, at now: TimeInterval) -> Bool {
        self.angle = angle
        trackVelocity(angle: angle, now: now)
        peak = max(peak, angle)
        if isActive { lowest = min(lowest, angle) }

        let c = configuration
        if angle >= c.startAngle {
            if aboveSince == nil { aboveSince = now }
            timedOut = false
        } else {
            aboveSince = nil
        }

        if isActive {
            if shouldRelease(angle: angle, now: now) {
                isActive = false
                peak = angle
            }
        } else if !timedOut, shouldStart(now: now) {
            isActive = true
            startedAt = now
            lowest = angle
            aboveSince = nil
            stillSince = (angle, now)
        }
        return isActive
    }

    /// Whether the capture should be warming up for an imminent start.
    public func wantsPrewarm(at now: TimeInterval) -> Bool {
        guard !isActive, let angle else { return false }
        return angle <= configuration.startAngle + configuration.prewarmCeiling
            && now - lastFastClosing < configuration.prewarmLinger
    }

    /// Where a fast-closing lid is heading, since a reading can be a whole
    /// sensor refresh old by the time it is used.
    public func predictedAngle(at now: TimeInterval) -> Double {
        guard let angle else { return 0 }
        guard velocity < -40, let lastChange else { return angle }
        let age = min(now - lastChange.time, 0.12)
        return angle + velocity * (age + 0.04)
    }

    private func shouldStart(now: TimeInterval) -> Bool {
        let c = configuration
        return peak >= c.startAngle
            && now - lastClosing < c.closingMemory
            && velocity < c.openingSpeed
            && predictedAngle(at: now) <= c.startAngle
    }

    private mutating func shouldRelease(angle: Double, now: TimeInterval) -> Bool {
        let c = configuration
        if velocity >= c.openingSpeed, angle >= c.startAngle, angle - lowest >= c.minimumReleaseRise {
            return true
        }
        if let aboveSince, now - aboveSince >= c.openDwell { return true }

        let settled = now - startedAt > c.minimumDuration
        if settled, angle >= c.startAngle + c.hysteresis { return true }

        if settled, c.timeoutEnabled {
            if let still = stillSince, abs(angle - still.angle) <= c.stillTolerance {
                if now - still.time >= c.stillDuration {
                    timedOut = true
                    return true
                }
            } else {
                stillSince = (angle, now)
            }
        }
        return false
    }

    private mutating func trackVelocity(angle: Double, now: TimeInterval) {
        guard let last = lastChange else {
            lastChange = (angle, now)
            return
        }
        if angle != last.angle {
            let dt = now - last.time
            if dt > 0.001 {
                velocity = 0.5 * (angle - last.angle) / dt + 0.5 * velocity
            }
            lastChange = (angle, now)
        } else if now - last.time > 0.4 {
            velocity = 0
        }

        let c = configuration
        if velocity >= c.openingSpeed {
            // An intentional reversal: an earlier close must not be reused.
            lastClosing = -.infinity
            lastFastClosing = -.infinity
        } else {
            if velocity <= -c.closingSpeed { lastClosing = now }
            if velocity <= -c.prewarmSpeed { lastFastClosing = now }
        }
    }
}
