import Foundation
import ServiceManagement

// Client-side facade over the privileged helper.
//
// Responsibilities:
//   - Manage SMAppService registration lifecycle for the LaunchDaemon.
//   - Hold an NSXPCConnection to the helper's Mach service.
//   - Expose simple async methods to the rest of the app: register(), nudge(), status().
//
// Thread-safety: all methods are MainActor so PowerManager (also MainActor) can
// call them without Task-hop gymnastics. XPC replies are dispatched onto MainActor.

@MainActor
final class KarabinerBridge: ObservableObject {

    enum State: Equatable {
        case notRegistered          // SMAppService says we haven't installed the daemon
        case registering            // register() in flight
        case requiresApproval       // user needs to allow in System Settings → Login Items
        case registrationFailed(String)
        case running                // daemon is listed as enabled AND helper responded to ping
        case unresponsive(String)   // daemon is enabled but XPC calls fail
    }

    @Published private(set) var state: State = .notRegistered
    @Published private(set) var driverConnected = false
    @Published private(set) var pointingReady = false
    @Published private(set) var lastStatusError: String?

    private let plistName = "com.kevinlay.keepalive.helper.plist"
    private var connection: NSXPCConnection?

    init() {
        refreshStateFromSMAppService()
    }

    // MARK: - Registration

    func register() {
        state = .registering
        let service = SMAppService.daemon(plistName: plistName)
        do {
            try service.register()
            // Give launchd a moment to spawn the helper before pinging.
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await pingAndUpdate()
            }
        } catch {
            state = .registrationFailed(error.localizedDescription)
            NSLog("KarabinerBridge: register() failed: %@", error.localizedDescription)
        }
    }

    func unregister() {
        let service = SMAppService.daemon(plistName: plistName)
        try? service.unregister()
        tearDownConnection()
        state = .notRegistered
    }

    /// Re-read SMAppService status. Call when the view appears.
    func refreshStateFromSMAppService() {
        let service = SMAppService.daemon(plistName: plistName)
        switch service.status {
        case .enabled:
            Task { await pingAndUpdate() }
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered, .notFound:
            state = .notRegistered
            tearDownConnection()
        @unknown default:
            state = .notRegistered
            tearDownConnection()
        }
    }

    // MARK: - XPC connection

    private func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: kKarabinerHelperMachServiceName,
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: KarabinerHelperProtocol.self)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.state = .unresponsive("XPC connection invalidated")
            }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.state = .unresponsive("XPC connection interrupted")
            }
        }
        c.resume()
        return c
    }

    private func tearDownConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func proxy() -> KarabinerHelperProtocol? {
        if connection == nil { connection = makeConnection() }
        let p = connection?.remoteObjectProxyWithErrorHandler { [weak self] err in
            Task { @MainActor in
                self?.state = .unresponsive(err.localizedDescription)
            }
        } as? KarabinerHelperProtocol
        return p
    }

    // MARK: - Calls

    private func pingAndUpdate() async {
        guard let p = proxy() else {
            state = .unresponsive("no proxy")
            return
        }
        let version: String? = await withCheckedContinuation { cont in
            p.ping { reply in cont.resume(returning: reply) }
        }
        if let v = version {
            NSLog("KarabinerBridge: helper ping → %@", v)
            state = .running
            await refreshStatus()
        } else {
            state = .unresponsive("no ping reply")
        }
    }

    func refreshStatus() async {
        guard let p = proxy() else { return }
        let (dc, pr, err): (Bool, Bool, String?) = await withCheckedContinuation { cont in
            p.status { dc, pr, err in cont.resume(returning: (dc, pr, err)) }
        }
        driverConnected = dc
        pointingReady = pr
        lastStatusError = err
    }

    /// Non-blocking nudge. Safe to call from PowerManager even if not registered —
    /// returns false quickly.
    @discardableResult
    func nudge() async -> Bool {
        guard state == .running, let p = proxy() else { return false }
        let result: (Bool, String?) = await withCheckedContinuation { cont in
            p.nudge { ok, err in cont.resume(returning: (ok, err)) }
        }
        if !result.0 {
            lastStatusError = result.1
            NSLog("KarabinerBridge: nudge failed: %@", result.1 ?? "unknown")
        }
        return result.0
    }
}
