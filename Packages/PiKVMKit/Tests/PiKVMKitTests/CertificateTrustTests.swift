import XCTest
@testable import PiKVMKit

final class CertificateTrustTests: XCTestCase {
    func testCATrustedIsAlwaysAccepted() {
        XCTAssertEqual(CertificatePinningDelegate.decide(caTrusted: true, fingerprint: "new",
                                                         policy: TrustPolicy(pinnedSHA256: "old")), .accept)
        XCTAssertEqual(CertificatePinningDelegate.decide(caTrusted: true, fingerprint: "x",
                                                         policy: TrustPolicy(requireCertificateAuthority: true)), .accept)
    }

    func testRequiringCARefusesUntrusted() {
        XCTAssertEqual(CertificatePinningDelegate.decide(caTrusted: false, fingerprint: "x",
                                                         policy: TrustPolicy(requireCertificateAuthority: true)), .reject)
    }

    func testPinning() {
        let policy = TrustPolicy(pinnedSHA256: "ABC")
        XCTAssertEqual(CertificatePinningDelegate.decide(caTrusted: false, fingerprint: "abc", policy: policy), .accept)
        XCTAssertEqual(CertificatePinningDelegate.decide(caTrusted: false, fingerprint: "def", policy: policy), .reject)
        XCTAssertEqual(CertificatePinningDelegate.decide(caTrusted: false, fingerprint: "def", policy: TrustPolicy()), .accept)
    }

    func testDevicePolicy() {
        var device = Device(name: "Rack", endpoints: [Endpoint(label: "LAN", host: "pikvm.lan"),
                                                       Endpoint(label: "Tailscale", host: "pikvm.tail1234.ts.net")])
        device.pinnedCertificateSHA256 = "abc"
        XCTAssertEqual(TrustPolicy(device: device).pinnedSHA256, "abc")
        XCTAssertFalse(TrustPolicy(device: device).requireCertificateAuthority)
        XCTAssertEqual(TrustPolicy(device: device).hostnames, ["pikvm.lan", "pikvm.tail1234.ts.net"])

        device.certificateTrust = .certificateAuthority
        XCTAssertNil(TrustPolicy(device: device).pinnedSHA256)
        XCTAssertTrue(TrustPolicy(device: device).requireCertificateAuthority)
    }

    func testLearning() {
        var selfSigned = Device(name: "A")
        selfSigned.learnCertificate(sha256: "abc", trustedByCA: false)
        XCTAssertEqual(selfSigned.certificateTrust, .pinned)
        XCTAssertEqual(selfSigned.pinnedCertificateSHA256, "abc")

        // A device that was pinned before and now has a CA-issued certificate switches over.
        var renewed = Device(name: "B", pinnedCertificateSHA256: "old")
        renewed.learnCertificate(sha256: "new", trustedByCA: true)
        XCTAssertEqual(renewed.certificateTrust, .certificateAuthority)
        XCTAssertNil(renewed.pinnedCertificateSHA256)

        // A pinned device never re-pins on its own.
        var pinned = Device(name: "C", pinnedCertificateSHA256: "abc", certificateTrust: .pinned)
        pinned.learnCertificate(sha256: "other", trustedByCA: false)
        XCTAssertEqual(pinned.pinnedCertificateSHA256, "abc")
    }

    func testOldSavedDevicesStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Old","model":"v3","endpoints":[],"username":"admin","targets":[],"pinnedCertificateSHA256":"abc"}"#
        let device = try JSONDecoder().decode(Device.self, from: Data(json.utf8))
        XCTAssertNil(device.certificateTrust)
        XCTAssertEqual(device.pinnedCertificateSHA256, "abc")
    }
}
