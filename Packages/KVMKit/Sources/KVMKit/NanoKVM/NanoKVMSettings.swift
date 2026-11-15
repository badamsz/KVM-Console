import Foundation

// Device settings on Sipeed devices: what the NanoKVM web page shows under
// Settings > Device (and Settings > Screen > EDID on the Pro). Sources:
// server/router/vm.go, hid.go and application.go in sipeed/NanoKVM and
// sipeed/NanoKVM-Pro.
//
// The two firmwares share most calls but not all:
// * Both: host name, web page title, SSH, mDNS, HID mode, mouse jiggler,
//   OLED sleep, preview updates, USB network adapter, reboot.
// * Classic NanoKVM: HDMI capture on/off (`/api/vm/hdmi/enable|disable`)
//   with an idle timeout, the data partition as a USB disk, swap file size.
// * Pro and Go: HDMI capture and HDMI passthrough, EDID, USB microphone,
//   USB disk from the SD card or eMMC, time zone, low power mode.
// Every setting is read on its own, and a setting the device doesn't answer
// for (an older firmware, a model without the hardware) is left nil, so the
// app only shows what this device has.
//
// Unlike kvmd's config, every change applies at once and persists; there is
// no file to edit and nothing to restart, except where noted.

/// Whether the NanoKVM shows the remote machine a keyboard and mouse only.
public enum NanoKVMHIDMode: String, Sendable, CaseIterable, Hashable {
    /// Keyboard, mouse, and the USB drive and network adapter if turned on.
    case normal
    /// Keyboard and mouse only, for BIOSes that get confused by composite
    /// USB devices.
    case hidOnly = "hid-only"
}

/// The NanoKVM's built-in mouse jiggler, which keeps the remote machine awake.
public enum NanoKVMJiggler: String, Sendable, CaseIterable, Hashable {
    case off, relative, absolute
}

/// Which storage a NanoKVM Pro or Go shows the remote machine as a USB disk.
public enum NanoKVMProDisk: String, Sendable, CaseIterable, Hashable {
    case off = ""
    case sdCard = "sdcard"
    case emmc
}

/// A NanoKVM Pro's built-in EDID (the display the remote machine sees).
public struct NanoKVMEDID: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String

    /// The Pro's built-in EDIDs, labelled the way its web page labels them.
    public static let builtIn: [NanoKVMEDID] = [
        NanoKVMEDID(id: "E18-4K30FPS", label: "3840 × 2160, 30 Hz"),
        NanoKVMEDID(id: "E48-4K39FPS", label: "3840 × 2160, 39 Hz"),
        NanoKVMEDID(id: "E56-2K60FPS", label: "2560 × 1440, 60 Hz"),
        NanoKVMEDID(id: "E54-1080P60FPS", label: "1920 × 1080, 60 Hz"),
        NanoKVMEDID(id: "E58-4K16-10", label: "3840 × 2400, 30 Hz"),
        NanoKVMEDID(id: "E63-Ultrawide", label: "3440 × 1440, 60 Hz"),
    ]
}

/// A Sipeed device's settings. Nil means the device doesn't have the
/// setting (or didn't say), so it isn't shown.
public struct NanoKVMSettings: Sendable, Equatable {
    // General
    public var hostname: String?
    public var webTitle: String?
    public var ssh: Bool?
    public var mdns: Bool?
    /// Offers beta releases when the NanoKVM checks for updates.
    public var previewUpdates: Bool?

    // Keyboard and mouse
    public var hidMode: NanoKVMHIDMode?
    public var jiggler: NanoKVMJiggler?

    // The device's own screen
    /// Seconds before the OLED (or the Pro's LCD) turns off; 0 = never.
    /// Nil when the device has no screen.
    public var screenSleepSeconds: Int?

    // USB devices shown to the remote machine
    /// The USB network adapter (RNDIS on the NanoKVM, NCM on the Pro).
    public var usbNetwork: Bool?
    /// Classic NanoKVM: its data partition, shared as a USB disk.
    public var usbDisk: Bool?
    /// Pro and Go: a USB microphone.
    public var usbMicrophone: Bool?
    /// Pro and Go: the storage shown as a USB disk.
    public var proDisk: NanoKVMProDisk?
    /// Pro and Go: the disks this device has (always includes `.off`).
    public var proDiskChoices: [NanoKVMProDisk] = []
    /// Pro and Go: whether the eMMC disk image exists. Making it (the first
    /// time eMMC is chosen) erases the device's /data, images included.
    public var emmcImageExists = true

