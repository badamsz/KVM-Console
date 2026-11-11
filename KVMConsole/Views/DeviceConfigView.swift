import AppKit
import Observation
import PiKVMKit
import SwiftUI

struct ConfigRequest: Identifiable {
    let deviceID: UUID
    var id: UUID { deviceID }
}

/// Reads and changes a PiKVM's configuration (override.yaml and a few
/// services) through a root shell in its web terminal.
@MainActor
@Observable
final class DeviceConfigModel {
    enum Phase: Equatable {
        case signIn
        case connecting
        case ready
    }

    struct Problem: Equatable {
        var message: String
        var details: String?
    }

    struct Validation: Equatable {
        var ok: Bool
        var message: String
        var details: String?
    }

    private(set) var phase: Phase = .signIn
    /// What is running right now, for the status line.
    private(set) var busy: String?
    var problem: Problem?
    private(set) var wrongPassword = false

    /// override.yaml as it is on the device.
    private(set) var savedText = ""
    /// The editor's text.
    var editorText = ""
    private(set) var validation: Validation?
    private(set) var effective: [String: JSONValue] = [:]
    private(set) var effectiveError: String?
    private(set) var overridden: Set<String> = []
    private(set) var dropIns: [String] = []
    private(set) var backups: [ConfigBackup] = []
    private(set) var units: [String: ConfigUnitState] = [:]
    private(set) var hasRuamel = true
    /// Setting changes not yet applied: path → new value (`.null` = use kvmd's default).
    var pending: [String: JSONValue] = [:]
    private(set) var lastSave: ConfigHelperResponse?
    private(set) var backupPreview: (name: String, text: String)?

    private var configurator: DeviceConfigurator?
    private weak var session: DeviceSession?

    var isBusy: Bool { busy != nil }
    var editorChanged: Bool { editorText != savedText }
    /// Catalog options the device's kvmd knows about.
    var options: [ConfigOption] { ConfigOption.catalog.filter { effective[$0.path] != nil } }
    var pendingNeedsReboot: Bool { ConfigOption.catalog.contains { pending[$0.path] != nil && $0.needsReboot } }

    func value(_ option: ConfigOption) -> JSONValue? {
        if let p = pending[option.path], p != .null { return p }
        return effective[option.path]
    }

    // MARK: Connecting

    func connect(session: DeviceSession, rootPassword: String) async {
        guard phase == .signIn else { return }
        self.session = session
        phase = .connecting
        problem = nil
        wrongPassword = false
        await session.connectIfNeeded()
        guard let client = session.client else {
            if case .failed(let message) = session.status { problem = Problem(message: message) } else { problem = Problem(message: "Not connected.") }
            phase = .signIn
            return
        }
        do {
            configurator = try await DeviceConfigurator.connect(client: client, rootPassword: rootPassword)
        } catch RootShellError.wrongRootPassword {
            wrongPassword = true
            phase = .signIn
            return
        } catch {
            problem = Problem(message: "Couldn't open a root shell: \(error.localizedDescription)")
            phase = .signIn
            return
        }
        phase = .ready
        await reload()
    }

    func close() {
        let c = configurator
        configurator = nil
        Task { await c?.close() }
    }

    /// Runs one step against the device, showing `label` while it runs.
    private func perform<T>(_ label: String, _ body: (DeviceConfigurator) async throws -> T) async -> T? {
        guard let configurator, busy == nil else { return nil }
        busy = label
        problem = nil
        defer { busy = nil }
        do {
            return try await body(configurator)
        } catch let error as DeviceConfigError {
            problem = Problem(message: error.message, details: error.details)
        } catch RootShellError.closed {
            // kvmd-nginx restarted, or the PiKVM rebooted.
            self.configurator = nil
            phase = .signIn
            problem = Problem(message: "The connection to the PiKVM's web terminal closed. Connect again to continue.")
        } catch {
            problem = Problem(message: error.localizedDescription)
        }
        return nil
    }

