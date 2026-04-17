import Foundation
import IOKit

// Prototype: register a virtual HID keyboard via the private IOHIDUserDevice API.
// Events posted through here reach the kernel as if from a real USB keyboard, which
// updates IOHIDSystem's HIDIdleTime without needing Accessibility permission and
// without going through the CGEvent tap pipeline that most EDR hooks watch.
//
// Not wired into PowerManager — instantiate manually to test. Symbols are resolved
// at runtime so a future macOS that removes them fails gracefully instead of crashing.

final class VirtualHIDDevice {

    // MARK: - Private IOKit symbol bindings

    private typealias IOHIDUserDeviceCreateFn = @convention(c) (
        CFAllocator?, CFDictionary
    ) -> Unmanaged<AnyObject>?

    private typealias IOHIDUserDeviceHandleReportFn = @convention(c) (
        AnyObject, UnsafePointer<UInt8>, CFIndex
    ) -> IOReturn

    private static let iokit: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    }()

    private static let createFn: IOHIDUserDeviceCreateFn? = {
        guard let h = iokit, let sym = dlsym(h, "IOHIDUserDeviceCreate") else { return nil }
        return unsafeBitCast(sym, to: IOHIDUserDeviceCreateFn.self)
    }()

    private static let handleReportFn: IOHIDUserDeviceHandleReportFn? = {
        guard let h = iokit, let sym = dlsym(h, "IOHIDUserDeviceHandleReport") else { return nil }
        return unsafeBitCast(sym, to: IOHIDUserDeviceHandleReportFn.self)
    }()

    static var isAvailable: Bool { createFn != nil && handleReportFn != nil }

    // MARK: - HID report descriptor (USB HID 1.11 boot keyboard)

    // 8-byte input report: [modifiers][reserved][key1..key6]
    private static let reportDescriptor: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x06,       // Usage (Keyboard)
        0xA1, 0x01,       // Collection (Application)
        0x05, 0x07,       //   Usage Page (Key Codes)
        0x19, 0xE0,       //   Usage Minimum (224)
        0x29, 0xE7,       //   Usage Maximum (231)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x08,       //   Report Count (8)   -- modifiers
        0x81, 0x02,       //   Input (Data, Var, Abs)
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x08,       //   Report Size (8)
        0x81, 0x01,       //   Input (Const)      -- reserved
        0x95, 0x06,       //   Report Count (6)
        0x75, 0x08,       //   Report Size (8)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x65,       //   Logical Maximum (101)
        0x05, 0x07,       //   Usage Page (Key Codes)
        0x19, 0x00,       //   Usage Minimum (0)
        0x29, 0x65,       //   Usage Maximum (101)
        0x81, 0x00,       //   Input (Data, Array) -- 6 keycodes
        0xC0              // End Collection
    ]

    // USB HID usage for F20 (0x6F). Earlier F-keys (F13-F15) are mapped by Apple
    // keyboards to brightness/Exposé and must be avoided.
    // Note: as of macOS 15, virtual *keyboard* devices require the entitlement
    // com.apple.developer.hid.virtual.device — IOHIDUserDeviceCreate returns nil
    // from a locally-signed build, so this path rarely runs. Kept for completeness.
    private static let usageF20: UInt8 = 0x6F

    // MARK: - Lifecycle

    private var device: AnyObject?

    init?() {
        guard VirtualHIDDevice.isAvailable else {
            NSLog("VirtualHIDDevice: IOHIDUserDevice symbols not found on this macOS")
            return nil
        }

        let descData = Data(VirtualHIDDevice.reportDescriptor) as CFData
        let props: [String: Any] = [
            "VendorID": 0xFEED,
            "ProductID": 0xA11E,
            "Product": "KeepAlive Virtual Keyboard",
            "Transport": "Virtual",
            "RequestTimeout": 5_000_000,
            "ReportDescriptor": descData
        ]

        guard let created = VirtualHIDDevice.createFn?(kCFAllocatorDefault, props as CFDictionary) else {
            NSLog("VirtualHIDDevice: IOHIDUserDeviceCreate returned null")
            return nil
        }
        self.device = created.takeRetainedValue()
    }

    // MARK: - Posting events

    /// Send a single F20 press + release. Kernel sees this as a real USB keyboard event.
    func tapF20() {
        guard let device, let handle = VirtualHIDDevice.handleReportFn else { return }

        let press: [UInt8] = [0, 0, VirtualHIDDevice.usageF20, 0, 0, 0, 0, 0]
        let release: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]

        press.withUnsafeBufferPointer { buf in
            _ = handle(device, buf.baseAddress!, CFIndex(buf.count))
        }
        // Small gap so the kernel sees distinct events
        usleep(10_000)
        release.withUnsafeBufferPointer { buf in
            _ = handle(device, buf.baseAddress!, CFIndex(buf.count))
        }
    }
}
