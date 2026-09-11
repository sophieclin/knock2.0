import Foundation
#if canImport(Darwin)
import Darwin
#endif
import KnockCore

/// A Unix domain socket server that accepts any number of clients and
/// broadcasts tap-count events to all of them. Uses raw BSD sockets
/// (rather than Network.framework) for a small, easily-verified
/// implementation with no dependency surprises.
public final class SocketServer {
    public enum SocketError: Error {
        case systemError(Int32)
    }

    private let path: String
    private var listenFD: Int32 = -1
    private var clientFDs: [Int32] = []
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "knockd.socket")

    public init(path: String) {
        self.path = path
    }

    public func start() throws {
        unlink(path) // remove a stale socket file from a previous run

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw SocketError.systemError(errno) }

        var addr = SocketIPC.makeSockAddr(path: path)
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenFD, sockaddrPtr, addrSize)
            }
        }
        guard bindResult == 0 else { throw SocketError.systemError(errno) }

        chmod(path, 0o666) // the unprivileged KnockAgent process must be able to connect

        guard listen(listenFD, 4) == 0 else { throw SocketError.systemError(errno) }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.resume()
        acceptSource = source
    }

    /// Runs on `queue` (via acceptSource's event handler) — do not wrap
    /// the body in `queue.sync`, that would deadlock.
    private func acceptClient() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        clientFDs.append(clientFD)
    }

    public func broadcast(tapCount: Int) {
        let data = SocketIPC.encode(tapCount: tapCount)
        queue.async {
            self.clientFDs = self.clientFDs.filter { fd in
                let bytesWritten = data.withUnsafeBytes { rawBuffer -> Int in
                    write(fd, rawBuffer.baseAddress, rawBuffer.count)
                }
                if bytesWritten < 0 {
                    close(fd)
                    return false
                }
                return true
            }
        }
    }

    public func stop() {
        acceptSource?.cancel()
        for fd in clientFDs { close(fd) }
        clientFDs.removeAll()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }
}
