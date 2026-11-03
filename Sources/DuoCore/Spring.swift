import Foundation

/// Smooths the sensor's ~10 Hz steps into motion at the display refresh rate.
///
/// Semi-implicit Euler; stable while `frequency * dt` stays below 2, so the
/// caller clamps `dt`.
public struct Spring: Sendable {
    public var value: Double
    public var velocity: Double = 0
    /// Radians per second. Higher follows faster and smooths less.
    public var frequency: Double = 16

    public init(value: Double = 0) {
        self.value = value
    }

    public mutating func step(toward target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    public mutating func reset(to value: Double) {
        self.value = value
        velocity = 0
    }
}
