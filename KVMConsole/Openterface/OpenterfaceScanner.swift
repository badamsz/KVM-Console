import AVFoundation
import Foundation
import IOKit
import KVMKit

/// One Openterface plugged into this Mac: its capture device, plus the serial
/// port and audio input found on the same USB hub.
struct OpenterfaceUnit: Identifiable, Hashable {
    /// The capture device's `uniqueID`. Stable while the unit stays in the same USB port.
    let id: String
    /// What macOS calls the capture device.
    let videoName: String
    /// The HDMI capture chip, such as "MS2109".
    let videoChip: String?
    /// The USB location ID, when the capture device reports one.
    let location: UInt32?
    /// The keyboard and mouse controller's serial port, such as `/dev/cu.usbserial-1420`.
    let serialPath: String?
    /// "CH9329" or "CH32V208".
    let controlChip: String?
    /// The audio input's `uniqueID`, when one was found.
    let audioID: String?
    let audioName: String?
    /// The USB serial number of the capture chip or controller, if either has one.
    var serialNumber: String? = nil

    var displayName: String {
        let chips = [videoChip, controlChip].compactMap { $0 }
        return chips.isEmpty ? "Openterface" : "Openterface (\(chips.joined(separator: ", ")))"
    }

    /// Newer units (KVM-GO, recent Mini-KVMs) have a CH32V208 controller,
    /// which also switches the KVM-GO's microSD card.
    var hasSDCardSwitch: Bool { controlChip == "CH32V208" }
}

/// Finds Openterface units by their USB vendor and product IDs.
enum OpenterfaceScanner {
    struct SerialPort {
        let path: String
        let location: UInt32?
        let chip: String
        var serialNumber: String? = nil
    }

    /// A serial port of any kind, for the USB Devices window.
    struct AnySerialPort: Hashable {
        let path: String
        let vendor: Int?
        let product: Int?
        let location: UInt32?
        /// "CH9329" or "CH32V208" when it is an Openterface controller.
        let chip: String?
        var serialNumber: String? = nil
    }

    /// A camera or microphone as AVFoundation sees it, for the USB Devices window.
    struct CaptureDeviceInfo: Hashable {
        let name: String
        let uniqueID: String
        let modelID: String
        /// For cameras: whether it is an Openterface capture chip.
        let isOpenterface: Bool
    }

    /// Everything the scan looks at, for the USB Devices window.
    struct Report {
        var units: [OpenterfaceUnit] = []
        var cameras: [CaptureDeviceInfo] = []
        var serialPorts: [AnySerialPort] = []
        var audioInputs: [CaptureDeviceInfo] = []
        var cameraAccess: AVAuthorizationStatus = .notDetermined
        var microphoneAccess: AVAuthorizationStatus = .notDetermined
    }

