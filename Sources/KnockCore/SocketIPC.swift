import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum SocketIPC {
    public static let socketPath = "/tmp/knockd.sock"

    public static func encode(tapCount: Int) -> Data {
        Data("\(tapCount)\n".utf8)
    }

    /// Builds a sockaddr_un for the given path, for use with bind()/connect().
    /// Shared by knockd's SocketServer and KnockAgent's SocketClient so the
    /// sun_path-filling boilerplate exists in exactly one place.
    public static func makeSockAddr(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { cstrPtr in
                path.withCString { pathPtr in
                    strncpy(cstrPtr, pathPtr, sunPathSize - 1)
                }
            }
        }
        return addr
    }
}

/// Buffers raw socket bytes and yields complete newline-terminated lines,
/// carrying partial lines over between calls to `append`.
public final class LineBuffer {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }
}
