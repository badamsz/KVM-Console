import SwiftUI

@main
struct PiKVMConsoleApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("PiKVM Console", id: "main") {
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
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ConsolePreferences.hideToolbarInFullScreenKey) private var hideToolbarInFullScreen = true

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
        CommandGroup(after: .newItem) {
            Button("Add Device…") { model.editorRequest = .new }
                .keyboardShortcut("n", modifiers: [.command, .shift])
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
                ContentUnavailableView("No Machine Selected", systemImage: "desktopcomputer",
                                       description: Text("Add a PiKVM, then pick a machine in the sidebar."))
            }
        }
        .sheet(item: $model.editorRequest) { request in
            DeviceEditorView(request: request)
        }
        .sheet(item: $model.updateRequest) { request in
            DeviceUpdateView(deviceID: request.deviceID)
                .interactiveDismissDisabled()
        }
        .alert("Error", isPresented: .constant(model.lastError != nil), presenting: model.lastError) { _ in
            Button("OK") { model.lastError = nil }
        } message: { Text($0) }
        .onAppear { model.installStatusItem(openWindow: openWindow, visible: showMenuBarExtra) }
        .onChange(of: showMenuBarExtra) { _, visible in model.statusItem?.setVisible(visible) }
    }
}
