import XCTest
@testable import KnockCore

final class SocketIPCTests: XCTestCase {
    func testEncodeProducesDecimalPlusNewline() {
        let data = SocketIPC.encode(tapCount: 2)
        XCTAssertEqual(String(data: data, encoding: .utf8), "2\n")
    }

    func testLineBufferSplitsSingleChunk() {
        let buffer = LineBuffer()
        let lines = buffer.append(Data("1\n2\n".utf8))
        XCTAssertEqual(lines, ["1", "2"])
    }

    func testLineBufferHandlesSplitAcrossChunks() {
        let buffer = LineBuffer()
        let first = buffer.append(Data("1\n2".utf8))
        XCTAssertEqual(first, ["1"])
        let second = buffer.append(Data("\n3\n".utf8))
        XCTAssertEqual(second, ["2", "3"])
    }

    func testMakeSockAddrSetsFamilyAndPath() {
        var addr = SocketIPC.makeSockAddr(path: "/tmp/test.sock")
        XCTAssertEqual(addr.sun_family, sa_family_t(AF_UNIX))
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        let path = withUnsafePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { cstrPtr in
                String(cString: cstrPtr)
            }
        }
        XCTAssertEqual(path, "/tmp/test.sock")
    }
}
