import Foundation
import IOKit.hid
import KnockCore

public protocol AccelerometerReaderDelegate: AnyObject {
    func accelerometerReader(_ reader: AccelerometerReader, didReceive sample: AccelSample)
}

/// Opens the internal accelerometer via IOKit HID. This is an undocumented
/// device (see the design doc's Background section) — matching is on
/// vendor usage page 0xFF00, usage 3, which is where community
/// reverse-engineering found it under AppleSPUHIDDevice. Requires root.
public final class AccelerometerReader {
    public enum AccelerometerError: Error {
        case openFailed(IOReturn)
    }

    public weak var delegate: AccelerometerReaderDelegate?

    private var manager: IOHIDManager?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private let reportBufferSize = 64

    public init() {}

    public func start() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0xFF00,
            kIOHIDDeviceUsageKey as String: 3,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let matchingCallback: IOHIDDeviceCallback = { context, _, _, device in
            guard let context else { return }
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue()
            reader.attachReportCallback(device: device)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            matchingCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw AccelerometerError.openFailed(openResult)
        }
        self.manager = manager
    }

    private func attachReportCallback(device: IOHIDDevice) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        reportBuffer = buffer

        let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
            guard let context else { return }
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            guard let parsed = AccelReportParser.parse(bytes) else { return }
            let sample = AccelSample(
                timestamp: CFAbsoluteTimeGetCurrent(),
                x: parsed.x, y: parsed.y, z: parsed.z
            )
            reader.delegate?.accelerometerReader(reader, didReceive: sample)
        }

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            reportBufferSize,
            reportCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
