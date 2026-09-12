/// Parses raw IOKit HID input reports from the Apple Silicon internal
/// accelerometer (AppleSPUHIDDevice, vendor usage page 0xFF00, usage 3).
/// Reports are 22 bytes; X/Y/Z are little-endian Int32 at byte offsets
/// 6, 10, 14, in units of 1/65536 g. This layout comes from community
/// reverse-engineering (Apple does not document this device) — see the
/// design doc's Background section for sources.
public enum AccelReportParser {
    public static func parse(_ bytes: [UInt8]) -> (x: Double, y: Double, z: Double)? {
        guard bytes.count >= 18 else { return nil }

        func readInt32LE(at offset: Int) -> Int32 {
            let b0 = UInt32(bytes[offset])
            let b1 = UInt32(bytes[offset + 1]) << 8
            let b2 = UInt32(bytes[offset + 2]) << 16
            let b3 = UInt32(bytes[offset + 3]) << 24
            return Int32(bitPattern: b0 | b1 | b2 | b3)
        }

        let x = Double(readInt32LE(at: 6)) / 65536.0
        let y = Double(readInt32LE(at: 10)) / 65536.0
        let z = Double(readInt32LE(at: 14)) / 65536.0
        return (x, y, z)
    }
}
