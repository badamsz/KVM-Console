import XCTest
@testable import KVMKit

final class DiscoveryTests: XCTestCase {
    // MARK: Subnets

    func testIPv4Parsing() {
        XCTAssertEqual(IPv4(string: "192.168.1.20")?.description, "192.168.1.20")
        XCTAssertNil(IPv4(string: "192.168.1"))
        XCTAssertNil(IPv4(string: "192.168.1.256"))
        XCTAssertNil(IPv4(string: "pikvm.local"))
        XCTAssertTrue(IPv4(string: "100.101.102.103")!.isCGNAT)
        XCTAssertFalse(IPv4(string: "100.63.0.1")!.isCGNAT)
        XCTAssertTrue(IPv4(string: "169.254.3.4")!.isLinkLocal)
    }

    func testSubnetScanAddresses() {
        let subnet = IPv4Subnet(interface: "en0", address: IPv4(string: "192.168.1.23")!, prefixLength: 24)
        let hosts = subnet.scanAddresses()
        XCTAssertEqual(hosts.count, 253) // .1–.254 minus this Mac
        XCTAssertEqual(hosts.first?.description, "192.168.1.1")
        XCTAssertEqual(hosts.last?.description, "192.168.1.254")
        XCTAssertFalse(hosts.contains(IPv4(string: "192.168.1.23")!))
        XCTAssertEqual(subnet.scannedRange, "192.168.1.0/24")
    }

    func testWideSubnetIsNarrowedToSlash24() {
        let subnet = IPv4Subnet(interface: "en0", address: IPv4(string: "10.20.30.40")!, prefixLength: 16)
        XCTAssertEqual(subnet.scannedRange, "10.20.30.0/24")
        XCTAssertEqual(subnet.scanAddresses().count, 253)
        XCTAssertEqual(IPv4Subnet.prefixLength(ofMask: 0xFFFF_FF00), 24)
    }

    func testTunnelAndSelfAssignedSubnetsAreSkipped() {
        XCTAssertFalse(IPv4Subnet(interface: "utun4", address: IPv4(string: "100.64.1.2")!, prefixLength: 24).isScannable)
        XCTAssertFalse(IPv4Subnet(interface: "en0", address: IPv4(string: "169.254.9.9")!, prefixLength: 16).isScannable)
        XCTAssertTrue(IPv4Subnet(interface: "en0", address: IPv4(string: "192.168.0.5")!, prefixLength: 24).isScannable)
    }

    // MARK: Fingerprints

    func testKVMDAuthCheckIsPiKVM() {
        let body = Data("""
        {"ok": false, "result": {"error": "UnauthorizedError", "error_msg": "Unauthorized"}}
        """.utf8)
        XCTAssertEqual(Fingerprint.classify(status: 401, body: body, overTLS: true), .pikvm(model: nil))
    }

    func testPiKVMLoginPageIsPiKVM() {
        let body = Data("<html><head><title>PiKVM Login</title></head></html>".utf8)
        XCTAssertEqual(Fingerprint.classify(status: 200, body: body, overTLS: true), .pikvm(model: nil))
    }

    func testNanoKVMUnauthorizedString() {
        let body = Data("\"unauthorized\"".utf8)
        XCTAssertEqual(Fingerprint.classify(status: 401, body: body, overTLS: false), .nanoKVM(pro: false))
        XCTAssertEqual(Fingerprint.classify(status: 401, body: body, overTLS: true), .nanoKVM(pro: true))
    }

    func testNanoKVMIndexTitle() {
        let body = Data("<!doctype html><html><head>\n<TITLE> NanoKVM </TITLE>".utf8)
        XCTAssertEqual(Fingerprint.classify(status: 200, body: body, overTLS: false), .nanoKVM(pro: false))
    }

    func testOtherServersAreIgnored() {
        XCTAssertNil(Fingerprint.classify(status: 200, body: Data("<title>Router</title>".utf8), overTLS: false))
        XCTAssertNil(Fingerprint.classify(status: 401, body: Data("{\"error\":\"no\"}".utf8), overTLS: true))
        XCTAssertNil(Fingerprint.classify(status: 404, body: Data(), overTLS: true))
    }

