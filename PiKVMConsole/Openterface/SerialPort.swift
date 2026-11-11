import Darwin
import Foundation

/// A raw 8N1 serial port. Reads arrive on a background queue through
/// `onData`; writes are queued in order on the same queue.
final class SerialPort: @unchecked Sendable {
    enum SerialError: LocalizedError {
        case open(path: String, code: Int32)
        case configure(code: Int32)

        var errorDescription: String? {
            switch self {
            case .open(let path, let code):
                if code == EBUSY { return "\(path) is in use by another app. Quit the Openterface app and try again." }
                if code == EPERM || code == EACCES { return "This Mac didn't allow opening \(path)." }
                return "Couldn't open \(path): \(String(cString: strerror(code)))."
            case .configure(let code):
                return "Couldn't set up the serial port: \(String(cString: strerror(code)))."
            }
        }
    }

    let path: String
    /// Called on the port's queue with each chunk read.
    var onData: (@Sendable (Data) -> Void)?
    /// Called once on the port's queue when the port stops working (for
    /// example when the device is unplugged). Not called after `close()`.
    var onFailure: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "PiKVMConsole.SerialPort", qos: .userInteractive)
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let lock = NSLock()
    private var queuedBytes = 0
    private var closed = false

    init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    func open(baudRate: Int) throws {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.open(path: path, code: errno) }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SerialError.configure(code: code)
        }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        options.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CCTS_OFLOW | CRTS_IFLOW)
        cfsetspeed(&options, speed_t(baudRate))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SerialError.configure(code: code)
        }
        tcflush(fd, TCIOFLUSH)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(fd) }
        source.setCancelHandler { Darwin.close(fd) }

        lock.lock()
        self.fd = fd
        closed = false
        readSource = source
        lock.unlock()
        source.resume()
    }

    func close() {
        lock.lock()
        let source = readSource
        readSource = nil
        closed = true
        fd = -1
        lock.unlock()
        source?.cancel()
    }

    /// Queues bytes to send. A `droppable` write (a mouse move) is skipped
    /// while earlier writes are still waiting, so a slow port doesn't lag
    /// further and further behind the pointer.
    func write(_ data: Data, droppable: Bool = false) {
        lock.lock()
        if closed || fd < 0 || (droppable && queuedBytes > 2 * data.count) {
            lock.unlock()
            return
        }
        queuedBytes += data.count
        let fd = self.fd
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.queuedBytes -= data.count
                self.lock.unlock()
            }
            var offset = 0
            var stalls = 0
            while offset < data.count {
                if self.isClosed { return }
                let n = data.withUnsafeBytes { buffer in
                    Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                }
                if n > 0 {
                    offset += n
                    stalls = 0
                } else if n < 0, errno == EAGAIN || errno == EINTR, stalls < 200 {
                    stalls += 1
                    usleep(1000)
                } else {
                    self.fail("The serial port stopped responding.")
                    return
                }
            }
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func readAvailable(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n > 0 {
            onData?(Data(buffer[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            fail("The Openterface was unplugged.")
        }
    }

    private func fail(_ message: String) {
        guard !isClosed else { return }
        close()
        onFailure?(message)
    }
}
