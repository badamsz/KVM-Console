import Observation
import PiKVMKit
import SwiftUI

struct UpdateRequest: Identifiable {
    let deviceID: UUID
    var id: UUID { deviceID }
}

/// Runs `pikvm-update` on one PiKVM through its web terminal and shows the log.
@MainActor
@Observable
final class DeviceUpdateModel {
    enum Status: Equatable {
        case idle
        case connecting
        case running
        case finished(DeviceUpdateRun.Outcome)
        /// The connection dropped mid-update; the update itself keeps going on the device.
        case connectionLost
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var log = ""
    private var task: Task<Void, Never>?
    private var terminal: WebTerminal?
    private var updateRun = DeviceUpdateRun()
    /// Shell output before the command is typed (login banner and prompt).
    private var banner = ""

    var isBusy: Bool { status == .connecting || status == .running }

    func start(session: DeviceSession, rootPassword: String) {
        guard !isBusy else { return }
        log = ""
        status = .connecting
        task = Task { [weak self] in
            await self?.run(session: session, rootPassword: rootPassword)
        }
    }

    func stopWatching() {
        task?.cancel()
        task = nil
        terminal?.close()
        terminal = nil
    }

    private func run(session: DeviceSession, rootPassword: String) async {
        await session.connectIfNeeded()
        guard let client = session.client else {
            if case .failed(let message) = session.status { status = .error(message) } else { status = .error("Not connected.") }
            return
        }
        updateRun = DeviceUpdateRun()
        banner = ""
        do {
            let terminal = try WebTerminal(client: client)
            self.terminal = terminal

            // Type the command once the shell prompt appears, or after a
            // few seconds if the prompt isn't recognised.
            let fallback = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { await self?.sendCommandIfNeeded() }
            }
            defer { fallback.cancel() }

            for try await chunk in terminal.output() {
                if updateRun.phase == .starting {
                    banner += chunk
                    if banner.hasSuffix("$ ") || banner.hasSuffix("# ") { await sendCommandIfNeeded() }
                    continue
                }
                if let reply = updateRun.receive(chunk, rootPassword: rootPassword) {
                    try await terminal.send(reply)
                }
                log = updateRun.output.text
                if case .finished(let outcome) = updateRun.phase, status != .finished(outcome) {
                    status = .finished(outcome)
                    // Keep following the log while the device counts down to its reboot.
                    if outcome != .rebooting { break }
                }
            }
        } catch {
            if Task.isCancelled { return }
            if case .finished = status {
                // Expected: the device rebooted and closed the terminal.
            } else if status == .running {
                status = .connectionLost
            } else {
                status = .error("Couldn't open the web terminal: \(error.localizedDescription)")
            }
        }
        if Task.isCancelled { return }
        if status == .running { status = .connectionLost }
        if status == .connecting { status = .error("The web terminal closed before the update started.") }
        terminal?.close()
        terminal = nil
    }

    private func sendCommandIfNeeded() async {
        guard updateRun.phase == .starting, let terminal else { return }
        let command = updateRun.start()
        do {
            try await terminal.send(command)
            status = .running
        } catch {
            status = .error("Couldn't send the update command: \(error.localizedDescription)")
            terminal.close()
        }
    }
}

struct DeviceUpdateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let deviceID: UUID

    @State private var model = DeviceUpdateModel()
    @State private var rootPassword = ""
    @State private var remember = true

    var body: some View {
        let device = app.device(deviceID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Update \(device?.name ?? "PiKVM")").font(.title2).bold()

            if model.status == .idle || model.status == .finished(.wrongRootPassword) {
                Text("This runs pikvm-update on the device. If updates are installed, the PiKVM reboots and its consoles disconnect for a minute or two. The machines it controls are not affected.")
                    .fixedSize(horizontal: false, vertical: true)
                if device?.hasSwitch == true {
                    Text("All machines on this PiKVM's Switch lose their console during the reboot.")
                        .foregroundStyle(.secondary)
                }
                SecureField("Root password", text: $rootPassword, prompt: Text("The PiKVM's root (SSH) password"))
                    .onSubmit(start)
                Toggle("Remember in Keychain", isOn: $remember)
                if model.status == .finished(.wrongRootPassword) {
                    Label("The root password was rejected.", systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            } else {
                statusLine
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.isEmpty ? " " : model.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.log) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .frame(minHeight: 260)
            }

            HStack {
                Spacer()
                if model.status == .idle || model.status == .finished(.wrongRootPassword) {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Update", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(rootPassword.isEmpty)
                } else {
                    Button(model.isBusy ? "Hide" : "Done") {
                        model.stopWatching()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .help(model.isBusy ? "The update keeps running on the device." : "")
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            if let saved = app.credentials.password(for: deviceID, kind: .root) { rootPassword = saved }
        }
        .onChange(of: model.status) { _, status in
            guard case .finished(let outcome) = status else { return }
            if outcome == .wrongRootPassword {
                app.credentials.deletePassword(for: deviceID, kind: .root)
            } else if remember {
                app.credentials.setPassword(rootPassword, for: deviceID, kind: .root)
            }
        }
    }

    private func start() {
        guard !rootPassword.isEmpty else { return }
        model.start(session: app.session(for: deviceID), rootPassword: rootPassword)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Opening the web terminal…") }
        case .running:
            HStack { ProgressView().controlSize(.small); Text("Updating. This can take several minutes.") }
        case .finished(.upToDate):
            Label("Already up to date.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .finished(.rebooting):
            Label("Updated. The PiKVM reboots in 30 seconds and will reconnect on its own.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .finished(.wrongRootPassword):
            Label("The root password was rejected.", systemImage: "xmark.octagon").foregroundStyle(.red)
        case .finished(.failed(let code)):
            Label("pikvm-update failed (exit code \(code)). Read the log below before rebooting the device.",
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .connectionLost:
            Label("The connection dropped. The update keeps running on the PiKVM, which reboots when it finishes.",
                  systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
        case .error(let message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
