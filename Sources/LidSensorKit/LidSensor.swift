import Foundation
import IOKit
import IOKit.hid

/// The MacBook hinge sensor.
///
/// Recent MacBooks expose an Apple HID device on usage page `0x20` (sensors),
/// usage `0x8A` (orientation). Its feature reports carry the lid angle:
///
/// - Report 7: `[0x07, b0, b1, b2, b3]`, little-endian, hundredths of a degree.
/// - Report 1: `[0x01, lo, hi]`, whole degrees.
///
/// Not every model answers report 7, so report 1 is the fallback. Only a
/// device that macOS marks as built-in is used: some external displays carry
/// the same usage and always read zero. Reading needs no permission.
public final class LidSensor {

    public enum Precision: Sendable {
        case centidegrees
        case degrees

        var reportID: CFIndex { self == .centidegrees ? 7 : 1 }

        public var label: String {
            self == .centidegrees ? "report 7 (0.01°)" : "report 1 (1°)"
        }
    }

    public private(set) var precision: Precision?
    public var isAvailable: Bool { device != nil && precision != nil }

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 16)

    public init() {
        connect()
    }

    deinit {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// Degrees between the lid and the base, 0 when shut, or `nil` when the
    /// read failed.
    public func angle() -> Double? {
        guard let precision, let bytes = readReport(precision.reportID),
              bytes.first == UInt8(precision.reportID) else { return nil }

        let degrees: Double
        switch precision {
        case .centidegrees:
            guard bytes.count >= 5 else { return nil }
            let raw = bytes[1...4].enumerated().reduce(UInt32(0)) { sum, item in
                sum | UInt32(item.element) << (8 * UInt32(item.offset))
            }
            degrees = Double(raw) / 100
        case .degrees:
            guard bytes.count >= 3 else { return nil }
            degrees = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        }
        return (0...360).contains(degrees) ? degrees : nil
    }

    private func connect() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        self.manager = manager

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            let builtIn = IOHIDDeviceGetProperty(candidate, kIOHIDBuiltInKey as CFString) as? NSNumber
            guard builtIn?.boolValue == true else { continue }
            device = candidate
            for option in [Precision.centidegrees, .degrees] {
                precision = option
                if angle() != nil { return }
            }
        }
        device = nil
        precision = nil
    }

    private func readReport(_ id: CFIndex) -> [UInt8]? {
        guard let device else { return nil }
        var length = CFIndex(buffer.count)
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, id, base, &length)
        }
        guard status == kIOReturnSuccess, length > 0 else { return nil }
        return Array(buffer[0..<length])
    }
}
