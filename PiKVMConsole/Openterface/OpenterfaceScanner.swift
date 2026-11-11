import AVFoundation
import Foundation
import IOKit
import PiKVMKit

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

    var displayName: String {
        videoChip.map { "Openterface (\($0))" } ?? "Openterface"
    }
}

/// Finds Openterface units by their USB vendor and product IDs.
enum OpenterfaceScanner {
    struct SerialPort {
        let path: String
        let location: UInt32?
        let chip: String
    }

    static func scan() -> [OpenterfaceUnit] {
        let videos = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices
            .filter { OpenterfaceHardware.isVideoCapture(uniqueID: $0.uniqueID, modelID: $0.modelID) }
        guard !videos.isEmpty else { return [] }
        let serials = serialPorts()
        let audios = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices

        return videos.map { video in
            let parsed = OpenterfaceHardware.parseCaptureUniqueID(video.uniqueID)
            let chipID = parsed?.id ?? OpenterfaceHardware.parseModelID(video.modelID)
            let location = parsed?.location

            var serial: SerialPort?
            if let location {
                serial = serials.first { $0.location.map { OpenterfaceHardware.shareHub($0, location) } ?? false }
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

            return OpenterfaceUnit(
                id: video.uniqueID,
                videoName: video.localizedName,
                videoChip: chipID.flatMap { OpenterfaceHardware.videoChips[$0] },
                location: location,
                serialPath: serial?.path,
                controlChip: serial?.chip,
                audioID: audio?.uniqueID,
                audioName: audio?.localizedName
            )
        }
    }

    /// The unit a saved device means: the one with its ID, or else the only
    /// one plugged in (it may have moved to another USB port).
    static func unit(for device: Device) -> OpenterfaceUnit? {
        let units = scan()
        if let id = device.localDeviceID, let match = units.first(where: { $0.id == id }) { return match }
        return units.count == 1 || device.localDeviceID == nil ? units.first : nil
    }

    /// Serial ports whose USB device is an Openterface controller.
    static func serialPorts() -> [SerialPort] {
        guard let matching = IOServiceMatching("IOSerialBSDClient") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [SerialPort] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            guard let vendor = number(service, "idVendor"), let product = number(service, "idProduct"),
                  let chip = OpenterfaceHardware.controlChips[.init(vendor: UInt16(truncatingIfNeeded: vendor),
                                                                    product: UInt16(truncatingIfNeeded: product))]
            else { continue }
            let location = number(service, "locationID").map { UInt32(truncatingIfNeeded: $0) }
            ports.append(SerialPort(path: path, location: location, chip: chip))
        }
        return ports.sorted { $0.path < $1.path }
    }

    /// A number property of the service or the nearest USB device above it.
    private static func number(_ service: io_object_t, _ key: String) -> Int? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
        return (value as? NSNumber)?.intValue
    }
}
