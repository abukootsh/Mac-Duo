import Foundation

/// The settings panel language, chosen independently of the system.
enum PanelLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case arabic = "ar"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    /// The language's own name, shown in the picker.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .arabic: return "العربية"
        case .chinese: return "简体中文"
        }
    }

    var isRightToLeft: Bool { self == .arabic }

    /// The best match for the system languages. Only languages listed in
    /// `CFBundleLocalizations` are considered, so Info.plist lists every case.
    static var system: PanelLanguage {
        let best = Bundle.preferredLocalizations(from: allCases.map(\.rawValue)).first
        return allCases.first { $0.rawValue == best } ?? .english
    }

    /// A packaged app keeps the SwiftPM resource bundle in
    /// Contents/Resources, where the generated accessor does not look.
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MacDuo_MacDuo.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    private var bundle: Bundle {
        // SwiftPM may lower-case the directory name, and Bundle matches
        // case-sensitively.
        for name in [rawValue, rawValue.lowercased()] {
            if let path = Self.resources.path(forResource: name, ofType: "lproj"),
               let bundle = Bundle(path: path) { return bundle }
        }
        return Self.resources
    }

    func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
