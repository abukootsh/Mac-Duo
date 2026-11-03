import Combine
import DuoCore
import Foundation

/// User settings, stored in `UserDefaults`.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Eye distance in screen heights at the two ends of the perspective
    /// slider. The panel shows strength, which runs the other way.
    static let farthestEye: Double = 6
    static let nearestEye: Double = 1

    @Published var isEnabled: Bool { didSet { save(isEnabled, "isEnabled") } }
    @Published var isLive: Bool { didSet { save(isLive, "isLive") } }
    @Published var isTimeoutEnabled: Bool { didSet { save(isTimeoutEnabled, "isTimeoutEnabled") } }
    /// Closing past this angle starts the effect. Degrees.
    @Published var startAngle: Double { didSet { save(startAngle, "startAngle") } }
    /// Degrees of further closing until the effect is at full strength.
    @Published var fullEffectSpan: Double { didSet { save(fullEffectSpan, "fullEffectSpan") } }
    @Published var maxBlur: Double { didSet { save(maxBlur, "maxBlur") } }
    @Published var blurSpread: Double { didSet { save(blurSpread, "blurSpread") } }
    @Published var maxDim: Double { didSet { save(maxDim, "maxDim") } }
    @Published var dimSpread: Double { didSet { save(dimSpread, "dimSpread") } }
    @Published var lean: Double { didSet { save(lean, "lean") } }
    @Published var viewingDistance: Double { didSet { save(viewingDistance, "viewingDistance") } }
    @Published var showsAngleInMenuBar: Bool { didSet { save(showsAngleInMenuBar, "showsAngleInMenuBar") } }

    private static let factory: [String: Any] = [
        "isEnabled": true,
        "isLive": true,
        "isTimeoutEnabled": false,
        "startAngle": 90.0,
        "fullEffectSpan": 60.0,
        "maxBlur": 135.0,
        "blurSpread": 0.0,
        "maxDim": 1.0,
        "dimSpread": 0.5,
        "lean": 1.0,
        "viewingDistance": 6.0,
        "showsAngleInMenuBar": false,
    ]

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: Self.factory)
        // Assigned once here so the stored values load; didSet does not run
        // during initialisation.
        isEnabled = defaults.bool(forKey: "isEnabled")
        isLive = defaults.bool(forKey: "isLive")
        isTimeoutEnabled = defaults.bool(forKey: "isTimeoutEnabled")
        startAngle = defaults.double(forKey: "startAngle")
        fullEffectSpan = defaults.double(forKey: "fullEffectSpan")
        maxBlur = defaults.double(forKey: "maxBlur")
        blurSpread = defaults.double(forKey: "blurSpread")
        maxDim = defaults.double(forKey: "maxDim")
        dimSpread = defaults.double(forKey: "dimSpread")
        lean = defaults.double(forKey: "lean")
        viewingDistance = defaults.double(forKey: "viewingDistance")
        showsAngleInMenuBar = defaults.bool(forKey: "showsAngleInMenuBar")
    }

    /// Restores every effect setting. The panel language is kept.
    func reset() {
        for key in Self.factory.keys { defaults.removeObject(forKey: key) }
        isEnabled = defaults.bool(forKey: "isEnabled")
        isLive = defaults.bool(forKey: "isLive")
        isTimeoutEnabled = defaults.bool(forKey: "isTimeoutEnabled")
        startAngle = defaults.double(forKey: "startAngle")
        fullEffectSpan = defaults.double(forKey: "fullEffectSpan")
        maxBlur = defaults.double(forKey: "maxBlur")
        blurSpread = defaults.double(forKey: "blurSpread")
        maxDim = defaults.double(forKey: "maxDim")
        dimSpread = defaults.double(forKey: "dimSpread")
        lean = defaults.double(forKey: "lean")
        viewingDistance = defaults.double(forKey: "viewingDistance")
        showsAngleInMenuBar = defaults.bool(forKey: "showsAngleInMenuBar")
    }

    var tuning: DepthTuning {
        DepthTuning(
            viewingDistance: viewingDistance, lean: lean, blurSpread: blurSpread,
            dimSpread: dimSpread, maxBlur: maxBlur, maxDim: maxDim
        )
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
