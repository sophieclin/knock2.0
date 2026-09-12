import XCTest
@testable import KnockCore

final class AccelReportParserTests: XCTestCase {
    /// Builds a 22-byte report with the given raw int32 (already in 1/65536 g units)
    /// little-endian at offsets 6 (x), 10 (y), 14 (z).
    private func makeReport(xRaw: Int32, yRaw: Int32, zRaw: Int32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 22)
        func writeLE(_ value: Int32, at offset: Int) {
            let bits = UInt32(bitPattern: value)
            bytes[offset] = UInt8(bits & 0xFF)
            bytes[offset + 1] = UInt8((bits >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((bits >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((bits >> 24) & 0xFF)
        }
        writeLE(xRaw, at: 6)
        writeLE(yRaw, at: 10)
        writeLE(zRaw, at: 14)
        return bytes
    }

    func testParsesOneGOnZAxis() {
        let report = makeReport(xRaw: 0, yRaw: 0, zRaw: 65536) // 65536 / 65536 = 1.0g
        let result = AccelReportParser.parse(report)
        XCTAssertEqual(result?.x, 0.0)
        XCTAssertEqual(result?.y, 0.0)
        XCTAssertEqual(result?.z, 1.0)
    }

    func testParsesNegativeValues() {
        let report = makeReport(xRaw: -32768, yRaw: 0, zRaw: 0) // -0.5g
        let result = AccelReportParser.parse(report)
        XCTAssertEqual(result?.x, -0.5)
    }

    func testReturnsNilForTooShortReport() {
        let shortReport = [UInt8](repeating: 0, count: 10)
        XCTAssertNil(AccelReportParser.parse(shortReport))
    }
}