    func testProbeURLs() {
        XCTAssertEqual(FingerprintProber.baseString(scheme: "https", host: "10.0.0.5", port: 443), "https://10.0.0.5")
        XCTAssertEqual(FingerprintProber.baseString(scheme: "http", host: "10.0.0.5", port: 8080), "http://10.0.0.5:8080")
        XCTAssertEqual(FingerprintProber.endpointHost(fromBase: "https://10.0.0.5"), "10.0.0.5")
        XCTAssertEqual(FingerprintProber.endpointHost(fromBase: "https://10.0.0.5:8443"), "10.0.0.5:8443")
        XCTAssertEqual(FingerprintProber.endpointHost(fromBase: "http://10.0.0.6"), "http://10.0.0.6")
        XCTAssertEqual(FingerprintProber.attempts(for: [80, 443, 8443]).map { "\($0.0):\($0.1)" },
                       ["https:443", "http:80", "https:8443", "http:8443"])
    }

    func testDeviceModelFromTXT() {
        XCTAssertEqual(BonjourBrowser.pikvmModel(fromTXT: ["model": "v4plus"]), .v4Plus)
        XCTAssertEqual(BonjourBrowser.pikvmModel(fromTXT: ["model": "v4mini"]), .v4Mini)
        XCTAssertEqual(BonjourBrowser.pikvmModel(fromTXT: ["model": "v3"]), .v3)
        XCTAssertEqual(BonjourBrowser.pikvmModel(fromTXT: ["platform": "v4plus-hdmi-rpi4"]), .v4Plus)
        XCTAssertEqual(BonjourBrowser.pikvmModel(fromTXT: ["model": "v2"]), .other)
        XCTAssertNil(BonjourBrowser.pikvmModel(fromTXT: [:]))
    }

    func testPiKVMServiceBecomesDevice() {
        let service = BonjourService(name: "pikvm-0000000012345678.local", type: "_pikvm._tcp",
                                     host: "192.168.1.40", port: 443,
                                     txt: ["model": "v4plus", "platform": "v4plus-hdmi-rpi4", "serial": "12345678"])
        let found = Discovery.device(fromPiKVMService: service)
        XCTAssertEqual(found.kind, .pikvm(model: .v4Plus))
        XCTAssertEqual(found.lanHost, "192.168.1.40")
        XCTAssertEqual(found.details["serial"], "12345678")
        let device = found.makeDevice()
        XCTAssertEqual(device.name, "pikvm-0000000012345678")
        XCTAssertEqual(device.model, .v4Plus)
        XCTAssertEqual(device.endpoints.map(\.host), ["192.168.1.40"])
    }

    // MARK: Merging

    func testBonjourAndScanOfSameHostMerge() {
        var results = DiscoveryResults()
        results.add(DiscoveredDevice(id: "lan:192.168.1.40", kind: .pikvm(model: nil), name: "192.168.1.40",
                                     lanHost: "192.168.1.40", sources: [.subnetScan]))
        results.add(DiscoveredDevice(id: "lan:192.168.1.40", kind: .pikvm(model: .v3), name: "pikvm-01.local",
                                     lanHost: "192.168.1.40", sources: [.bonjour]))
        XCTAssertEqual(results.devices.count, 1)
        XCTAssertEqual(results.devices[0].kind, .pikvm(model: .v3))
        XCTAssertEqual(results.devices[0].name, "pikvm-01.local")
        XCTAssertEqual(results.devices[0].sources, [.subnetScan, .bonjour])
    }

    func testTailscalePeerMergesWithUniquelyNamedLANDevice() {
        var results = DiscoveryResults()
        results.add(DiscoveredDevice(id: "lan:192.168.1.40", kind: .pikvm(model: nil), name: "rack-kvm.local",
                                     lanHost: "192.168.1.40", sources: [.subnetScan]))
        results.add(DiscoveredDevice(id: "ts:n1", kind: .pikvm(model: nil), name: "rack-kvm",
                                     tailscaleHost: "rack-kvm.tail1234.ts.net", sources: [.tailscale]))
        XCTAssertEqual(results.devices.count, 1)
        let device = results.devices[0].makeDevice()
        XCTAssertEqual(device.endpoints.map(\.label), ["LAN", "Tailscale"])
        XCTAssertEqual(device.endpoints.map(\.host), ["192.168.1.40", "rack-kvm.tail1234.ts.net"])
    }

