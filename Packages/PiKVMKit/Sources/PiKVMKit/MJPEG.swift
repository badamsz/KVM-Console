import Foundation

/// Incremental parser for uStreamer's `multipart/x-mixed-replace` MJPEG
/// stream. Feed it bytes as they arrive; it returns each complete JPEG.
public struct MJPEGParser {
    private var buffer = Data()
    private var expectedLength: Int?
    /// Guards against unbounded growth on a malformed stream.
    private let maxBuffer = 32 * 1024 * 1024

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let jpegStart = Data([0xFF, 0xD8])
    private static let jpegEnd = Data([0xFF, 0xD9])

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let frame = nextFrame() { frames.append(frame) }
        if buffer.count > maxBuffer { buffer.removeAll(); expectedLength = nil }
        return frames
    }

    private mutating func nextFrame() -> Data? {
        if expectedLength == nil {
            guard let headerRange = buffer.range(of: Self.headerEnd) else { return nil }
            let headers = String(decoding: buffer[buffer.startIndex..<headerRange.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
            if let length = Self.contentLength(in: headers) {
                expectedLength = length
            } else if headers.lowercased().contains("image/jpeg") {
                expectedLength = -1 // no length given: scan for the JPEG end marker
            } else {
                return nextFrame() // preamble or unrelated part
            }
        }
        guard let length = expectedLength else { return nil }
        if length >= 0 {
            guard buffer.count >= length else { return nil }
            let frame = buffer.prefix(length)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + length)
            expectedLength = nil
            return length > 0 ? Data(frame) : nextFrame()
        }
        guard let start = buffer.range(of: Self.jpegStart),
              let end = buffer.range(of: Self.jpegEnd, in: start.upperBound..<buffer.endIndex) else { return nil }
        let frame = Data(buffer[start.lowerBound..<end.upperBound])
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        expectedLength = nil
        return frame
    }

    static func contentLength(in headers: String) -> Int? {
        for line in headers.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

/// Reads the MJPEG stream from `/streamer/stream` and delivers JPEG frames.
/// kvmd only runs the streamer while a session websocket opened with
/// `stream=1` exists, so keep `KVMDClient.consoleSocket()` open alongside.
public final class MJPEGStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (Data) -> Void
    public typealias EndHandler = @Sendable (Error?) -> Void

    private let request: URLRequest
    private let trust: CertificatePinningDelegate
    private let onFrame: FrameHandler
    private let onEnd: EndHandler
    private var parser = MJPEGParser()
    private var session: URLSession?
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    public init(client: KVMDClient, onFrame: @escaping FrameHandler, onEnd: @escaping EndHandler) throws {
        var req = try client.makeRequest("streamer/stream")
        req.timeoutInterval = 15
        self.request = req
        self.trust = CertificatePinningDelegate(pinnedSHA256: client.effectivePinnedSHA256)
        self.onFrame = onFrame
        self.onEnd = onEnd
    }

    public func start() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    public func stop() {
        session?.invalidateAndCancel()
        session = nil
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        trust.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            onEnd(http.statusCode == 401 || http.statusCode == 403 ? KVMDError.unauthorized : KVMDError.http(http.statusCode))
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for frame in parser.append(data) { onFrame(frame) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as? URLError, e.code == .cancelled { return }
        onEnd(error)
    }
}
