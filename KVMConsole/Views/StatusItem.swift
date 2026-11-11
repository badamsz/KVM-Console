import AppKit
import PiKVMKit
import SwiftUI

/// Preference keys shared by the app's scenes.
enum AppPreferences {
    static let showMenuBarExtraKey = "app.showMenuBarExtra"
}

/// The menu bar item: every machine with its power state and quick actions.
///
/// This is a plain AppKit status item rather than SwiftUI's `MenuBarExtra`.
/// `MenuBarExtra` re-evaluated its menu whenever any machine's state changed
/// and kept resizing the status item, which could hang the main thread. Here
/// the menu is built only when the user opens it.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private weak var app: AppModel?
    private let openWindow: OpenWindowAction
    private var item: NSStatusItem?

    init(app: AppModel, openWindow: OpenWindowAction) {
        self.app = app
        self.openWindow = openWindow
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = "KVM Console"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let app else { return }
        if app.devices.isEmpty {
            menu.addItem(disabled("No devices yet"))
        }
        for device in app.devices {
            if device.hasSwitch {
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: device.name))
                for target in device.targets { menu.addItem(machineItem(app, device, target)) }
            } else if let target = device.targets.first {
                menu.addItem(machineItem(app, device, target))
            }
        }
        menu.addItem(.separator())
        menu.addItem(action("Open KVM Console") { [weak self] in self?.showMainWindow() })
        menu.addItem(action("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })
        menu.addItem(.separator())
        menu.addItem(action("Quit KVM Console") { NSApp.terminate(nil) })
    }

    // MARK: Building

    private func machineItem(_ app: AppModel, _ device: Device, _ target: Target) -> NSMenuItem {
        let session = app.session(for: device.id)
        let leds = session.leds(for: target)
        let selection = TargetSelection(deviceID: device.id, targetID: target.id)

        let item = NSMenuItem(title: target.name, action: nil, keyEquivalent: "")
        let symbol = leds.map { $0.power ? "power.circle.fill" : "power.circle" } ?? "desktopcomputer"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)

        let sub = NSMenu()
        sub.addItem(disabled(statusLine(session, leds)))
        sub.addItem(.separator())
        sub.addItem(action("Open Console") { [weak self] in
            self?.openWindow(value: selection)
            NSApp.activate(ignoringOtherApps: true)
        })
        sub.addItem(action("Show in Main Window") { [weak self, weak app] in
            app?.selection = selection
            self?.showMainWindow()
        })
        if !session.isConnected {
            sub.addItem(action("Connect") { Task { await session.connect() } })
        }
        if let leds {
            sub.addItem(.separator())
            sub.addItem(action("Power On", enabled: !leds.power) { [weak self] in
                self?.run(target.name) { try await session.power(.on, for: target) }
            })
            sub.addItem(action("Shut Down", enabled: leds.power) { [weak self] in
                self?.run(target.name) { try await session.power(.off, for: target) }
            })
            sub.addItem(action("Reset…") { [weak self] in
                self?.confirm("Reset \(target.name)?", "This presses the reset button and may lose unsaved work.",
                              button: "Reset", name: target.name) {
                    try await session.click(.reset, for: target)
                }
            })
            sub.addItem(action("Force Off…") { [weak self] in
                self?.confirm("Force off \(target.name)?", "This holds the power button and may lose unsaved work.",
                              button: "Force Off", name: target.name) {
                    try await session.power(.offHard, for: target)
                }
            })
        }
        item.submenu = sub
        return item
    }

    private func statusLine(_ session: DeviceSession, _ leds: (power: Bool, hdd: Bool)?) -> String {
        switch session.status {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .failed: return "Can't connect"
        case .connected(let label, _):
            guard let leds else { return "Connected via \(label)" }
            return (leds.power ? "Powered on" : "Powered off") + " · via \(label)"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, enabled: Bool = true, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, handler: handler)
        item.isEnabled = enabled
        return item
    }

    // MARK: Actions

    /// Brings the main window forward, or opens one if it was closed.
    private func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func run(_ name: String, _ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
            } catch {
                // The main window may be closed, so report here instead of through it.
                let alert = NSAlert()
                alert.messageText = "Couldn't control \(name)"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func confirm(_ title: String, _ message: String, button: String, name: String,
                         _ work: @escaping () async throws -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            run(name, work)
        }
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }
}

/// The app's Settings window.
struct SettingsView: View {
    @AppStorage(AppPreferences.showMenuBarExtraKey) private var showMenuBarExtra = true
    @AppStorage(ConsolePreferences.hideToolbarInFullScreenKey) private var hideToolbarInFullScreen = true

    var body: some View {
        Form {
            Toggle("Show KVM Console in the menu bar", isOn: $showMenuBarExtra)
            Toggle("Hide the console toolbar in full screen", isOn: $hideToolbarInFullScreen)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
