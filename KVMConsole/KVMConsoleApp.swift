import SwiftUI

@main
struct KVMConsoleApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("KVM Console", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands { AppCommands(model: model) }

        // One console window per machine; opening the same machine again
        // brings its existing window forward.
        WindowGroup("Console", for: TargetSelection.self) { $selection in
            if let selection {
                ConsoleWindow(selection: selection)
                    .environment(model)
            }
        }
        .defaultSize(width: 1280, height: 760)

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("KVM Console Help", id: HelpCenter.windowID) {
            HelpView()
        }
        .defaultSize(width: 920, height: 640)
        .commandsRemoved()

        Window("USB Devices", id: USBDevicesView.windowID) {
            USBDevicesView()
                .environment(model)
        }
        .defaultSize(width: 640, height: 600)
        .commandsRemoved()
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ConsolePreferences.hideToolbarInFullScreenKey) private var hideToolbarInFullScreen = false

    var body: some Commands {
        // Acts on the console window in front. The buttons look the console up when
        // they run, so the menu does not depend on (or rebuild with) console state.
        // The shortcuts all use Control+Command, which the console keeps for the Mac
        // instead of sending to the remote machine.
        CommandMenu("Console") {
            Button("Send Ctrl+Alt+Del") { model.frontConsole?.sendCombo(["ControlLeft", "AltLeft", "Delete"]) }
                .keyboardShortcut(.delete, modifiers: [.control, .command])
            Button("Paste Clipboard as Typing") { model.frontConsole?.pasteClipboard() }
                .keyboardShortcut("v", modifiers: [.option, .command])
            Button("Paste Clipboard as Formatted Typing") { model.frontConsole?.pasteClipboard(.formatted) }
                .keyboardShortcut("v", modifiers: [.shift, .option, .command])
            Divider()
            Button("Switch Mouse Mode") { model.frontConsole?.toggleMouseMode() }
                .keyboardShortcut("m", modifiers: [.control, .command])
            Button("Virtual Media…") { model.frontConsole?.showingMedia = true }
                .keyboardShortcut("i", modifiers: [.control, .command])
            Divider()
            Button("Reconnect Video") { model.frontConsole?.reconnect() }
                .keyboardShortcut("r", modifiers: [.control, .command])
        }
        CommandGroup(after: .toolbar) {
            Toggle("Hide Toolbar in Full Screen", isOn: $hideToolbarInFullScreen)
                .keyboardShortcut("t", modifiers: [.command, .control])
        }
        // Replaces the default item, which would say help isn't available. The
        // Help menu's search field also finds help topics (HelpMenuSearch).
        CommandGroup(replacing: .help) {
            Button("KVM Console Help") { HelpCenter.shared.show(using: openWindow) }
                .keyboardShortcut("?", modifiers: .command)
            Button("Keyboard Shortcuts") { HelpCenter.shared.show("shortcuts", using: openWindow) }
            Button("Troubleshooting") { HelpCenter.shared.show("troubleshooting", using: openWindow) }
            Divider()
            Link("PiKVM Documentation", destination: URL(string: "https://docs.pikvm.org")!)
            Link("Sipeed NanoKVM Wiki", destination: URL(string: "https://wiki.sipeed.com/hardware/en/kvm/")!)
            Link("Openterface Website", destination: URL(string: "https://openterface.com")!)
            Divider()
            Link("KVM Console on GitHub", destination: URL(string: "https://github.com/badamsz/PiKVM-Console")!)
        }
        CommandGroup(after: .newItem) {
            Button("Add Device…") { model.editorRequest = .new }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Find Devices on Network…") { model.showingDiscovery = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("USB Devices…") { openWindow(id: USBDevicesView.windowID) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Open Console") {
                if let selection = model.selection { openWindow(value: selection) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.selection == nil)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppPreferences.showMenuBarExtraKey) private var showMenuBarExtra = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            DeviceListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let selection = model.selection,
               let device = model.device(selection.deviceID),
               let target = device.targets.first(where: { $0.id == selection.targetID }) {
                TargetDetailView(device: device, target: target)
                    .id(target.id)
            } else {
                ContentUnavailableView {
                    Label("No Machine Selected", systemImage: "desktopcomputer")
                } description: {
                    Text("Add a KVM, then pick a machine in the sidebar.")
                } actions: {
                    Button("Getting Started") { HelpCenter.shared.show("getting-started", using: openWindow) }
                }
            }
        }
        .sheet(item: $model.editorRequest) { request in
            DeviceEditorView(request: request)
        }
        .sheet(isPresented: $model.showingDiscovery) {
            DiscoveryView()
        }
        .sheet(item: $model.updateRequest) { request in
            DeviceUpdateView(deviceID: request.deviceID)
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.configRequest) { request in
            DeviceConfigView(deviceID: request.deviceID)
                .interactiveDismissDisabled()
        }
        .alert("Error", isPresented: .constant(model.lastError != nil), presenting: model.lastError) { _ in
            Button("OK") { model.lastError = nil }
        } message: { Text($0) }
        .onAppear {
            model.installStatusItem(openWindow: openWindow, visible: showMenuBarExtra)
            HelpCenter.shared.install(openWindow: openWindow)
        }
        .onChange(of: showMenuBarExtra) { _, visible in model.statusItem?.setVisible(visible) }
    }
}
