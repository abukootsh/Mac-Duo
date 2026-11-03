import AppKit
import Combine
import SwiftUI

/// The menu bar icon and its settings popover.
@MainActor
final class MenuBar: NSObject {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let settings: Settings
    private let engine: LidEngine
    private var subscriptions = Set<AnyCancellable>()
    private var moveObserver: NSObjectProtocol?

    init(settings: Settings, engine: LidEngine) {
        self.settings = settings
        self.engine = engine
        super.init()

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Mac Duo")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle)
        }

        popover.behavior = .transient
        let host = NSHostingController(rootView: SettingsPanel(
            settings: settings, engine: engine, onQuit: { NSApp.terminate(nil) }
        ))
        // Otherwise the popover keeps its default height and clips the panel.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        Publishers.CombineLatest(engine.$angle, settings.$showsAngleInMenuBar)
            .map { angle, shows in shows ? String(format: " %.0f°", angle) : "" }
            .removeDuplicates()
            .sink { [weak self] title in self?.item.button?.title = title }
            .store(in: &subscriptions)

        // Showing the angle widens the button, and the status item window
        // slides a moment later. Re-anchor so the popover follows it.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown, let button = self.item.button,
                      (note.object as? NSWindow) === button.window else { return }
                self.popover.animates = false
                self.popover.show(relativeTo: .zero, of: button, preferredEdge: .minY)
                self.popover.animates = true
            }
        }
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: .zero, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