    // Video capture
    /// Whether the device captures HDMI at all.
    public var hdmiCapture: Bool?
    /// Classic NanoKVM: minutes without a viewer before capture pauses; 0 = never.
    public var hdmiIdleTimeoutMinutes: Int?
    /// Pro and Go: passes the HDMI input through to the HDMI output.
    public var hdmiPassthrough: Bool?
    /// Pro and Go: the EDID in use (a built-in ID or a custom file name).
    public var edid: String?
    /// Pro and Go: EDID files uploaded on the device's web page.
    public var customEDIDs: [String] = []

    // System
    /// Classic NanoKVM: the swap file's size in MB; 0 = off.
    public var swapMB: Int?
    /// Pro and Go: the IANA time zone, e.g. "Europe/Berlin".
    public var timeZone: String?
    /// Pro and Go: low power mode.
    public var lowPower: Bool?

    public init() {}

    /// The OLED sleep choices the NanoKVM's web page offers, in seconds.
    public static let screenSleepChoices = [0, 15, 30, 60, 180, 300, 600, 1800, 3600]
    /// The swap sizes the NanoKVM's web page offers, in MB.
    public static let swapChoices = [0, 64, 128, 256, 512]
    /// The longest HDMI idle timeout the NanoKVM takes: a week.
    public static let maxHDMIIdleTimeoutMinutes = 10080

    /// Whether a host name is one the NanoKVM can use: 1 to 63 letters,
    /// digits and hyphens, not starting or ending with a hyphen.
    public static func isValidHostname(_ name: String) -> Bool {
        guard (1...63).contains(name.count), !name.hasPrefix("-"), !name.hasSuffix("-") else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }
}

// MARK: - Response shapes

struct NanoKVMEnabled: Decodable { let enabled: Bool }
struct NanoKVMHostname: Decodable { let hostname: String }
struct NanoKVMWebTitle: Decodable { let title: String? }
struct NanoKVMHIDModeData: Decodable { let mode: String }
struct NanoKVMJigglerData: Decodable {
    let enabled: Bool
    let mode: String?
}
struct NanoKVMOLED: Decodable {
    let exist: Bool
    let sleep: Int?
}
struct NanoKVMHDMIState: Decodable {
    let enabled: Bool
    let idleTimeout: Int?
}
struct NanoKVMSwap: Decodable { let size: Int }
struct NanoKVMTimeZone: Decodable { let timezone: String }
struct NanoKVMEDIDData: Decodable { let edid: String? }
struct NanoKVMEDIDList: Decodable { let edidList: [String]? }

/// `/api/vm/device/virtual`: the classic and Pro shapes in one.
struct NanoKVMVirtualDevices: Decodable {
    // Classic
    let network: Bool?
    let disk: Bool?
    // Pro
    let isNetworkEnabled: Bool?
    let isMicEnabled: Bool?
    let mountedDisk: String?
    let isEmmcExist: Bool?
    let isSdCardExist: Bool?
}

extension NanoKVMSettings {
    /// Fills in the USB device settings from either firmware's answer.
    mutating func apply(_ devices: NanoKVMVirtualDevices, family: DeviceFamily) {
        if family == .nanoKVMPro {
            usbNetwork = devices.isNetworkEnabled
            usbMicrophone = devices.isMicEnabled
            if let mounted = devices.mountedDisk {
                proDisk = NanoKVMProDisk(rawValue: mounted) ?? NanoKVMProDisk.off
                // eMMC is always offered (the Pro makes its image on first
                // use, as its web page does); the SD card only when inserted.
                var choices: [NanoKVMProDisk] = [.off, .emmc]
                if devices.isSdCardExist == true || proDisk == .sdCard { choices.append(.sdCard) }
                emmcImageExists = devices.isEmmcExist ?? true
                proDiskChoices = choices
            }
        } else {
            usbNetwork = devices.network
            usbDisk = devices.disk
        }
    }

    /// Fills in the jiggler from its answer.
    mutating func apply(_ jiggler: NanoKVMJigglerData) {
        self.jiggler = jiggler.enabled ? (NanoKVMJiggler(rawValue: jiggler.mode ?? "") ?? .relative) : .off
    }
}

// MARK: - Reading and changing

