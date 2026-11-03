import Foundation
import simd

/// The settings that shape a frame of the effect.
public struct DepthTuning: Equatable, Sendable {
    /// Eye distance from the screen centre, in screen heights.
    public var viewingDistance: Double
    /// Degrees the picture leans away from the glass per degree of closing.
    public var lean: Double
    /// Blur at the hinge edge as a fraction of the blur at the far edge.
    public var blurSpread: Double
    /// Height (fraction of the screen) where dimming reaches full strength.
    public var dimSpread: Double
    /// Blur radius at full effect, in points.
    public var maxBlur: Double
    /// Darkness at full effect, 0...1.
    public var maxDim: Double

    public init(
        viewingDistance: Double, lean: Double, blurSpread: Double,
        dimSpread: Double, maxBlur: Double, maxDim: Double
    ) {
        self.viewingDistance = viewingDistance
        self.lean = lean
        self.blurSpread = blurSpread
        self.dimSpread = dimSpread
        self.maxBlur = maxBlur
        self.maxDim = maxDim
    }
}

/// Where the screen picture lands on the glass as the lid closes.
///
/// The picture is a sheet hinged on the bottom edge of the screen. The eye
/// stays fixed in the room, placed in front of the screen as it stood at the
/// start angle. As the lid closes the glass turns under the eye, and the sheet
/// turns further back by `lean` times the travel, so it appears to recede.
public enum DepthProjection {

    /// Past 90° the sheet would turn its face away from the glass.
    public static let maxLeanDegrees: Double = 88

    /// Picture corners on the glass, in points with y up: bottom-left,
    /// bottom-right, top-right, top-left.
    public static func corners(
        startAngle: Double,
        currentAngle: Double,
        viewingDistance: Double,
        lean: Double,
        width: Double,
        height: Double
    ) -> [SIMD2<Double>] {
        let start = startAngle * .pi / 180
        let current = currentAngle * .pi / 180
        let travel = max(startAngle - currentAngle, 0)
        let tilt = min(lean * travel, maxLeanDegrees) * .pi / 180

        // The eye in room axes with the hinge at the origin: `forward` along
        // the base towards the viewer, `up` vertical.
        let forward = height * viewingDistance + height / 2 * cos(start)
        let up = height / 2 * sin(start)

        // The same eye in glass axes: along the glass, and out in front of it.
        let along = forward * cos(current) + up * sin(current)
        let depth = max(forward * sin(current) - up * cos(current), height / 10)

        let half = width / 2
        func project(_ x: Double, _ y: Double) -> SIMD2<Double> {
            // A sheet point at height y sits y·sin(tilt) behind the glass.
            let t = depth / (depth + y * sin(tilt))
            return SIMD2(half + (x - half) * t, along + (y * cos(tilt) - along) * t)
        }
        return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
    }

    /// The projective map from the rectangle (0,0)-(width,height) onto
    /// `corners` (bottom-left, bottom-right, top-right, top-left), as
    /// `screen = M * (x, y, 1)` followed by the perspective divide.
    public static func homography(width: Double, height: Double, corners q: [SIMD2<Double>]) -> simd_double3x3 {
        precondition(q.count == 4)
        // Unit square to quad (Heckbert).
        let sx = q[0].x - q[1].x + q[2].x - q[3].x
        let sy = q[0].y - q[1].y + q[2].y - q[3].y
        var g = 0.0, h = 0.0
        if abs(sx) > 1e-9 || abs(sy) > 1e-9 {
            let dx1 = q[1].x - q[2].x, dx2 = q[3].x - q[2].x
            let dy1 = q[1].y - q[2].y, dy2 = q[3].y - q[2].y
            let det = dx1 * dy2 - dx2 * dy1
            if abs(det) > 1e-12 {
                g = (sx * dy2 - dx2 * sy) / det
                h = (dx1 * sy - sx * dy1) / det
            }
        }
        let a = q[1].x - q[0].x + g * q[1].x
        let b = q[3].x - q[0].x + h * q[3].x
        let d = q[1].y - q[0].y + g * q[1].y
        let e = q[3].y - q[0].y + h * q[3].y
        return simd_double3x3(columns: (
            SIMD3(a / width, d / width, g / width),
            SIMD3(b / height, e / height, h / height),
            SIMD3(q[0].x, q[0].y, 1)
        ))
    }

    /// Blur strength for how far into the effect the lid is, 0...1. Starts
    /// slowly so the first degrees past the start angle stay sharp.
    public static func blurStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), 1.6)
    }

    /// Dimming strength; rises faster than the blur.
    public static func dimStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), 0.7)
    }

    /// Dimming at the hinge edge as a fraction of the far edge.
    public static let dimHingeFloor: Double = 0.2
}
