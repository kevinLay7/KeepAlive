import Foundation

// Shared between the main KeepAlive app and the privileged helper (KeepAliveHelper).
// Both targets must include this file. In Xcode: File → Add Files…, then in the
// File Inspector check BOTH "KeepAlive" and "KeepAliveHelper" under Target Membership.

// Mach service name the helper's NSXPCListener advertises and the app's
// NSXPCConnection connects to. Must match:
//   - `MachServices` key in Contents/Library/LaunchDaemons/<plist>
//   - the Label of the LaunchDaemon plist (common convention)
//   - SMAppService lookup name
public let kKarabinerHelperMachServiceName = "com.kevinlay.keepalive.helper"

@objc(KarabinerHelperProtocol)
public protocol KarabinerHelperProtocol {
    /// Liveness check. Returns helper version string.
    func ping(reply: @escaping (String) -> Void)

    /// Current VHID driver state as observed by the helper.
    /// - driverConnected: true once the daemon reports driver_connected=1
    /// - pointingReady:   true once virtual_hid_pointing_ready=1 has arrived
    /// - lastError:       nil if healthy, else a short diagnostic string
    func status(reply: @escaping (Bool, Bool, String?) -> Void)

    /// Post a zero-net-drift mouse nudge (+1 dx, then -1 dx) through the VHID driver.
    /// Succeeds iff the helper has seen virtual_hid_pointing_ready=1.
    /// - success: true if both reports were sent to the daemon's socket
    /// - errorMessage: nil on success, else diagnostic
    func nudge(reply: @escaping (Bool, String?) -> Void)
}
