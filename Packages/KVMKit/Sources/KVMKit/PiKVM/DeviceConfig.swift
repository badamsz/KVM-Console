import Foundation

// PiKVM configuration: /etc/kvmd/override.yaml and a few services.
//
// kvmd's HTTP API has no way to read or change its configuration, and the
// file lives on a filesystem PiKVM OS keeps read-only. So, like the OS
// updater, this works through the web terminal as root: a small Python
// helper (Resources/pikvm_config_helper.py) is sent along with each request
// and does the work on the device. It validates with kvmd itself
// (`kvmd -m --override-config <candidate>`), remounts the filesystem
// read-write only while writing, keeps dated backups in
// /etc/kvmd/pikvm-console-backups, restarts the services that read the
// changed sections, and puts the previous file back if a restarted service
// doesn't come up.

/// One setting the app offers as a control. Anything else is edited as YAML.
public struct ConfigOption: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case usb = "USB devices"
        case video = "Video"
        case hid = "Keyboard and mouse"
        case features = "Features"
    }

    public struct Choice: Hashable, Sendable {
        public let value: String
        public let label: String
        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    public enum Kind: Hashable, Sendable {
        case toggle
        case number(min: Int, max: Int, step: Int, unit: String?)
        case choice([Choice])
    }

    /// The key path in the config, `/`-separated (as in `kvmd-override`).
    public let path: String
    public let title: String
    public let help: String
    public let group: Group
    public let kind: Kind
    /// Changes take effect only after the PiKVM reboots (the USB gadget is built at boot).
    public let needsReboot: Bool

    public var id: String { path }

    public init(_ path: String, _ title: String, group: Group, kind: Kind, needsReboot: Bool = false, help: String = "") {
        self.path = path
        self.title = title
        self.help = help
        self.group = group
        self.kind = kind
        self.needsReboot = needsReboot
    }

    /// The settings shown as controls. Options the device's kvmd doesn't
    /// know (older PiKVM OS) are hidden.
    public static let catalog: [ConfigOption] = [
        ConfigOption("otg/devices/audio/enabled", "USB audio", group: .usb, kind: .toggle, needsReboot: true,
                     help: "The remote machine sees a USB sound card. Needed to send this Mac's microphone."),
        ConfigOption("otg/devices/camera/enabled", "USB webcam", group: .usb, kind: .toggle, needsReboot: true,
                     help: "The remote machine sees a USB webcam. Needed to send this Mac's camera."),
        ConfigOption("otg/devices/ethernet/enabled", "USB Ethernet", group: .usb, kind: .toggle, needsReboot: true,
                     help: "A network link between the PiKVM and the remote machine over USB."),
        ConfigOption("otg/devices/serial/enabled", "USB serial port", group: .usb, kind: .toggle, needsReboot: true,
                     help: "A serial console between the PiKVM and the remote machine."),
        ConfigOption("otg/devices/drives/enabled", "Extra USB flash drives", group: .usb, kind: .toggle, needsReboot: true,
                     help: "Additional virtual drives besides the main one."),
        ConfigOption("otg/devices/drives/count", "Number of extra drives", group: .usb,
                     kind: .number(min: 1, max: 4, step: 1, unit: nil), needsReboot: true),
        ConfigOption("otg/devices/msd/start", "Virtual drive at startup", group: .usb, kind: .toggle, needsReboot: true,
                     help: "Present the virtual (ISO) drive to the remote machine when the PiKVM starts."),

        ConfigOption("kvmd/streamer/quality", "JPEG quality", group: .video,
                     kind: .number(min: 1, max: 100, step: 5, unit: "%"),
                     help: "MJPEG picture quality. The console can change it for the session; this is the startup value."),
        ConfigOption("kvmd/streamer/desired_fps/default", "Frame rate", group: .video,
                     kind: .number(min: 0, max: 120, step: 5, unit: "fps"), help: "0 means as fast as possible."),
        ConfigOption("kvmd/streamer/h264_bitrate/default", "H.264 bitrate", group: .video,
                     kind: .number(min: 25, max: 20000, step: 500, unit: "kbps")),
        ConfigOption("kvmd/streamer/h264_gop/default", "H.264 keyframe interval", group: .video,
                     kind: .number(min: 0, max: 60, step: 5, unit: "frames")),
        ConfigOption("kvmd/streamer/forever", "Keep video running", group: .video, kind: .toggle,
                     help: "Run the video capture all the time instead of only while someone watches. Previews are faster; the PiKVM uses more power."),

        ConfigOption("kvmd/hid/jiggler/enabled", "Allow mouse jiggler", group: .hid, kind: .toggle,
                     help: "Lets the jiggler be turned on to keep the remote machine awake."),
        ConfigOption("kvmd/hid/jiggler/active", "Jiggler on at startup", group: .hid, kind: .toggle),
        ConfigOption("kvmd/hid/jiggler/interval", "Jiggler interval", group: .hid,
                     kind: .number(min: 1, max: 3600, step: 15, unit: "s")),

        ConfigOption("kvmd/atx/type", "ATX power control", group: .features,
                     kind: .choice([Choice("gpio", "On"), Choice("disabled", "Off")]),
                     help: "Turn off on machines without the ATX cable, to hide the power controls."),
        ConfigOption("kvmd/msd/type", "Virtual drive (ISO mounting)", group: .features,
                     kind: .choice([Choice("otg", "On"), Choice("disabled", "Off")])),
    ]
}

