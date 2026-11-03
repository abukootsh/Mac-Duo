import AppKit
import ServiceManagement
import SwiftUI

struct SettingsPanel: View {
    @ObservedObject var settings: Settings
    @ObservedObject var engine: LidEngine
    var onQuit: () -> Void

    /// Empty follows the system language.
    @AppStorage("panelLanguage") private var languageCode = ""
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasPermission = CGPreflightScreenCaptureAccess()
    @State private var settingsFailed = false

    private static let privacyURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    private var language: PanelLanguage { PanelLanguage(rawValue: languageCode) ?? .system }
    private func t(_ key: String) -> String { language.text(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if engine.isSensorAvailable {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switches
                        if !hasPermission { permissionNotice }
                        startSection
                        lookSection
                        perspectiveSection
                    }
                    .padding(14)
                }
                .frame(height: 420)
            } else {
                Text(t("This Mac has no lid angle sensor. Only some MacBook models have one."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
            Divider()
            footer.padding(14)
        }
        .frame(width: 310)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = CGPreflightScreenCaptureAccess()
        }
        .onAppear { hasPermission = CGPreflightScreenCaptureAccess() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: "Mac Duo").font(.title2.weight(.semibold))
            Spacer()
            Text(String(format: "%.1f°", engine.angle))
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(engine.isActive ? Color.accentColor : .secondary)
                .accessibilityLabel(t("Lid angle"))
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 6) {
            toggle(t("Depth effect"), $settings.isEnabled, help: t("Leans the screen away as the lid closes."))
            toggle(t("Live rendering"), $settings.isLive, help: t("Off holds the frame from when the effect started."))
                .disabled(!settings.isEnabled)
            Button(t("Preview effect")) { engine.runPreview() }
                .controlSize(.small)
                .disabled(!settings.isEnabled || !hasPermission || engine.isActive)
        }
    }

    private var startSection: some View {
        section(t("Start")) {
            toggle(t("Timeout"), $settings.isTimeoutEnabled, help: t("Ends the effect once the angle stops changing."))
            slider(t("Start angle"), $settings.startAngle, 5...130, "%.0f°",
                   help: t("The effect starts at this angle."))
            slider(t("Full effect after"), $settings.fullEffectSpan, 5...60, "%.0f°",
                   help: t("Degrees of further closing to reach full strength."))
        }
    }

    private var lookSection: some View {
        section(t("Look")) {
            slider(t("Blur"), $settings.maxBlur, 10...160, "%.0f pt", help: t("Blur radius at the far edge."))
            slider(t("Blur spread"), $settings.blurSpread, 0...1, "%.0f%%", scale: 100,
                   help: t("0 blurs the far edge only, 100 the whole picture."))
            slider(t("Dimming"), $settings.maxDim, 0...1, "%.0f%%", scale: 100, help: t("How dark the far edge goes."))
            slider(t("Dimming spread"), $settings.dimSpread, 0.2...1, "%.0f%%", scale: 100,
                   help: t("Everything above this height goes fully dark."))
        }
    }

    private var perspectiveSection: some View {
        section(t("Perspective")) {
            slider(t("Lean back"), $settings.lean, 0...3, "%.1f×",
                   help: t("Degrees of lean per degree of closing. 1 holds it still."))
            slider(t("Perspective"), perspective, 0...1, "%.0f%%", scale: 100,
                   help: t("0 keeps the sides parallel, 100 converges sharply."))
        }
    }

    /// Strength 0...1 over the eye distance, which runs the other way.
    private var perspective: Binding<Double> {
        let range = Settings.farthestEye - Settings.nearestEye
        return Binding(
            get: { (Settings.farthestEye - settings.viewingDistance) / range },
            set: { settings.viewingDistance = Settings.farthestEye - $0 * range }
        )
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("Screen Recording permission is required to show the depth effect."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(t("Open System Settings")) {
                    settingsFailed = !NSWorkspace.shared.open(Self.privacyURL)
                }
                .controlSize(.small)
            }
            if settingsFailed {
                Text(t("Could not open System Settings. Open it manually and enable screen recording for Mac Duo under Privacy & Security."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("Language"))
                Spacer()
                Picker("", selection: $languageCode) {
                    Text(t("System")).tag("")
                    ForEach(PanelLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            toggle(t("Show angle in menu bar"), $settings.showsAngleInMenuBar)
            toggle(t("Launch at login"), $launchesAtLogin)
                .onChange(of: launchesAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchesAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            HStack {
                Button(t("Reset")) { settings.reset() }
                Spacer()
                Button(t("Quit"), action: onQuit)
            }
            .controlSize(.small)
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .disabled(!settings.isEnabled)
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(title)
            }
            caption(help)
        }
    }

    private func slider(
        _ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
        _ format: String, scale: Double = 1, help: String? = nil
    ) -> some View {
        let reading = String(format: format, value.wrappedValue * scale)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(reading).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).labelsHidden().controlSize(.small)
                .accessibilityLabel(title).accessibilityValue(reading)
            caption(help)
        }
    }

    @ViewBuilder
    private func caption(_ text: String?) -> some View {
        if let text {
            Text(text).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
