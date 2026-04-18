import Foundation

// KeepAlive privileged helper (LaunchDaemon, runs as root).
// Exposes an XPC service that the main KeepAlive app calls into to post
// mouse-nudge reports through the Karabiner VirtualHIDDevice DriverKit driver.

let kHelperVersion = "1.0.0"

// MARK: - XPC service implementation

final class HelperService: NSObject, KarabinerHelperProtocol {
    let vhid: VHIDClient

    init(vhid: VHIDClient) { self.vhid = vhid }

    func ping(reply: @escaping (String) -> Void) {
        reply("KeepAliveHelper \(kHelperVersion)")
    }

    func status(reply: @escaping (Bool, Bool, String?) -> Void) {
        reply(vhid.driverConnected, vhid.pointingReady, vhid.lastError)
    }

    func nudge(reply: @escaping (Bool, String?) -> Void) {
        let (ok, err) = vhid.nudge()
        reply(ok, err)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: HelperService
    init(service: HelperService) { self.service = service }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only accept connections from the main app (Developer ID, team QKXV85S73A,
        // bundle id com.kevinlay.keepalive). This is belt-and-suspenders; the launchd
        // MachServices port is already restricted to the bundled app by SMAppService.
        let requirement = """
            anchor apple generic and certificate leaf[subject.OU] = "QKXV85S73A" \
            and identifier "com.kevinlay.keepalive"
            """
        if #available(macOS 13.0, *) {
            newConnection.setCodeSigningRequirement(requirement)
        }

        newConnection.exportedInterface = NSXPCInterface(with: KarabinerHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

// MARK: - Entry point

NSLog("KeepAliveHelper %@ starting (uid=%d)", kHelperVersion, getuid())

let vhid: VHIDClient
do {
    vhid = try VHIDClient()
} catch {
    NSLog("KeepAliveHelper: FATAL VHIDClient init failed: %@", error.localizedDescription)
    // Still start the XPC listener so the main app can surface a clear error
    // via status() instead of "helper crashed".
    //
    // Construct a dummy that reports the error.
    //
    // Simplest path: exit. launchd will restart us and the situation will resolve
    // if the daemon comes up later. But we should rate-limit to avoid tight loop.
    sleep(5)
    exit(1)
}

vhid.initializePointing()

let service = HelperService(vhid: vhid)
let delegate = ListenerDelegate(service: service)

// The Mach service name must match the MachServices key in the LaunchDaemon plist.
let listener = NSXPCListener(machServiceName: kKarabinerHelperMachServiceName)
listener.delegate = delegate
listener.resume()

NSLog("KeepAliveHelper: XPC listener up on %@", kKarabinerHelperMachServiceName)

// Keep the process alive. launchd KeepAlive=true handles restarts.
RunLoop.main.run()