    func reload() async {
        guard let r = await perform("Reading the configuration…", { try await $0.load(paths: ConfigOption.catalog.map(\.path)) }) else { return }
        savedText = r.text ?? ""
        editorText = savedText
        effective = r.effective ?? [:]
        effectiveError = r.effectiveError
        overridden = Set(r.overridden ?? [])
        dropIns = r.overrideD ?? []
        backups = r.backups ?? []
        units = r.units ?? [:]
        hasRuamel = r.hasRuamel ?? true
        pending = [:]
        validation = nil
    }

    // MARK: Settings

    /// Writes the pending setting changes into the editor's YAML. With
    /// `save`, also saves and restarts.
    func applyPending(save: Bool) async {
        guard !pending.isEmpty else { return }
        let patch = pending
        guard let text = await perform("Preparing the change…", { try await $0.merge(self.editorText, patch: patch) }) else { return }
        editorText = text
        pending = [:]
        if save { await saveEditor() }
    }

    func setService(_ unit: String, enabled: Bool) async {
        if let u = await perform(enabled ? "Turning on \(unit)…" : "Turning off \(unit)…", { try await $0.setService(unit, enabled: enabled) }) {
            units = u
        }
    }

    // MARK: Editor

    func validateEditor() async {
        let text = editorText
        validation = nil
        if let r = await perform("Checking with kvmd…", { try await $0.validate(text) }) {
            let count = r.changed?.count ?? 0
            validation = Validation(ok: true, message: count == 0 ? "Valid. No settings change." : "Valid. \(count) setting\(count == 1 ? "" : "s") change.",
                                    details: r.changed?.joined(separator: "\n"))
        } else if let p = problem {
            validation = Validation(ok: false, message: p.message, details: p.details)
            problem = nil
        }
    }

    func saveEditor() async {
        let text = editorText
        validation = nil
        guard let r = await perform("Saving and restarting services…", { try await $0.save(text) }) else {
            if let p = problem {
                validation = Validation(ok: false, message: p.message, details: p.details)
            }
            return
        }
        finishInstall(r)
    }

    // MARK: Backups

    func preview(_ backup: ConfigBackup) async {
        if let text = await perform("Reading the backup…", { try await $0.backupText(backup.name) }) {
            backupPreview = (backup.name, text)
        }
    }

    func restore(_ backup: ConfigBackup) async {
        if let r = await perform("Restoring \(backup.name)…", { try await $0.restore(backup.name) }) {
            finishInstall(r)
        }
    }

    private func finishInstall(_ r: ConfigHelperResponse) {
        lastSave = r
        if r.rolledBack == true {
            problem = Problem(message: r.error ?? "The change was rolled back.", details: r.details)
        }
        Task {
            await reload()
            // kvmd restarted: refresh what the app knows (features may have changed).
            if r.restarted?.contains("kvmd") == true, let session {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await session.connect()
            }
        }
    }

    func reboot() async {
        if await perform("Rebooting…", { try await $0.reboot() }) != nil {
            close()
            phase = .signIn
            lastSave = nil
            problem = Problem(message: "The PiKVM is rebooting. It takes a minute or two; the app reconnects by itself.")
        }
    }
}

