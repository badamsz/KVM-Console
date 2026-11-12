import Foundation

// Presents NanoKVM state in the shapes the app already shows for kvmd, so the
// power and virtual media screens work for both kinds of device.

extension ATXState {
    public init(enabled: Bool, busy: Bool, power: Bool, hdd: Bool) {
        self.enabled = enabled
        self.busy = busy
        self.leds = LEDs(power: power, hdd: hdd)
    }

    /// ATX state from a NanoKVM's LEDs.
    public init(nanoKVM leds: NanoKVMLEDs, busy: Bool = false) {
        self.init(enabled: true, busy: busy, power: leds.pwr, hdd: leds.hdd)
    }
}

extension MSDState {
    /// Virtual media state from a NanoKVM's image library and mounted image.
    /// Image names are the device's paths (e.g. `/data/ubuntu.iso`).
    public init(nanoKVMImages files: [String], mounted: NanoKVMMountedImage?, cdrom: Bool) {
        self.init(nanoKVM: NanoKVMLibrary(images: files, canUpload: false), mounted: mounted, cdrom: cdrom)
    }

    public init(nanoKVM library: NanoKVMLibrary, mounted: NanoKVMMountedImage?, cdrom: Bool) {
        enabled = true
        online = true
        busy = false
        images = library.images
            .map { path in
                MSDImage(name: path, size: library.sizes[path] ?? 0, complete: true,
                         removable: true, cdromable: library.optical?.contains(path) ?? true)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        totalBytes = library.totalBytes
        freeBytes = library.freeBytes
        uploading = nil
        if let mounted, !mounted.file.isEmpty {
            let image = images.first { $0.name == mounted.file } ?? MSDImage(name: mounted.file, size: 0)
            drive = Drive(image: image, connected: true, cdrom: mounted.cdrom ?? cdrom,
                          writable: mounted.readOnly.map { !$0 } ?? false)
        } else {
            drive = Drive(image: nil, connected: false, cdrom: false, writable: false)
        }
    }
}

extension ATXPowerAction {
    /// What a NanoKVM does for this action, given the power LED: NanoKVM only
    /// presses buttons, so "on" and "off" press power only when needed.
    public enum NanoKVMPress: Equatable, Sendable {
        case none
        case power(milliseconds: Int)
        case reset
    }

    public func nanoKVMPress(powerIsOn: Bool?) -> NanoKVMPress {
        switch self {
        case .on: return powerIsOn == true ? .none : .power(milliseconds: NanoKVMClient.shortPressMilliseconds)
        case .off: return powerIsOn == false ? .none : .power(milliseconds: NanoKVMClient.shortPressMilliseconds)
        case .offHard: return .power(milliseconds: NanoKVMClient.longPressMilliseconds)
        case .resetHard: return .reset
        }
    }
}

extension ATXButton {
    public var nanoKVMPress: ATXPowerAction.NanoKVMPress {
        switch self {
        case .power: return .power(milliseconds: NanoKVMClient.shortPressMilliseconds)
        case .powerLong: return .power(milliseconds: NanoKVMClient.longPressMilliseconds)
        case .reset: return .reset
        }
    }
}
