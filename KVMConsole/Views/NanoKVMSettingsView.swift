import Observation
import KVMKit
import SwiftUI

/// Reads and changes a NanoKVM's device settings through its HTTP API, over
/// the connection the app already has. Each change applies at once, like on
/// the NanoKVM's own Settings page; changes that interrupt the remote
/// machine's keyboard, mouse or video ask first.
@MainActor
@Observable
final class NanoKVMSettingsModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var settings = NanoKVMSettings()
    /// What is being changed right now, for the status line.
    private(set) var busy: String?
    var problem: String?
    /// Shown after a change the device needs time for (a reboot).
    private(set) var notice: String?
    private(set) var family: DeviceFamily = .nanoKVM

    var hostnameDraft = ""
    var webTitleDraft = ""
    var idleTimeoutDraft = 0

    private var client: NanoKVMClient?
    private weak var session: DeviceSession?

    var isBusy: Bool { busy != nil }
    var isPro: Bool { family == .nanoKVMPro }

    func load(session: DeviceSession) async {
        self.session = session
        phase = .loading
        problem = nil
        await session.connectIfNeeded()
        guard let client = session.nanoClient else {
            if case .failed(let message) = session.status {
                phase = .failed(message)
            } else {
                phase = .failed("Not connected to the NanoKVM.")
            }
            return
        }
        self.client = client
        family = client.family
        await reread()
        phase = .ready
    }

    func reload() async {
        guard let session, busy == nil else { return }
        notice = nil
        if session.nanoClient !== client {
            await load(session: session)
            return
        }
        busy = "Reading the settings…"
        defer { busy = nil }
        await reread()
    }

    private func reread() async {
        guard let client else { return }
        settings = await client.settings()
        hostnameDraft = settings.hostname ?? ""
        webTitleDraft = settings.webTitle ?? ""
        idleTimeoutDraft = settings.hdmiIdleTimeoutMinutes ?? 0
    }

    /// Runs one change, then reads the settings again so the sheet shows what
    /// the device really did.
    func apply(_ label: String, optimistic: ((inout NanoKVMSettings) -> Void)? = nil,
               _ change: @escaping (NanoKVMClient) async throws -> Void) {
        guard let client, busy == nil else { return }
        optimistic?(&settings)
        busy = label
        problem = nil
        notice = nil
        Task {
            defer { busy = nil }
            do {
                try await change(client)
            } catch {
                problem = error.localizedDescription
            }
            await reread()
        }
    }

    /// For changes after which the device goes away for a while.
    func applyAndDisconnect(_ label: String, notice: String, _ change: @escaping (NanoKVMClient) async throws -> Void) {
        guard let client, busy == nil else { return }
        busy = label
        problem = nil
        Task {
            defer { busy = nil }
            do {
                try await change(client)
                self.notice = notice
                phase = .failed(notice)
                self.client = nil
                session?.disconnect()
            } catch {
                problem = error.localizedDescription
                await reread()
            }
        }
    }
}

/// A change that asks before it is made.
private struct PendingChange: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    var destructive = false
    let run: () -> Void
}