    private static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static func report() -> Report {
        let cameras = videoDevices()
        let audios = audioDevices()
        return Report(
            units: scan(),
            cameras: cameras.map {
                CaptureDeviceInfo(name: $0.localizedName, uniqueID: $0.uniqueID, modelID: $0.modelID,
                                  isOpenterface: OpenterfaceHardware.isVideoCapture(uniqueID: $0.uniqueID, modelID: $0.modelID))
            },
            serialPorts: allSerialPorts(),
            audioInputs: audios.map {
                CaptureDeviceInfo(name: $0.localizedName, uniqueID: $0.uniqueID, modelID: $0.modelID, isOpenterface: false)
            },
            cameraAccess: AVCaptureDevice.authorizationStatus(for: .video),
            microphoneAccess: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    static func scan() -> [OpenterfaceUnit] {
        let videos = videoDevices()
            .filter { OpenterfaceHardware.isVideoCapture(uniqueID: $0.uniqueID, modelID: $0.modelID) }
        guard !videos.isEmpty else { return [] }
        let serials = serialPorts()
        let audios = audioDevices()

        return videos.map { video in
            let parsed = OpenterfaceHardware.parseCaptureUniqueID(video.uniqueID)
            let chipID = parsed?.id ?? OpenterfaceHardware.parseModelID(video.modelID)
            let location = parsed?.location

            var serial: SerialPort?
            if let location {
                serial = serials.first { $0.location.map { OpenterfaceHardware.shareHub($0, location) } ?? false }
                    // A KVM-GO's capture chip runs at USB 3 speed, so it sits on the
                    // SuperSpeed side of the port while the serial controller is on the USB 2 side.
                    ?? serials.first { $0.location.map { OpenterfaceHardware.sharePhysicalPort(video: location, serial: $0) } ?? false }
            }
            // One of each: they belong together even without matching locations.
            if serial == nil, videos.count == 1, serials.count == 1 { serial = serials[0] }

            var audio: AVCaptureDevice?
            if let location {
                let tag = OpenterfaceHardware.audioLocationTag(location)
                audio = audios.first { $0.uniqueID.lowercased().contains(tag) }
            }
            if audio == nil, videos.count == 1 {
                audio = audios.first { device in
                    OpenterfaceHardware.audioNames.contains(device.localizedName)
                        || device.localizedName.localizedCaseInsensitiveContains("openterface")
                }
            }

            let videoSerial = location.flatMap { usbSerialNumber(atLocation: $0) }
            return OpenterfaceUnit(
                id: video.uniqueID,
                videoName: video.localizedName,
                videoChip: chipID.flatMap { OpenterfaceHardware.videoChips[$0] },
                location: location,
                serialPath: serial?.path,
                controlChip: serial?.chip,
                audioID: audio?.uniqueID,
                audioName: audio?.localizedName,
                serialNumber: videoSerial ?? serial?.serialNumber
            )
        }
    }

    /// Serial ports whose USB device is an Openterface controller.
    static func serialPorts() -> [SerialPort] {
        allSerialPorts().compactMap { port in
            port.chip.map { SerialPort(path: port.path, location: port.location, chip: $0, serialNumber: port.serialNumber) }
        }
    }

    /// Every serial port, with the USB IDs of the device it belongs to.
    static func allSerialPorts() -> [AnySerialPort] {
        guard let matching = IOServiceMatching("IOSerialBSDClient") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [AnySerialPort] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            let vendor = number(service, "idVendor"), product = number(service, "idProduct")
            var chip: String?
            if let vendor, let product {
                chip = OpenterfaceHardware.controlChips[.init(vendor: UInt16(truncatingIfNeeded: vendor),
                                                              product: UInt16(truncatingIfNeeded: product))]
            }
            let location = number(service, "locationID").map { UInt32(truncatingIfNeeded: $0) }
            ports.append(AnySerialPort(path: path, vendor: vendor, product: product, location: location, chip: chip,
                                       serialNumber: string(service, Self.serialNumberKey)))
        }
        return ports.sorted { $0.path < $1.path }
    }

    private static let serialNumberKey = "USB Serial Number"

    /// The serial number of the USB device at a location ID, if it reports one.
    static func usbSerialNumber(atLocation location: UInt32) -> String? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let value = IORegistryEntryCreateCFProperty(service, "locationID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            guard let value, UInt32(truncatingIfNeeded: value.intValue) == location else { continue }
            let serial = IORegistryEntryCreateCFProperty(service, serialNumberKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            return clean(serial)
        }
        return nil
    }

    /// A string property of the service or the nearest USB device above it.
    private static func string(_ service: io_object_t, _ key: String) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        return clean(IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options) as? String)
    }

    /// Drops empty and placeholder serial numbers.
    private static func clean(_ serial: String?) -> String? {
        guard let s = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              s.contains(where: { $0 != "0" }) else { return nil }
        return s
    }

    /// A number property of the service or the nearest USB device above it.
    private static func number(_ service: io_object_t, _ key: String) -> Int? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
        return (value as? NSNumber)?.intValue
    }
}
