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
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
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
        .alert("Error", isPresented: .constant(model.lastError != nil), presenting: model.lastError) { _ in
            Button("OK") { model.lastError = nil }
        } message: { Text($0) }
    }
}
