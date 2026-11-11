import PiKVMKit
import SwiftUI

struct DeviceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: EditorRequest

    @State private var device = Device(name: "")
    @State private var lanHost = ""
    @State private var tailscaleHost = ""
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var testResult: String?
    @State private var testing = false

    private var isNew: Bool { if case .new = request { return true } else { return false } }
    private var isSipeed: Bool { device.family.isSipeed }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Device") {
                    TextField("Name", text: $device.name, prompt: Text("Rack KVM"))
                    Picker("Model", selection: $device.model) {
                        Section("PiKVM") {
                            ForEach(PiKVMModel.allCases.filter { $0.family == .pikvm }) { Text($0.displayName).tag($0) }
                        }
                        Section("Sipeed") {
                            ForEach(PiKVMModel.allCases.filter { $0.family.isSipeed }) { Text($0.displayName).tag($0) }
                        }
                    }
                }
                Section {
                    TextField("LAN address", text: $lanHost, prompt: Text(isSipeed ? "192.168.1.60 or nanokvm.local" : "192.168.1.50 or pikvm.local"))
                    TextField("Tailscale address", text: $tailscaleHost, prompt: Text(isSipeed ? "nanokvm.tailnet-name.ts.net" : "pikvm.tailnet-name.ts.net"))
                } header: {
                    Text("Addresses")
                } footer: {
                    Text(isSipeed
                         ? "The LAN address is tried first, then Tailscale. HTTPS is tried before plain HTTP, which a NanoKVM uses unless HTTPS is turned on in its settings."
                         : "The LAN address is tried first, then Tailscale.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("Username", text: $device.username)
                    SecureField("Password", text: $password,
                                prompt: Text(hasSavedPassword ? "Saved in Keychain" : "Required"))
                } header: {
                    Text("Login")
                } footer: {
                    Text(isSipeed
                         ? "The NanoKVM web login. The default is admin / admin until you change it."
                         : "If two-factor authentication is on, add the current code to the end of the password.")
                        .foregroundStyle(.secondary)
                }
                if let testResult {
                    Text(testResult).font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Test Connection") { Task { await test() } }
                    .disabled(testing || assembled().endpoints.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    model.save(assembled(), password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !device.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !assembled().endpoints.isEmpty
            && (hasSavedPassword || !password.isEmpty)
    }

    private func load() {
        guard case .edit(let id) = request, let existing = model.device(id) else { return }
        device = existing
        lanHost = existing.endpoints.first { $0.label == "LAN" }?.host ?? ""
        tailscaleHost = existing.endpoints.first { $0.label == "Tailscale" }?.host ?? ""
        hasSavedPassword = model.credentials.password(for: id) != nil
    }

    private func assembled() -> Device {
        var d = device
        d.name = d.name.trimmingCharacters(in: .whitespaces)
        var endpoints: [Endpoint] = []
        let lan = lanHost.trimmingCharacters(in: .whitespaces)
        let ts = tailscaleHost.trimmingCharacters(in: .whitespaces)
        if !lan.isEmpty {
            endpoints.append(device.endpoints.first { $0.label == "LAN" }.map { Endpoint(id: $0.id, label: "LAN", host: lan) }
                ?? Endpoint(label: "LAN", host: lan))
        }
        if !ts.isEmpty {
            endpoints.append(device.endpoints.first { $0.label == "Tailscale" }.map { Endpoint(id: $0.id, label: "Tailscale", host: ts) }
                ?? Endpoint(label: "Tailscale", host: ts))
        }
        d.endpoints = endpoints
        if d.targets.count == 1, d.targets[0].switchPort == nil, d.targets[0].name.isEmpty || d.targets[0].name == device.name {
            d.targets[0].name = d.name
        }
        return d
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let pw = password.isEmpty ? (model.credentials.password(for: device.id) ?? "") : password
        var probe = assembled()
        probe.resetCertificateTrust()
        do {
            if probe.family.isSipeed {
                let conn = try await NanoKVMConnectionResolver.connect(to: probe, password: pw)
                let info = try? await conn.client.info()
                let scheme = conn.client.baseURL.scheme == "http" ? " over plain HTTP" : ""
                testResult = "Connected via \(conn.endpoint.label)\(scheme)"
                    + (info?.application.map { ", NanoKVM \($0)" } ?? "") + "."
            } else {
                let conn = try await ConnectionResolver.connect(to: probe, password: pw)
                let info = try? await conn.client.info()
                testResult = "Connected via \(conn.endpoint.label)" + (info?.kvmdVersion.map { ", kvmd \($0)" } ?? "") + "."
            }
        } catch {
            testResult = error.localizedDescription
        }
    }
}
