import Foundation

// Image library management on Sipeed devices: sizes and free space, uploads
// from this Mac, and downloads the device makes from a URL.
//
// * Classic NanoKVM 2.5.3+ has a media API (`/api/storage/media*`) with
//   sizes, free space and streaming uploads into its data partition. Older
//   firmware only has the image list, mount and delete.
// * NanoKVM Pro and Go upload in 8 MiB chunks to `/api/storage/image/upload`.
// * Both download from a URL: `/api/download/image` (classic, cancellable)
//   and `/api/storage/download/image` (Pro).
// Images live in `/data` on both.

/// One image in a classic NanoKVM's media library (`/api/storage/media`).
public struct NanoKVMMediaItem: Decodable, Sendable, Hashable {
    /// "image" or "partition".
    public let type: String
    /// The path relative to `/data`.
    public let rel: String
    public let name: String?
    public let size: Int64?
    /// "iso9660", "udf", "exfat", ...
    public let fs: String?
    public let attached: Bool?

    /// The path the legacy image API uses for this image.
    public var path: String { rel.hasPrefix("/") ? rel : "/data/" + rel }
    public var isOptical: Bool { fs == "iso9660" || fs == "udf" }
}

/// What the device's image library holds.
public struct NanoKVMLibrary: Sendable, Hashable {
    /// Image paths, as the mount and delete calls take them.
    public var images: [String]
    /// Sizes by path, where the device reports them.
    public var sizes: [String: Int64] = [:]
    /// Paths of images that can be served as a CD-ROM, where known.
    public var optical: Set<String>?
    public var totalBytes: Int64?
    public var freeBytes: Int64?
    /// Whether this Mac can upload images to the device.
    public var canUpload: Bool
}

/// A download the device is making from a URL.
public struct NanoKVMDownloadStatus: Decodable, Sendable, Hashable {
    /// "idle", "in_progress", "success", "failed" or "checksum_failed".
    public let status: String
    /// The URL being downloaded.
    public let file: String?
    /// e.g. "42%", or empty while unknown.
    public let percentage: String?
    /// Classic NanoKVM only.
    public let loaded: Int64?
    public let total: Int64?

    public var inProgress: Bool { status == "in_progress" }

    /// 0...1, when known.
    public var fraction: Double? {
        if let loaded, let total, total > 0 { return Double(loaded) / Double(total) }
        let digits = (percentage ?? "").filter { $0.isNumber || $0 == "." }
        return Double(digits).map { min(1, max(0, $0 / 100)) }
    }
}

extension NanoKVMClient {
    /// Where uploaded and downloaded images go.
    public static let imageDirectory = "/data"

    /// Uploads are done in chunks of this size on NanoKVM Pro and Go, like
    /// the Pro's web page.
    static let uploadChunkSize = 8 * 1024 * 1024