struct NanoKVMSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let deviceID: UUID

    @State private var model = NanoKVMSettingsModel()
    @State private var pending: PendingChange?

    var body: some View {
        let device = app.device(deviceID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Configure \(device?.name ?? "NanoKVM")").font(.title2).bold()

            switch model.phase {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Reading the settings…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: model.notice == nil ? "exclamationmark.triangle.fill" : "arrow.clockwise.circle")
                        .foregroundStyle(model.notice == nil ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await model.load(session: app.session(for: deviceID)) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .ready:
                form(device)
            }

            statusArea
            HStack {
                HelpButton(topic: "configure-nanokvm")
                if model.phase == .ready {
                    Button { Task { await model.reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(model.isBusy)
                    Button("Reboot \(device?.model.shortName ?? "NanoKVM")…") { confirmReboot(device) }
                        .disabled(model.isBusy)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 600, height: 640)
        .task { await model.load(session: app.session(for: deviceID)) }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { change in
            Button(change.button, role: change.destructive ? .destructive : nil) { change.run() }
        } message: { change in
            Text(change.message)
        }
    }

    @ViewBuilder private var statusArea: some View {
        if let busy = model.busy {
            HStack { ProgressView().controlSize(.small); Text(busy) }
        } else if let problem = model.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Form

    private func form(_ device: Device?) -> some View {
        let s = model.settings
        return Form {
            general(s, device)
            input(s)
            usbDevices(s)
            video(s)
            system(s)
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
    }

    @ViewBuilder private func general(_ s: NanoKVMSettings, _ device: Device?) -> some View {
        Section("General") {
            if s.hostname != nil {
                row(help: "Its name on the network, also used for its .local address. Takes full effect after a reboot.") {
                    LabeledContent("Host name") {
                        HStack {
                            TextField("Host name", text: $model.hostnameDraft)
                                .labelsHidden()
                                .onSubmit(saveHostname)
                            Button("Set", action: saveHostname)
                                .disabled(model.hostnameDraft == s.hostname || !NanoKVMSettings.isValidHostname(model.hostnameDraft))
                        }
                    }
                }
            }
            if s.webTitle != nil {
                row(help: "The title of its web page. Leave empty for the default.") {
                    LabeledContent("Web page title") {
                        HStack {
                            TextField("Web page title", text: $model.webTitleDraft, prompt: Text("NanoKVM"))
                                .labelsHidden()
                                .onSubmit(saveWebTitle)
                            Button("Set", action: saveWebTitle).disabled(model.webTitleDraft == s.webTitle)
                        }
                    }
                }
            }
            if let ssh = s.ssh {
                row(help: "Lets you log in to the NanoKVM with ssh as root.") {
                    Toggle("SSH", isOn: Binding(get: { ssh }, set: { on in
                        model.apply(on ? "Turning SSH on…" : "Turning SSH off…", optimistic: { $0.ssh = on }) { try await $0.setSSH(on) }
                    }))
                }
            }
            if let mdns = s.mdns {
                row(help: "Answers to its .local name and shows up in Find Devices.") {
                    Toggle("mDNS (Bonjour)", isOn: Binding(get: { mdns }, set: { on in setMDNS(on, device: device) }))
                }
            }
            if let preview = s.previewUpdates {
                row(help: "Offers beta versions when the NanoKVM checks for updates on its web page.") {
                    Toggle("Preview updates", isOn: Binding(get: { preview }, set: { on in
                        model.apply("Changing the update channel…", optimistic: { $0.previewUpdates = on }) { try await $0.setPreviewUpdates(on) }
                    }))
                }
            }
            if let sleep = s.screenSleepSeconds {
                row(help: "How long the NanoKVM's own screen stays on.") {
                    Picker("Screen sleep", selection: Binding(get: { sleep }, set: { value in
                        model.apply("Changing screen sleep…", optimistic: { $0.screenSleepSeconds = value }) { try await $0.setScreenSleep(seconds: value) }
                    })) {
                        ForEach(Self.including(sleep, in: NanoKVMSettings.screenSleepChoices), id: \.self) { Text(Self.duration($0)).tag($0) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func input(_ s: NanoKVMSettings) -> some View {
        if s.hidMode != nil || s.jiggler != nil {
            Section("Keyboard and Mouse") {
                if let mode = s.hidMode {
                    row(help: "Keyboard and mouse only hides the virtual drive and network adapter, for BIOSes that don't cope with them.") {
                        Picker("USB devices", selection: Binding(get: { mode }, set: { setHIDMode($0) })) {
                            Text("Keyboard, mouse and more").tag(NanoKVMHIDMode.normal)
                            Text("Keyboard and mouse only").tag(NanoKVMHIDMode.hidOnly)
                        }
                    }
                }
                if let jiggler = s.jiggler {
                    row(help: "Moves the pointer now and then so the remote machine doesn't sleep or lock. Use relative if the pointer jumps to a corner.") {
                        Picker("Mouse jiggler", selection: Binding(get: { jiggler }, set: { value in
                            model.apply("Changing the mouse jiggler…", optimistic: { $0.jiggler = value }) { try await $0.setJiggler(value) }
                        })) {
                            Text("Off").tag(NanoKVMJiggler.off)
                            Text("Relative").tag(NanoKVMJiggler.relative)
                            Text("Absolute").tag(NanoKVMJiggler.absolute)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func usbDevices(_ s: NanoKVMSettings) -> some View {
        if s.usbNetwork != nil || s.usbDisk != nil || s.usbMicrophone != nil || s.proDisk != nil {
            Section {
                if let on = s.usbNetwork {
                    row(help: "A USB Ethernet adapter on the remote machine that connects it to the NanoKVM.") {
                        Toggle("Network adapter", isOn: Binding(get: { on }, set: { value in
                            confirmUSB("Turn the USB network adapter \(value ? "on" : "off")?") {
                                model.apply("Changing USB devices…", optimistic: { $0.usbNetwork = value }) { try await $0.setUSBNetwork(value, current: on) }
                            }
                        }))
                    }
                }
                if let on = s.usbDisk {
                    row(help: "Shows the NanoKVM's data partition to the remote machine as a USB drive. Off while an image is mounted.") {
                        Toggle("Data partition as a USB drive", isOn: Binding(get: { on }, set: { value in
                            confirmUSB("\(value ? "Share" : "Stop sharing") the data partition?") {
                                model.apply("Changing USB devices…", optimistic: { $0.usbDisk = value }) { try await $0.setUSBDisk(value, current: on) }
                            }
                        }))
                    }
                }
                if let disk = s.proDisk {
                    row(help: "Storage on the NanoKVM shown to the remote machine as a USB drive.") {
                        Picker("USB drive", selection: Binding(get: { disk }, set: { value in
                            let change = {
                                model.apply("Changing USB devices…", optimistic: { $0.proDisk = value }) { try await $0.setProDisk(value, current: disk) }
                            }
                            if value == .emmc && !s.emmcImageExists {
                                pending = PendingChange(title: "Erase the NanoKVM's /data to set up the eMMC drive?",
                                                        message: "Using the built-in storage for the first time erases everything in the NanoKVM's /data folder, including its ISO images. Copy anything you need off it first.",
                                                        button: "Erase and Use eMMC", destructive: true, run: change)
                            } else {
                                confirmUSB("Change the USB drive to \(Self.diskName(value).lowercased())?", run: change)
                            }
                        })) {
                            ForEach(s.proDiskChoices, id: \.self) { Text(Self.diskName($0)).tag($0) }
                        }
                    }
                }
                if let on = s.usbMicrophone {
                    row(help: "A USB microphone on the remote machine, for sound sent from the NanoKVM's web page.") {
                        Toggle("Microphone", isOn: Binding(get: { on }, set: { value in
                            confirmUSB("Turn the USB microphone \(value ? "on" : "off")?") {
                                model.apply("Changing USB devices…", optimistic: { $0.usbMicrophone = value }) { try await $0.setUSBMicrophone(value, current: on) }
                            }
                        }))
                    }
                }
            } header: {
                Text("USB Devices")
            } footer: {
                Text("Changing these reconnects the NanoKVM's USB, so the remote machine loses its keyboard and mouse for a moment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func video(_ s: NanoKVMSettings) -> some View {
        if s.hdmiCapture != nil || s.hdmiPassthrough != nil || s.edid != nil {
            Section("Video") {
                if let on = s.hdmiCapture {
                    row(help: "Off stops the video completely, for privacy or to save power.") {
                        Toggle("HDMI capture", isOn: Binding(get: { on }, set: { value in
                            let change = {
                                model.apply(value ? "Turning HDMI capture on…" : "Turning HDMI capture off…", optimistic: { $0.hdmiCapture = value }) {
                                    try await $0.setHDMICapture(value)
                                }
                            }
                            if value { change() } else {
                                pending = PendingChange(title: "Turn HDMI capture off?",
                                                        message: "Consoles and the screen picture go black until it's turned on again.",
                                                        button: "Turn Off", run: change)
                            }
                        }))
                    }
                }
                if s.hdmiIdleTimeoutMinutes != nil {
                    row(help: "Pauses capture when nobody has watched for this long, to save power. 0 never pauses.") {
                        LabeledContent("Pause when idle") {
                            HStack(spacing: 4) {
                                TextField("Minutes", value: $model.idleTimeoutDraft, format: .number.grouping(.never))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 70)
                                    .onSubmit(saveIdleTimeout)
                                Text("minutes").foregroundStyle(.secondary)
                                Button("Set", action: saveIdleTimeout)
                                    .disabled(model.idleTimeoutDraft == s.hdmiIdleTimeoutMinutes
                                              || !(0...NanoKVMSettings.maxHDMIIdleTimeoutMinutes).contains(model.idleTimeoutDraft))
                            }
                        }
                    }
                }
                if let on = s.hdmiPassthrough {
                    row(help: "Sends the remote machine's picture on to a monitor plugged into the NanoKVM's HDMI output.") {
                        Toggle("HDMI passthrough", isOn: Binding(get: { on }, set: { value in
                            model.apply("Changing HDMI passthrough…", optimistic: { $0.hdmiPassthrough = value }) { try await $0.setHDMIPassthrough(value) }
                        }))
                    }
                }
                if let edid = s.edid {
                    row(help: "The display the remote machine thinks it's connected to, which sets the resolutions it offers. Upload your own on the NanoKVM's web page.") {
                        Picker("Display (EDID)", selection: Binding(get: { edid }, set: { value in
                            pending = PendingChange(title: "Change the display to \(Self.edidName(value, in: s))?",
                                                    message: "The remote machine sees its monitor unplugged and plugged in again, and may change resolution.",
                                                    button: "Change") {
                                model.apply("Changing the EDID…", optimistic: { $0.edid = value }) { try await $0.setEDID(value) }
                            }
                        })) {
                            if edid.isEmpty { Text("Unknown").tag("") }
                            ForEach(NanoKVMEDID.builtIn) { Text($0.label).tag($0.id) }
                            if !s.customEDIDs.isEmpty {
                                Divider()
                                ForEach(s.customEDIDs, id: \.self) { Text($0).tag($0) }
                            }
                            if !edid.isEmpty, !NanoKVMEDID.builtIn.contains(where: { $0.id == edid }), !s.customEDIDs.contains(edid) {
                                Text(edid).tag(edid)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func system(_ s: NanoKVMSettings) -> some View {
        if s.swapMB != nil || s.timeZone != nil || s.lowPower != nil {
            Section("System") {
                if let tz = s.timeZone {
                    row(help: "Used for the time on its screen and in its logs.") {
                        Picker("Time zone", selection: Binding(get: { tz }, set: { value in
                            model.apply("Changing the time zone…", optimistic: { $0.timeZone = value }) { try await $0.setTimeZone(value) }
                        })) {
                            ForEach(Self.including(tz, in: TimeZone.knownTimeZoneIdentifiers.sorted()), id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                if let on = s.lowPower {
                    row(help: "Saves power by slowing the NanoKVM down while nobody is using it.") {
                        Toggle("Low power mode", isOn: Binding(get: { on }, set: { value in
                            model.apply("Changing low power mode…", optimistic: { $0.lowPower = value }) { try await $0.setLowPower(value) }
                        }))
                    }
                }
                if let swap = s.swapMB {
                    row(help: "A swap file on the SD card gives the NanoKVM more memory, at the cost of SD card wear.") {
                        Picker("Swap", selection: Binding(get: { swap }, set: { value in
                            model.apply("Changing swap…", optimistic: { $0.swapMB = value }) { try await $0.setSwap(megabytes: value) }
                        })) {
                            ForEach(Self.including(swap, in: NanoKVMSettings.swapChoices), id: \.self) { Text($0 == 0 ? "Off" : "\($0) MB").tag($0) }
                        }
                    }
                }
            }
        }
    }

    private func row<Content: View>(help: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Changes

    private func saveHostname() {
        let name = model.hostnameDraft.trimmingCharacters(in: .whitespaces)
        guard name != model.settings.hostname, NanoKVMSettings.isValidHostname(name) else { return }
        model.apply("Changing the host name…") { try await $0.setHostname(name) }
    }

    private func saveWebTitle() {
        let title = model.webTitleDraft
        guard title != model.settings.webTitle else { return }
        model.apply("Changing the web page title…") { try await $0.setWebTitle(title) }
    }

    private func saveIdleTimeout() {
        let minutes = model.idleTimeoutDraft
        guard minutes != model.settings.hdmiIdleTimeoutMinutes,
              (0...NanoKVMSettings.maxHDMIIdleTimeoutMinutes).contains(minutes) else { return }
        model.apply("Changing the idle timeout…") { try await $0.setHDMIIdleTimeout(minutes: minutes) }
    }

    private func setMDNS(_ on: Bool, device: Device?) {
        let change = {
            model.apply(on ? "Turning mDNS on…" : "Turning mDNS off…", optimistic: { $0.mdns = on }) { try await $0.setMDNS(on) }
        }
        let usesLocalName = device?.endpoints.contains { $0.host.lowercased().contains(".local") } ?? false
        if !on && usesLocalName {
            pending = PendingChange(title: "Turn mDNS off?",
                                    message: "This device's address in the app is a .local name, which stops working without mDNS. Change it to an IP address first.",
                                    button: "Turn Off", destructive: true, run: change)
        } else {
            change()
        }
    }

    private func setHIDMode(_ mode: NanoKVMHIDMode) {
        guard mode != model.settings.hidMode else { return }
        let label = mode == .hidOnly ? "keyboard and mouse only" : "keyboard, mouse and more"
        if model.isPro {
            pending = PendingChange(title: "Change USB devices to \(label)?",
                                    message: "The NanoKVM reconnects its USB, so the remote machine loses its keyboard and mouse for a moment.",
                                    button: "Change") {
                model.apply("Changing USB devices…", optimistic: { $0.hidMode = mode }) { try await $0.setHIDMode(mode) }
            }
        } else {
            pending = PendingChange(title: "Change USB devices to \(label)?",
                                    message: "The NanoKVM reboots to do this, so its consoles disconnect for a minute. The remote machine keeps running.",
                                    button: "Change and Reboot", destructive: true) {
                model.applyAndDisconnect("Changing USB devices…",
                                         notice: "The NanoKVM is rebooting with the new USB devices. Reconnect in a minute.") {
                    try await $0.setHIDMode(mode)
                }
            }
        }
    }

    private func confirmUSB(_ title: String, run: @escaping () -> Void) {
        pending = PendingChange(title: title,
                                message: "The NanoKVM reconnects its USB, so the remote machine loses its keyboard and mouse for a moment.",
                                button: "Change", run: run)
    }

    private func confirmReboot(_ device: Device?) {
        let name = device?.name ?? "the NanoKVM"
        pending = PendingChange(title: "Reboot \(name)?",
                                message: "Its consoles disconnect for a minute or two. The machine it controls keeps running.",
                                button: "Reboot", destructive: true) {
            model.applyAndDisconnect("Rebooting…", notice: "The NanoKVM is rebooting. Reconnect in a minute or two.") {
                try await $0.reboot()
            }
        }
    }

    // MARK: Labels

    private static func including<T: Equatable>(_ value: T, in choices: [T]) -> [T] {
        choices.contains(value) ? choices : choices + [value]
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds == 0 { return "Never" }
        if seconds < 60 { return "\(seconds) seconds" }
        if seconds < 3600 { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        return seconds == 3600 ? "1 hour" : "\(seconds / 3600) hours"
    }

    private static func diskName(_ disk: NanoKVMProDisk) -> String {
        switch disk {
        case .off: return "None"
        case .sdCard: return "SD card"
        case .emmc: return "Built-in storage (eMMC)"
        }
    }

    private static func edidName(_ id: String, in s: NanoKVMSettings) -> String {
        NanoKVMEDID.builtIn.first { $0.id == id }?.label ?? id
    }
}