struct DeviceConfigView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let deviceID: UUID

    @State private var model = DeviceConfigModel()
    @State private var rootPassword = ""
    @State private var remember = true
    @State private var tab = Tab.settings
    @State private var confirmApply = false
    @State private var confirmSave = false
    @State private var confirmReboot = false
    @State private var backupToRestore: ConfigBackup?
    @State private var selectedBackup: ConfigBackup.ID?

    enum Tab: Hashable { case settings, file, backups }

    var body: some View {
        let device = app.device(deviceID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Configure \(device?.name ?? "PiKVM")").font(.title2).bold()

            switch model.phase {
            case .signIn, .connecting:
                signIn(device)
            case .ready:
                TabView(selection: $tab) {
                    settingsTab.tabItem { Text("Settings") }.tag(Tab.settings)
                    fileTab.tabItem { Text("override.yaml") }.tag(Tab.file)
                    backupsTab.tabItem { Text("Backups") }.tag(Tab.backups)
                }
            }

            statusArea
            HStack {
                if model.phase == .ready {
                    Button { Task { await model.reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(model.isBusy)
                    Button("Reboot PiKVM…") { confirmReboot = true }.disabled(model.isBusy)
                }
                Spacer()
                if model.phase == .ready {
                    Button("Done") { close() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
                } else {
                    Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                    Button("Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(rootPassword.isEmpty || model.phase == .connecting)
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: model.phase == .ready ? 640 : nil)
        .onAppear {
            if let saved = app.credentials.password(for: deviceID, kind: .root) { rootPassword = saved }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .ready, remember { app.credentials.setPassword(rootPassword, for: deviceID, kind: .root) }
        }
        .onChange(of: model.wrongPassword) { _, wrong in
            if wrong { app.credentials.deletePassword(for: deviceID, kind: .root) }
        }
        .confirmationDialog("Reboot \(device?.name ?? "the PiKVM")?", isPresented: $confirmReboot) {
            Button("Reboot", role: .destructive) { Task { await model.reboot() } }
        } message: {
            Text(device?.hasSwitch == true
                 ? "Consoles to every machine on its Switch disconnect for a minute or two. The machines themselves keep running."
                 : "Its consoles disconnect for a minute or two. The machine it controls keeps running.")
        }
    }

    private func connect() {
        guard !rootPassword.isEmpty else { return }
        Task { await model.connect(session: app.session(for: deviceID), rootPassword: rootPassword) }
    }

    private func close() {
        model.close()
        dismiss()
    }

    // MARK: Sign in

    @ViewBuilder private func signIn(_ device: Device?) -> some View {
        Text("Settings live in /etc/kvmd/override.yaml on the PiKVM. The app changes it as root through the PiKVM's web terminal, checks every change with kvmd before saving, keeps a backup of each version, and puts the old file back if kvmd doesn't start.")
            .fixedSize(horizontal: false, vertical: true)
        SecureField("Root password", text: $rootPassword, prompt: Text("The PiKVM's root (SSH) password"))
            .onSubmit(connect)
            .disabled(model.phase == .connecting)
        Toggle("Remember in Keychain", isOn: $remember)
        if model.wrongPassword {
            Label("The root password was rejected.", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
        if model.phase == .connecting {
            HStack { ProgressView().controlSize(.small); Text("Opening a root shell…") }
        }
    }

    // MARK: Settings tab

    private var settingsTab: some View {
        VStack(spacing: 0) {
            Form {
                if let error = model.effectiveError {
                    Label("kvmd couldn't read its configuration: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(ConfigOption.Group.allCases, id: \.self) { group in
                    let options = model.options.filter { $0.group == group }
                    if !options.isEmpty {
                        Section(group.rawValue) {
                            ForEach(options) { option in optionRow(option) }
                        }
                    }
                }
                if !model.units.isEmpty {
                    Section("Services") {
                        serviceToggle("kvmd-vnc", "VNC server", help: "Lets VNC clients connect on port 5900.")
                        serviceToggle("kvmd-ipmi", "IPMI server", help: "Lets ipmitool control ATX power over the network.")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !model.pending.isEmpty {
                    Text("\(model.pending.count) change\(model.pending.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Button("Discard") { model.pending = [:] }
                }
                Spacer()
                Button("Edit in override.yaml") {
                    Task {
                        await model.applyPending(save: false)
                        tab = .file
                    }
                }
                .disabled(model.pending.isEmpty || model.isBusy)
                .help("Write these changes into the file without saving, to review them first.")
                Button("Apply…") { confirmApply = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pending.isEmpty || model.isBusy || model.editorChanged)
                    .help(model.editorChanged ? "Save or revert the unsaved edits in override.yaml first." : "")
            }
            .padding(.top, 8)
        }
        .confirmationDialog("Apply \(model.pending.count) change\(model.pending.count == 1 ? "" : "s")?", isPresented: $confirmApply) {
            Button("Apply") { Task { await model.applyPending(save: true) } }
        } message: {
            Text(applySummary)
        }
    }

    private var applySummary: String {
        var lines = ConfigOption.catalog.compactMap { option -> String? in
            guard let new = model.pending[option.path] else { return nil }
            return "\(option.title): \(describe(model.effective[option.path], option)) → \(new == .null ? "default" : describe(new, option))"
        }
        lines.append("")
        lines.append("override.yaml is checked with kvmd and backed up first, then kvmd restarts (consoles reconnect).")
        if model.pendingNeedsReboot { lines.append("USB device changes take effect after the PiKVM reboots.") }
        return lines.joined(separator: "\n")
    }

    private func describe(_ value: JSONValue?, _ option: ConfigOption) -> String {
        switch (value, option.kind) {
        case (nil, _): return "unset"
        case (.bool(let b)?, .toggle): return b ? "on" : "off"
        case (.string(let s)?, .choice(let choices)): return choices.first { $0.value == s }?.label ?? s
        case (let v?, .number(_, _, _, let unit)): return "\(Self.int(v))" + (unit.map { " \($0)" } ?? "")
        case (let v?, _): return "\(v)"
        }
    }

    private static func int(_ v: JSONValue?) -> Int {
        switch v {
        case .number(let n)?: return Int(n)
        case .bool(let b)?: return b ? 1 : 0
        case .string(let s)?: return Int(s) ?? 0
        default: return 0
        }
    }

    private static func string(_ v: JSONValue?) -> String {
        if case .string(let s)? = v { return s }
        return ""
    }

    /// The offered choices, plus the current value if it is something else
    /// (for example an ATX type other than GPIO).
    private static func choices(_ choices: [ConfigOption.Choice], including current: String) -> [ConfigOption.Choice] {
        if current.isEmpty || choices.contains(where: { $0.value == current }) { return choices }
        return choices + [ConfigOption.Choice(current, current)]
    }

    @ViewBuilder private func optionRow(_ option: ConfigOption) -> some View {
        let pendingDefault = model.pending[option.path] == .null
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                control(option)
                if model.overridden.contains(option.path) && !pendingDefault {
                    Menu {
                        Button("Use kvmd's Default") { model.pending[option.path] = .null }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Set in override.yaml")
                }
            }
            if pendingDefault {
                Text("Will go back to kvmd's default when applied.").font(.caption).foregroundStyle(.orange)
            } else if model.pending[option.path] != nil && option.needsReboot {
                Text("Takes effect after a reboot.").font(.caption).foregroundStyle(.orange)
            } else if !option.help.isEmpty {
                Text(option.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func control(_ option: ConfigOption) -> some View {
        switch option.kind {
        case .toggle:
            Toggle(option.title, isOn: Binding(
                get: { if case .bool(let b)? = model.value(option) { return b }; return Self.int(model.value(option)) != 0 },
                set: { model.pending[option.path] = .bool($0) }))
        case .number(let min, let max, let step, let unit):
            let binding = Binding<Int>(
                get: { Self.int(model.value(option)) },
                set: { model.pending[option.path] = .number(Double(Swift.min(max, Swift.max(min, $0)))) })
            LabeledContent(option.title) {
                HStack(spacing: 4) {
                    TextField(option.title, value: binding, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Stepper(option.title, value: binding, in: min...max, step: step).labelsHidden()
                    if let unit { Text(unit).foregroundStyle(.secondary) }
                }
            }
        case .choice(let choices):
            let current = Self.string(model.value(option))
            Picker(option.title, selection: Binding(
                get: { current },
                set: { model.pending[option.path] = .string($0) })) {
                ForEach(Self.choices(choices, including: current), id: \.value) { Text($0.label).tag($0.value) }
            }
        }
    }

    @ViewBuilder private func serviceToggle(_ unit: String, _ title: String, help: String) -> some View {
        if let state = model.units[unit], state.exists != false {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(title, isOn: Binding(
                    get: { state.enabled },
                    set: { on in Task { await model.setService(unit, enabled: on) } }))
                .disabled(model.isBusy)
                Text(help + (state.enabled && !state.active ? " Enabled, but not running." : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: File tab

    private var fileTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applied after every other config file. Group options under one section; see docs.pikvm.org/config.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.dropIns.isEmpty {
                Text("Also loaded before this file, from /etc/kvmd/override.d: \(model.dropIns.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.hasRuamel {
                Text("This PiKVM OS is old: changes made on the Settings tab rewrite the file without its comments.")
                    .font(.caption).foregroundStyle(.orange)
            }
            PlainTextEditor(text: $model.editorText)
                .border(Color(nsColor: .separatorColor))
            if let v = model.validation {
                VStack(alignment: .leading, spacing: 4) {
                    Label(v.message, systemImage: v.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(v.ok ? .green : .red)
                    if let details = v.details, !details.isEmpty {
                        ScrollView {
                            Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                    }
                }
            }
            HStack {
                Button("Revert") { model.editorText = model.savedText }
                    .disabled(!model.editorChanged || model.isBusy)
                Spacer()
                Button("Check") { Task { await model.validateEditor() } }
                    .disabled(model.isBusy)
                    .help("Ask kvmd whether it accepts this file, without saving.")
                Button("Save and Restart…") { confirmSave = true }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.editorChanged || model.isBusy)
            }
        }
        .padding(8)
        .confirmationDialog("Save override.yaml?", isPresented: $confirmSave) {
            Button("Save and Restart") { Task { await model.saveEditor() } }
        } message: {
            Text("kvmd checks the file first and the current version is backed up. Then the services that read the changed sections restart, and consoles reconnect. If kvmd doesn't start, the previous file is put back.")
        }
    }

    // MARK: Backups tab

    private var backupsTab: some View {
        HStack(spacing: 12) {
            List(model.backups, selection: $selectedBackup) { backup in
                VStack(alignment: .leading) {
                    Text(backup.date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? backup.name)
                    Text("\(backup.size) bytes").font(.caption).foregroundStyle(.secondary)
                }
                .tag(backup.id)
            }
            .frame(width: 230)
            .overlay {
                if model.backups.isEmpty {
                    Text("No backups yet. One is made each time the app saves override.yaml.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                }
            }
            .onChange(of: selectedBackup) { _, id in
                if let backup = model.backups.first(where: { $0.id == id }) { Task { await model.preview(backup) } }
            }

            VStack(alignment: .leading, spacing: 8) {
                if let preview = model.backupPreview, preview.name == selectedBackup {
                    ScrollView {
                        Text(preview.text.isEmpty ? "(empty file)" : preview.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .border(Color(nsColor: .separatorColor))
                    HStack {
                        Button("Open in Editor") {
                            model.editorText = preview.text
                            tab = .file
                        }
                        .help("Load this version into the override.yaml tab to look at or edit before saving.")
                        Spacer()
                        Button("Restore…") { backupToRestore = model.backups.first { $0.name == preview.name } }
                            .disabled(model.isBusy)
                    }
                } else {
                    Text("Select a backup to see it.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(8)
        .confirmationDialog("Restore this version of override.yaml?", isPresented: Binding(
            get: { backupToRestore != nil }, set: { if !$0 { backupToRestore = nil } }), presenting: backupToRestore) { backup in
            Button("Restore and Restart") { Task { await model.restore(backup) } }
        } message: { _ in
            Text("The current file is backed up first, so this can be undone.")
        }
    }

    // MARK: Status

    @ViewBuilder private var statusArea: some View {
        if let busy = model.busy {
            HStack { ProgressView().controlSize(.small); Text(busy) }
        } else if let problem = model.problem {
            VStack(alignment: .leading, spacing: 4) {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let details = problem.details, !details.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView {
                            Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }
        } else if let save = model.lastSave, model.phase == .ready {
            saveSummary(save)
        }
    }

    @ViewBuilder private func saveSummary(_ save: ConfigHelperResponse) -> some View {
        if save.unchanged == true {
            Label("Nothing to save: the file is unchanged.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else if save.ok {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    let restarted = save.restarted ?? []
                    Label(save.restoredFrom.map { "Restored \($0)." } ?? "Saved.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text((restarted.isEmpty ? "No services needed a restart." : "Restarted \(restarted.joined(separator: ", ")).")
                         + (save.backup.map { " Previous version backed up as \($0)." } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if save.rebootRequired == true {
                        Text("USB device changes take effect after the PiKVM reboots.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if save.rebootRequired == true {
                    Button("Reboot Now…") { confirmReboot = true }
                }
            }
        }
    }
}

/// A plain-text editor for YAML: monospaced, with smart quotes, dashes and
/// spelling correction off (TextEditor would turn ' into ’).
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.delegate = context.coordinator
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
