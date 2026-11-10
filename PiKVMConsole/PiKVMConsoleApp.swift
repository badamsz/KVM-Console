import SwiftUI

@main
struct PiKVMConsoleApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("PiKVM Console") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Device…") { model.editorRequest = .new }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
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
