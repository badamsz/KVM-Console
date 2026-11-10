import XCTest
@testable import PiKVMKit

final class JanusTests: XCTestCase {
    private func parse(_ json: String) -> [JanusIncoming] {
        JanusIncoming.parse(Data(json.utf8))
    }

    func testSuccessCarriesId() {
        XCTAssertEqual(parse(#"{"janus":"success","transaction":"abc","data":{"id":6189354312345678}}"#),
                       [.success(transaction: "abc", id: 6189354312345678)])
    }

    func testFeaturesEvent() {
        let json = #"{"janus":"event","session_id":1,"sender":2,"plugindata":{"plugin":"janus.plugin.ustreamer","data":{"ustreamer":"event","result":{"status":"features","features":{"audio":true,"mic":false,"camera":{"enabled":false},"ice":{"url":"stun:stun.example.net:3478"}}}}}}"#
        XCTAssertEqual(parse(json), [.features(JanusFeatures(audio: true, iceURL: "stun:stun.example.net:3478"))])
    }

    func testFeaturesWithoutIce() {
        let json = #"{"janus":"event","plugindata":{"data":{"result":{"status":"features","features":{"audio":false,"ice":{"url":""}}}}}}"#
        XCTAssertEqual(parse(json), [.features(JanusFeatures(audio: false, iceURL: nil))])
    }

    func testOfferArrivesWithStatus() {
        let json = #"{"janus":"event","plugindata":{"data":{"result":{"status":"starting"}}},"jsep":{"type":"offer","sdp":"v=0\r\n"}}"#
        XCTAssertEqual(parse(json), [.status("starting"), .offer(sdp: "v=0\r\n")])
    }

    func testPluginErrorAndHangup() {
        XCTAssertEqual(parse(#"{"janus":"event","plugindata":{"data":{"error_code":503,"error":"No video stream"}}}"#),
                       [.pluginError("No video stream")])
        XCTAssertEqual(parse(#"{"janus":"hangup","reason":"ICE failed"}"#), [.hangup(reason: "ICE failed")])
        XCTAssertEqual(parse(#"{"janus":"error","transaction":"t","error":{"code":458,"reason":"No such session"}}"#),
                       [.error(transaction: "t", reason: "No such session")])
        XCTAssertEqual(parse("not json"), [])
    }

    func testOutgoingMessages() throws {
        let watch = JanusMessage.watch(audio: true, session: 11, handle: 22, transaction: "t1")
        XCTAssertEqual(watch["janus"] as? String, "message")
        XCTAssertEqual(watch["session_id"] as? Int64, 11)
        XCTAssertEqual(watch["handle_id"] as? Int64, 22)
        let body = try XCTUnwrap(watch["body"] as? [String: Any])
        XCTAssertEqual(body["request"] as? String, "watch")
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        XCTAssertEqual(params["audio"] as? Bool, true)
        XCTAssertEqual(params["mic"] as? Bool, false)

        let start = JanusMessage.start(answerSDP: "sdp", session: 1, handle: 2, transaction: "t2")
        let jsep = try XCTUnwrap(start["jsep"] as? [String: String])
        XCTAssertEqual(jsep, ["type": "answer", "sdp": "sdp"])

        let done = JanusMessage.trickleCompleted(session: 1, handle: 2, transaction: "t3")
        XCTAssertEqual((done["candidate"] as? [String: Bool])?["completed"], true)

        // Every message must be valid JSON.
        for message in [watch, start, done, JanusMessage.attach(session: 1, transaction: "t"),
                        JanusMessage.trickle(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0, session: 1, handle: 2, transaction: "t")] {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(message))
        }
    }
}
