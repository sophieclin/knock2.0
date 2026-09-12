import Foundation
#if canImport(Darwin)
import Darwin
#endif
import KnockCore

/// Connects to knockd's Unix domain socket and reconnects every 3 seconds
/// if knockd isn't running yet (or restarts). This is what lets KnockAgent
/// show a "knockd connected?" status regardless of start order between
/// the two processes.
final class SocketClient {
    private let path: String
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var reconnectTimer: DispatchSourceTimer?
    private let lineBuffer = LineBuffer()
    private let queue = DispatchQueue(label: "knockagent.socket")

    var onTapCount: ((Int) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        queue.async { [weak self] in
            self?.attemptConnect()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.fd < 0 else { return }
            self.attemptConnect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func attemptConnect() {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }

        var addr = SocketIPC.makeSockAddr(path: path)
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(socketFD, sockaddrPtr, addrSize)
            }
        }
        guard connectResult == 0 else {
            close(socketFD)
            return
        }

        fd = socketFD
        onConnectionChange?(true)

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        source.setCancelHandler { [weak self] in
            close(socketFD)
            self?.fd = -1
            self?.onConnectionChange?(false)
        }
        source.resume()
        readSource = source
    }

    private func handleReadable() {
        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            readSource?.cancel()
            return
        }
        let data = Data(buffer[0..<bytesRead])
        for line in lineBuffer.append(data) {
            if let count = Int(line) {
                onTapCount?(count)
            }
        }
    }

    func stop() {
        reconnectTimer?.cancel()
        readSource?.cancel()
    }
}