    /// Whether a file name is one the device lists as an image.
    public static func isImageName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".iso") || lower.hasSuffix(".img")
    }

    // MARK: Library

    private struct MediaList: Decodable { let media: [NanoKVMMediaItem]? }
    private struct MediaFiles: Decodable { let free: Int64?; let total: Int64? }

    /// The image list, with sizes and free space where the firmware reports them.
    /// - Parameter includeFreeSpace: reading free space lists the data
    ///   partition, so background refreshes leave it out.
    public func library(includeFreeSpace: Bool = true) async throws -> NanoKVMLibrary {
        let files = try await images()
        guard family == .nanoKVM else {
            return NanoKVMLibrary(images: files, canUpload: true)
        }
        // Classic NanoKVM: the media API exists from 2.5.3 on.
        guard let list = try? await call(MediaList.self, "api/storage/media") else {
            return NanoKVMLibrary(images: files, canUpload: false)
        }
        let items = (list.media ?? []).filter { $0.type == "image" }
        var library = NanoKVMLibrary(images: files, canUpload: true)
        for item in items {
            if let size = item.size { library.sizes[item.path] = size }
        }
        if items.contains(where: { $0.fs != nil }) {
            library.optical = Set(items.filter(\.isOptical).map(\.path))
        }
        if includeFreeSpace, let space = try? await call(MediaFiles.self, "api/storage/media/files", query: ["type": "partition", "path": "/"]) {
            library.totalBytes = space.total
            library.freeBytes = space.free
        }
        return library
    }

    // MARK: Upload

    /// Uploads a local ISO or disk image to `/data` on the device.
    /// - Parameter progress: bytes sent and total bytes, called off the main thread.
    public func uploadImage(fileURL: URL, as name: String,
                            progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let size = Int64((try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Log in again first if the session has expired, rather than finding
        // out after sending a whole image.
        _ = try await info()
        switch family {
        case .nanoKVMPro: try await uploadInChunks(fileURL: fileURL, name: name, size: size, progress: progress)
        default: try await uploadStreaming(fileURL: fileURL, name: name, size: size, progress: progress)
        }
    }

    /// Classic NanoKVM: one multipart request into the data partition's root.
    private func uploadStreaming(fileURL: URL, name: String, size: Int64,
                                 progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        for attempt in 0..<2 {
            let boundary = "KVMConsole-\(UUID().uuidString)"
            let body = try MultipartFileStream(fileURL: fileURL, fileSize: size, fieldName: "file",
                                               fileName: name, boundary: boundary)
            var req = try makeRequest("api/storage/media/files/upload", method: "POST",
                                      query: ["type": "partition", "path": "/"])
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue(String(body.length), forHTTPHeaderField: "Content-Length")
            req.httpBodyStream = body.stream
            // Idle timeout: generous, the NanoKVM's SD card can stall while it flushes.
            req.timeoutInterval = 600
            let (data, response) = try await session.data(for: req, delegate: UploadProgressDelegate(progress))
            if (response as? HTTPURLResponse)?.statusCode == 401, attempt == 0 {
                try await login()
                continue
            }
            _ = try Self.decode(NanoKVMIgnored.self, data: data, response: response)
            return
        }
        throw KVMDError.unauthorized
    }

    /// NanoKVM Pro and Go: 8 MiB chunks, each its own multipart request.
    private func uploadInChunks(fileURL: URL, name: String, size: Int64,
                                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let chunkSize = Self.uploadChunkSize
        let totalChunks = max(1, Int((size + Int64(chunkSize) - 1) / Int64(chunkSize)))
        let fileID = UUID().uuidString
        var sent: Int64 = 0
        progress(0, size)
        for index in 0..<totalChunks {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            let boundary = "KVMConsole-\(UUID().uuidString)"
            let body = Self.multipartBody(boundary: boundary, fields: [
                ("chunkIndex", String(index)),
                ("chunkSize", String(chunkSize)),
                ("totalChunks", String(totalChunks)),
            ], fileField: "file", fileName: name, fileData: chunk)
            let base = sent
            let chunkProgress = UploadProgressDelegate { chunkSent, _ in progress(base + min(chunkSent, Int64(chunk.count)), size) }
            for attempt in 0..<2 {
                var req = try makeRequest("api/storage/image/upload", method: "POST", query: ["fid": fileID])
                req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 300
                let (data, response) = try await session.upload(for: req, from: body, delegate: chunkProgress)
                if (response as? HTTPURLResponse)?.statusCode == 401, attempt == 0 {
                    try await login()
                    continue
                }
                _ = try Self.decode(NanoKVMIgnored.self, data: data, response: response)
                break
            }
            sent += Int64(chunk.count)
            progress(sent, size)
        }
    }

    static func multipartBody(boundary: String, fields: [(String, String)],
                              fileField: String, fileName: String, fileData: Data) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(MultipartFileStream.fileHeader(boundary: boundary, fieldName: fileField, fileName: fileName))
        body.append(fileData)
        body.append(MultipartFileStream.footer(boundary: boundary))
        return body
    }

    // MARK: Download from a URL

    private var downloadPath: String { family == .nanoKVMPro ? "api/storage/download/image" : "api/download/image" }

    private struct Enabled: Decodable { let enabled: Bool? }

    /// Whether the device can download images right now (its image storage is writable).
    public func canDownloadImages() async -> Bool {
        (try? await call(Enabled.self, downloadPath + "/enabled"))?.enabled ?? false
    }

    /// Asks the device to download an image from `url` into `/data`. The
    /// download runs on the device; follow it with `downloadStatus()`.
    public func startDownload(url: URL) async throws {
        _ = try await call(NanoKVMIgnored.self, downloadPath, method: "POST",
                           body: ["file": url.absoluteString, "sha256sum": ""], timeout: 30)
    }

    public func downloadStatus() async throws -> NanoKVMDownloadStatus? {
        try await call(NanoKVMDownloadStatus.self, downloadPath + "/status")
    }

    /// Whether a running download can be stopped (classic NanoKVM only).
    public var canCancelDownload: Bool { family == .nanoKVM }

    public func cancelDownload() async throws {
        guard canCancelDownload else { return }
        _ = try await call(NanoKVMIgnored.self, downloadPath + "/cancel", method: "POST", body: [:])
    }
}

/// A multipart/form-data body with one file part, read from disk as it is
/// sent, so multi-gigabyte images aren't loaded into memory.
final class MultipartFileStream: @unchecked Sendable {
    let stream: InputStream
    let length: Int64
    private let output: OutputStream
    private let head: Data
    private let tail: Data
    private let fileURL: URL

    static func fileHeader(boundary: String, fieldName: String, fileName: String) -> Data {
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        return Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeName)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n").utf8)
    }

    static func footer(boundary: String) -> Data { Data("\r\n--\(boundary)--\r\n".utf8) }

    init(fileURL: URL, fileSize: Int64, fieldName: String, fileName: String, boundary: String) throws {
        self.fileURL = fileURL
        head = Self.fileHeader(boundary: boundary, fieldName: fieldName, fileName: fileName)
        tail = Self.footer(boundary: boundary)
        length = Int64(head.count) + fileSize + Int64(tail.count)
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 256 * 1024, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw KVMDError.api("Couldn't prepare the upload.") }
        stream = input
        self.output = output
        let writer = Thread { [self] in self.pump() }
        writer.name = "KVMConsole upload"
        writer.start()
    }

    /// Runs on its own thread: writes the head, the file and the tail. Stops
    /// when URLSession closes the read end (cancel or failure).
    private func pump() {
        output.open()
        defer { output.close() }
        guard write(head) else { return }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        while true {
            guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { break }
            guard write(data) else { return }
        }
        _ = write(tail)
    }

    private func write(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            switch output.streamStatus {
            case .error, .closed, .atEnd: return false
            default: break
            }
            if !output.hasSpaceAvailable {
                usleep(1000)
                continue
            }
            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base + offset, maxLength: data.count - offset)
            }
            if n < 0 { return false }
            if n == 0 { usleep(1000) }
            offset += n
        }
        return true
    }
}
