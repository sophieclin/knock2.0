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

    /// The sensor streams nothing until its AppleSPUHIDDriver services are told
    /// to report (their ReportInterval is 0 after boot). Setting these on the
    /// IOHIDDevice instead is silently ignored on Apple Silicon, so they go on
    /// the registry services. Previously knockd relied on some other process
    /// having woken the drivers, which stopped happening after a reboot.
    private func wakeSensorDrivers() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else {
            print("Warning: could not look up AppleSPUHIDDriver services; sensor may not report")
            return
        }
        defer { IOObjectRelease(iterator) }

        let properties: [(String, Int32)] = [
            ("SensorPropertyReportingState", 1),
            ("SensorPropertyPowerState", 1),
            ("ReportInterval", 1000), // microseconds; hardware clamps to its max rate
        ]
        while case let service = IOIteratorNext(iterator), service != 0 {
            for (key, value) in properties {
                let result = IORegistryEntrySetCFProperty(service, key as CFString, NSNumber(value: value))
                if result != KERN_SUCCESS {
                    print("Warning: setting \(key) on AppleSPUHIDDriver failed (0x\(String(UInt32(bitPattern: result), radix: 16)))")
                }
            }
            IOObjectRelease(service)
        }
    }

    public func start() throws {
        wakeSensorDrivers()
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