extension NanoKVMClient {
    /// Reads every setting the device has, at once. Never throws: a setting
    /// that can't be read is left nil.
    public func settings() async -> NanoKVMSettings {
        let pro = family == .nanoKVMPro
        async let hostname = read(NanoKVMHostname.self, "api/vm/hostname")
        async let title = read(NanoKVMWebTitle.self, "api/vm/web-title")
        async let ssh = read(NanoKVMEnabled.self, "api/vm/ssh")
        async let mdns = read(NanoKVMEnabled.self, "api/vm/mdns")
        async let preview = read(NanoKVMEnabled.self, "api/application/preview")
        async let hid = read(NanoKVMHIDModeData.self, "api/hid/mode")
        async let jiggler = read(NanoKVMJigglerData.self, "api/vm/mouse-jiggler")
        async let oled = read(NanoKVMOLED.self, "api/vm/oled")
        async let devices = read(NanoKVMVirtualDevices.self, "api/vm/device/virtual")
        // Classic only
        async let hdmi = read(NanoKVMHDMIState.self, "api/vm/hdmi", if: !pro)
        async let swap = read(NanoKVMSwap.self, "api/vm/swap", if: !pro)
        // Pro and Go only
        async let capture = read(NanoKVMEnabled.self, "api/vm/hdmi/capture", if: pro)
        async let passthrough = read(NanoKVMEnabled.self, "api/vm/hdmi/passthrough", if: pro)
        async let edid = read(NanoKVMEDIDData.self, "api/vm/edid", if: pro)
        async let customEDIDs = read(NanoKVMEDIDList.self, "api/vm/edid/custom", if: pro)
        async let timeZone = read(NanoKVMTimeZone.self, "api/vm/timezone", if: pro)
        async let lowPower = read(NanoKVMEnabled.self, "api/vm/low-power", if: pro)

        var s = NanoKVMSettings()
        s.hostname = await hostname?.hostname
        if let t = await title { s.webTitle = t.title ?? "" }
        s.ssh = await ssh?.enabled
        s.mdns = await mdns?.enabled
        s.previewUpdates = await preview?.enabled
        s.hidMode = await hid.flatMap { NanoKVMHIDMode(rawValue: $0.mode) }
        if let j = await jiggler { s.apply(j) }
        if let o = await oled, o.exist { s.screenSleepSeconds = o.sleep ?? 0 }
        if let d = await devices { s.apply(d, family: family) }
        if let h = await hdmi {
            s.hdmiCapture = h.enabled
            s.hdmiIdleTimeoutMinutes = h.idleTimeout
        }
        s.swapMB = await swap?.size
        if let c = await capture { s.hdmiCapture = c.enabled }
        s.hdmiPassthrough = await passthrough?.enabled
        if let e = await edid { s.edid = e.edid ?? "" }
        s.customEDIDs = (await customEDIDs?.edidList ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        s.timeZone = await timeZone?.timezone
        s.lowPower = await lowPower?.enabled
        return s
    }

    /// One setting, or nil when the device doesn't answer for it.
    private func read<T: Decodable>(_ type: T.Type, _ path: String, if condition: Bool = true) async -> T? {
        guard condition else { return nil }
        return try? await call(T.self, path)
    }

    private func post(_ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws {
        _ = try await call(NanoKVMIgnored.self, path, method: "POST", body: body, timeout: timeout)
    }

    // General

    /// Changes the host name. The mDNS name follows after a reboot.
    public func setHostname(_ name: String) async throws {
        guard NanoKVMSettings.isValidHostname(name) else {
            throw KVMDError.api("A host name has 1 to 63 letters, digits and hyphens, and can't start or end with a hyphen.")
        }
        try await post("api/vm/hostname", ["hostname": name])
    }

    /// The title of the NanoKVM's web page. Empty restores the default.
    public func setWebTitle(_ title: String) async throws {
        try await post("api/vm/web-title", ["title": title])
    }

    public func setSSH(_ on: Bool) async throws {
        try await post(on ? "api/vm/ssh/enable" : "api/vm/ssh/disable", timeout: 30)
    }

    public func setMDNS(_ on: Bool) async throws {
        try await post(on ? "api/vm/mdns/enable" : "api/vm/mdns/disable", timeout: 30)
    }

    public func setPreviewUpdates(_ on: Bool) async throws {
        try await post("api/application/preview", ["enable": on])
    }

    // Keyboard and mouse

    /// Changes the USB devices the remote machine sees. A classic NanoKVM
    /// reboots to do it; the Pro restarts its USB, so either way the
    /// keyboard and mouse drop out for a moment.
    public func setHIDMode(_ mode: NanoKVMHIDMode) async throws {
        do {
            try await post("api/hid/mode", ["mode": mode.rawValue], timeout: 30)
        } catch let error as URLError where family == .nanoKVM {
            // The classic NanoKVM answers and reboots; the answer can be lost.
            if error.code != .timedOut && error.code != .networkConnectionLost { throw error }
        }
    }

    public func setJiggler(_ jiggler: NanoKVMJiggler) async throws {
        let body: [String: Any] = jiggler == .off
            ? ["enabled": false, "mode": NanoKVMJiggler.relative.rawValue]
            : ["enabled": true, "mode": jiggler.rawValue]
        // The route is registered with the trailing slash.
        try await post("api/vm/mouse-jiggler/", body)
    }

    // The device's own screen

    public func setScreenSleep(seconds: Int) async throws {
        try await post("api/vm/oled", ["sleep": seconds])
    }

    // USB devices

    /// Turns the USB network adapter on or off. The USB gadget restarts, so
    /// the keyboard and mouse drop out for a moment.
    public func setUSBNetwork(_ on: Bool, current: Bool) async throws {
        guard on != current else { return }
        // The Pro only toggles; the classic NanoKVM takes `enable` on newer
        // firmware and toggles on older, which comes to the same here.
        var body: [String: Any] = ["device": "network"]
        if family == .nanoKVM { body["enable"] = on }
        try await post("api/vm/device/virtual", body, timeout: 60)
    }

    /// Classic NanoKVM: shares its data partition as a USB disk.
    public func setUSBDisk(_ on: Bool, current: Bool) async throws {
        guard family == .nanoKVM, on != current else { return }
        try await post("api/vm/device/virtual", ["device": "disk", "enable": on], timeout: 60)
    }

    /// NanoKVM Pro and Go: a USB microphone.
    public func setUSBMicrophone(_ on: Bool, current: Bool) async throws {
        guard family == .nanoKVMPro, on != current else { return }
        try await post("api/vm/device/virtual", ["device": "mic"], timeout: 60)
    }

    /// NanoKVM Pro and Go: which storage the remote machine sees as a USB disk.
    public func setProDisk(_ disk: NanoKVMProDisk, current: NanoKVMProDisk) async throws {
        guard family == .nanoKVMPro, disk != current else { return }
        // The Pro unplugs whatever is shown, then shows `type` unless it was
        // the one already shown, so naming the current disk turns it off.
        let type = disk == .off ? current.rawValue : disk.rawValue
        try await post("api/vm/device/virtual", ["device": "disk", "type": type], timeout: 120)
    }

    // Video capture

    public func setHDMICapture(_ on: Bool) async throws {
        if family == .nanoKVMPro {
            try await post("api/vm/hdmi/capture", ["enabled": on])
        } else {
            try await post(on ? "api/vm/hdmi/enable" : "api/vm/hdmi/disable")
        }
    }

    /// Classic NanoKVM: minutes without a viewer before capture pauses; 0 = never.
    public func setHDMIIdleTimeout(minutes: Int) async throws {
        let minutes = min(NanoKVMSettings.maxHDMIIdleTimeoutMinutes, max(0, minutes))
        try await post("api/vm/hdmi/timeout", ["minutes": minutes])
    }

    public func setHDMIPassthrough(_ on: Bool) async throws {
        try await post("api/vm/hdmi/passthrough", ["enabled": on])
    }

    /// NanoKVM Pro and Go: a built-in EDID's ID, or a custom EDID's file name.
    public func setEDID(_ edid: String) async throws {
        try await post("api/vm/edid", ["edid": edid], timeout: 30)
    }

    // System

    /// Classic NanoKVM: the swap file size in MB; 0 turns swap off.
    public func setSwap(megabytes: Int) async throws {
        try await post("api/vm/swap", ["size": megabytes], timeout: 120)
    }

    public func setTimeZone(_ identifier: String) async throws {
        try await post("api/vm/timezone", ["timezone": identifier])
    }

    public func setLowPower(_ on: Bool) async throws {
        try await post("api/vm/low-power", ["enable": on], timeout: 30)
    }

    /// Restarts the NanoKVM. Returns once it has taken the request; the
    /// connection drops soon after.
    public func reboot() async throws {
        do {
            try await post("api/vm/system/reboot", timeout: 15)
        } catch let error as URLError {
            // The classic NanoKVM can go down before it answers.
            if error.code != .timedOut && error.code != .networkConnectionLost { throw error }
        }
    }
}
