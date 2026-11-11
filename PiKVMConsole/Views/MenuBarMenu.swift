import AppKit
import PiKVMKit
import SwiftUI

/// Preference keys shared by the app's scenes.
enum AppPreferences {
    static let showMenuBarExtraKey = "app.showMenuBarExtra"
}

/// The menu bar item's menu: every machine with its power state and quick actions.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if app.devices.isEmpty {
            Text("No devices yet")
        }
        ForEach(app.devices) { device in
            if device.hasSwitch {
                Section(device.name) {
                    ForEach(device.targets) { target in
                        machineMenu(device, target)
                    }
                }
            } else if let target = device.targets.first {
                machineMenu(device, target)
            }
        }
        Divider()
        Button("Open PiKVM Console") { showMainWindow() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit PiKVM Console") { NSApp.terminate(nil) }
    }

    @ViewBuilder private func machineMenu(_ device: Device, _ target: Target) -> some View {
        let session = app.session(for: device.id)
        let leds = session.leds(for: target)
        let selection = TargetSelection(deviceID: device.id, targetID: target.id)
        Menu {
            Text(statusLine(session, leds))
            Divider()
            Button("Open Console") {
                openWindow(value: selection)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Show in Main Window") {
                app.selection = selection
                showMainWindow()
            }
            if session.client == nil {
                Button("Connect") { Task { await session.connect() } }
            }
            if let leds {
                Divider()
                Button("Power On") { run(target.name) { try await session.power(.on, for: target) } }
                    .disabled(leds.power)
                Button("Shut Down") { run(target.name) { try await session.power(.off, for: target) } }
                    .disabled(!leds.power)
                Button("Reset…") {
                    confirm("Reset \(target.name)?", "This presses the reset button and may lose unsaved work.", button: "Reset") {
                        try await session.click(.reset, for: target)
                    }
                }
                Button("Force Off…") {
                    confirm("Force off \(target.name)?", "This holds the power button and may lose unsaved work.", button: "Force Off") {
                        try await session.power(.offHard, for: target)
                    }
                }
            }
        } label: {
            if let leds {
                Label(target.name, systemImage: leds.power ? "power.circle.fill" : "power.circle")
            } else {
                Label(target.name, systemImage: "desktopcomputer")
            }
        }
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

    /// Brings the main window forward, or opens one if it was closed.
    private func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func run(_ name: String, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
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

    private func confirm(_ title: String, _ message: String, button: String, action: @escaping () async throws -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            run(title, action)
        }
    }
}

/// The app's Settings window.
struct SettingsView: View {
    @AppStorage(AppPreferences.showMenuBarExtraKey) private var showMenuBarExtra = true
    @AppStorage(ConsolePreferences.hideToolbarInFullScreenKey) private var hideToolbarInFullScreen = true

    var body: some View {
        Form {
            Toggle("Show PiKVM Console in the menu bar", isOn: $showMenuBarExtra)
            Toggle("Hide the console toolbar in full screen", isOn: $hideToolbarInFullScreen)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