    func testDuplicateDefaultNamesStaySeparate() {
        var results = DiscoveryResults()
        results.add(DiscoveredDevice(id: "lan:192.168.1.40", kind: .pikvm(model: nil), name: "pikvm.local",
                                     lanHost: "192.168.1.40", sources: [.subnetScan]))
        results.add(DiscoveredDevice(id: "lan:192.168.1.41", kind: .pikvm(model: nil), name: "pikvm.local",
                                     lanHost: "192.168.1.41", sources: [.subnetScan]))
        results.add(DiscoveredDevice(id: "ts:n1", kind: .pikvm(model: nil), name: "pikvm",
                                     tailscaleHost: "pikvm.tail1234.ts.net", sources: [.tailscale]))
        XCTAssertEqual(results.devices.count, 3)
    }

    func testPiKVMsSortBeforeNanoKVMs() {
        var results = DiscoveryResults()
        results.add(DiscoveredDevice(id: "a", kind: .nanoKVM(pro: false), name: "a-nano", lanHost: "http://10.0.0.2", sources: [.subnetScan]))
        results.add(DiscoveredDevice(id: "b", kind: .pikvm(model: nil), name: "z-pikvm", lanHost: "10.0.0.3", sources: [.subnetScan]))
        XCTAssertEqual(results.devices.map(\.id), ["b", "a"])
    }

    func testAlreadyAddedMatchesAnyEndpoint() {
        let existing = [Device(name: "Desk", endpoints: [Endpoint(label: "LAN", host: "192.168.1.40"),
                                                          Endpoint(label: "Tailscale", host: "desk.tail1234.ts.net")])]
        let byLAN = DiscoveredDevice(id: "x", kind: .pikvm(model: nil), name: "x", lanHost: "192.168.1.40", sources: [.subnetScan])
        let byTS = DiscoveredDevice(id: "y", kind: .pikvm(model: nil), name: "y", tailscaleHost: "DESK.tail1234.ts.net.", sources: [.tailscale])
        let other = DiscoveredDevice(id: "z", kind: .pikvm(model: nil), name: "z", lanHost: "https://192.168.1.41", sources: [.subnetScan])
        XCTAssertTrue(DiscoveryResults.isAlreadyAdded(byLAN, in: existing))
        XCTAssertTrue(DiscoveryResults.isAlreadyAdded(byTS, in: existing))
        XCTAssertFalse(DiscoveryResults.isAlreadyAdded(other, in: existing))
    }

    func testNanoKVMPrefill() {
        let found = DiscoveredDevice(id: "lan:10.0.0.9", kind: .nanoKVM(pro: false), name: "kvm-a1b2.local",
                                     lanHost: "http://10.0.0.9", sources: [.bonjour])
        let device = found.makeDevice()
        XCTAssertEqual(device.name, "kvm-a1b2")
        XCTAssertEqual(device.username, "admin")
        // Stored bare; the NanoKVM client falls back from HTTPS to HTTP itself.
        XCTAssertEqual(device.endpoints.first?.host, "10.0.0.9")
        XCTAssertEqual(device.model, .nanoKVM)
        XCTAssertEqual(DiscoveredKind.nanoKVM(pro: true).suggestedModel, .nanoKVMPro)
    }

    // MARK: Tailscale

    func testTailscaleDevicesDecode() throws {
        let json = Data("""
        {"devices": [
          {"addresses": ["100.101.1.2", "fd7a:115c:a1e0::1"], "name": "rack-kvm.tail1234.ts.net",
           "hostname": "rack-kvm", "os": "linux", "nodeId": "n1", "connectedToControl": true},
          {"addresses": ["100.101.1.3"], "name": "phone.tail1234.ts.net", "hostname": "phone",
           "os": "iOS", "nodeId": "n2", "connectedToControl": true},
          {"addresses": ["100.101.1.4"], "name": "", "hostname": "old", "os": "linux", "id": "4"}
        ]}
        """.utf8)
        let peers = try TailscaleClient.decodePeers(json)
        XCTAssertEqual(peers.count, 3)
        XCTAssertEqual(peers[0].preferredHost, "rack-kvm.tail1234.ts.net")
        XCTAssertEqual(peers[0].ipv4, "100.101.1.2")
        XCTAssertTrue(peers[0].mightBeKVM)
        XCTAssertFalse(peers[1].mightBeKVM)
        XCTAssertEqual(peers[2].preferredHost, "100.101.1.4")
        XCTAssertEqual(peers[2].id, "4")
    }
}