/// A saved copy of override.yaml on the device.
public struct ConfigBackup: Decodable, Hashable, Sendable, Identifiable {
    public let name: String
    public let size: Int
    public var id: String { name }

    /// When it was made, parsed from its name (the device's local time).
    public var date: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(name.prefix(15)))
    }
}

public struct ConfigUnitState: Decodable, Hashable, Sendable {
    public let enabled: Bool
    public let active: Bool
    public let exists: Bool?
}

/// The helper's reply. Which fields are set depends on the request.
public struct ConfigHelperResponse: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    /// kvmd's own message, or a service log.
    public let details: String?
    public let text: String?
    public let overrideD: [String]?
    public let effective: [String: JSONValue]?
    public let effectiveError: String?
    public let overridden: [String]?
    public let backups: [ConfigBackup]?
    public let units: [String: ConfigUnitState]?
    public let rootReadOnly: Bool?
    public let hasRuamel: Bool?
    public let commentsLost: Bool?
    public let changed: [String]?
    public let sections: [String]?
    public let restarted: [String]?
    public let rebootRequired: Bool?
    public let backup: String?
    public let unchanged: Bool?
    public let rolledBack: Bool?
    public let restoredFrom: String?
}

public struct DeviceConfigError: Error, LocalizedError, Sendable {
    public let message: String
    public let details: String?
    public var errorDescription: String? { message }
}

/// Talks to the configuration helper on one PiKVM through a root shell.
public actor DeviceConfigurator {
    private let shell: RootShell

    public init(shell: RootShell) {
        self.shell = shell
    }

    public static func connect(client: KVMDClient, rootPassword: String) async throws -> DeviceConfigurator {
        DeviceConfigurator(shell: try await RootShell.open(client: client, rootPassword: rootPassword))
    }

    public func close() async { await shell.close() }

    public static var helperSource: String {
        guard let url = Bundle.module.url(forResource: "pikvm_config_helper", withExtension: "py"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("pikvm_config_helper.py is missing from KVMKit's resources")
        }
        return text
    }

    /// The shell script that runs the helper with `request`.
    static func script(request: [String: JSONValue], helper: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(JSONValue.object(request)), as: UTF8.self)
        return "umask 077\n"
            + "cat >/tmp/pkc-req.json <<'PKC_REQ'\n\(json)\nPKC_REQ\n"
            + "python3 - /tmp/pkc-req.json <<'PKC_PY'\n\(helper)\nPKC_PY\n"
            + "rc=$?\nrm -f /tmp/pkc-req.json\nexit $rc\n"
    }

    /// Finds the helper's result line in the job output.
    static func parse(output: String, code: Int) throws -> ConfigHelperResponse {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("PKC_JSON:") }) else {
            let tail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000)
            throw DeviceConfigError(message: "The configuration helper didn't finish (exit code \(code)).",
                                    details: tail.isEmpty ? nil : String(tail))
        }
        return try JSONDecoder().decode(ConfigHelperResponse.self, from: Data(line.dropFirst("PKC_JSON:".count).utf8))
    }

    private func call(_ op: String, _ fields: [String: JSONValue] = [:], timeout: TimeInterval = 120) async throws -> ConfigHelperResponse {
        var request = fields
        request["op"] = .string(op)
        let (code, output) = try await shell.run(try Self.script(request: request, helper: Self.helperSource), timeout: timeout)
        let response = try Self.parse(output: output, code: code)
        // A failed save that was rolled back still carries useful fields; the caller looks at it.
        if !response.ok, response.rolledBack != true {
            throw DeviceConfigError(message: response.error ?? "The PiKVM refused the change.", details: response.details)
        }
        return response
    }

    /// The current override.yaml, effective values for `paths`, backups and services.
    public func load(paths: [String]) async throws -> ConfigHelperResponse {
        try await call("load", ["paths": .array(paths.map { .string($0) })])
    }

    /// Checks `text` with kvmd. Throws with kvmd's message if it's rejected.
    public func validate(_ text: String) async throws -> ConfigHelperResponse {
        try await call("validate", ["text": .string(text)])
    }

    /// Applies `patch` (path → value, `.null` to remove) to `text` and
    /// returns the new YAML. Nothing is saved.
    public func merge(_ text: String, patch: [String: JSONValue]) async throws -> String {
        try await call("merge", ["text": .string(text), "patch": .object(patch)]).text ?? text
    }

    /// Validates, backs up the current file, installs `text`, and restarts
    /// the affected services. Check `rolledBack` on the result.
    public func save(_ text: String, restart: Bool = true) async throws -> ConfigHelperResponse {
        try await call("save", ["text": .string(text), "restart": .bool(restart)], timeout: 300)
    }

    public func backupText(_ name: String) async throws -> String {
        try await call("backup", ["name": .string(name)]).text ?? ""
    }

    /// Puts a backup back (backing up the current file first) and restarts.
    public func restore(_ name: String, restart: Bool = true) async throws -> ConfigHelperResponse {
        try await call("restore", ["name": .string(name), "restart": .bool(restart)], timeout: 300)
    }

    public func setService(_ unit: String, enabled: Bool) async throws -> [String: ConfigUnitState] {
        try await call("service", ["unit": .string(unit), "enabled": .bool(enabled)]).units ?? [:]
    }

    /// Reboots the PiKVM two seconds from now.
    public func reboot() async throws {
        _ = try await call("reboot")
    }
}
