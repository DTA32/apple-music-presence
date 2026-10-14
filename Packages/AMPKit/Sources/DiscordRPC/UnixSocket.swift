import Darwin
import Foundation

/// A blocking Unix domain stream socket with a dedicated reader thread.
///
/// Discord's IPC is a plain Unix socket, so POSIX is the most direct route. Reads block on their
/// own thread (never on Swift's cooperative pool) and are delivered in order through an AsyncStream.
final class UnixSocket: @unchecked Sendable {
    enum Event: Sendable {
        case frame(IPCFrame)
        case closed(String?)
    }

    private let fd: Int32
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private init(fd: Int32) {
        self.fd = fd
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    static func connect(path: String) throws -> UnixSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .ECONNREFUSED)
        }

        let socket = UnixSocket(fd: fd)
        socket.startReading()
        return socket
    }

    func send(_ frame: IPCFrame) throws {
        let data = frame.encoded()
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    /// Unblocks the reader; the reader thread closes the descriptor when it exits.
    func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    private func startReading() {
        let thread = Thread { [fd, continuation] in
            var decoder = IPCFrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            var reason: String?
            readLoop: while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    reason = String(cString: strerror(errno))
                    break
                }
                do {
                    for frame in try decoder.append(Data(buffer[0..<count])) {
                        continuation.yield(.frame(frame))
                    }
                } catch {
                    reason = "Malformed frame from Discord: \(error)"
                    break readLoop
                }
            }
            Darwin.close(fd)
            continuation.yield(.closed(reason))
            continuation.finish()
        }
        thread.name = "DiscordIPC.reader"
        thread.start()
    }
}
