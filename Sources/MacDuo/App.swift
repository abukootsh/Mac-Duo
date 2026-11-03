import AppKit

@main
@MainActor
enum MacDuoApp {
    /// `NSApplication.delegate` is weak, so something has to own it.
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: LidEngine?
    private var menuBar: MenuBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.shared
        let engine = LidEngine(settings: settings)
        self.engine = engine
        menuBar = MenuBar(settings: settings, engine: engine)
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }
}
