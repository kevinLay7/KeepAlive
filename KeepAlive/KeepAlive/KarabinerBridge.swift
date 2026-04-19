import Foundation
import Darwin
import ServiceManagement

// Client-side facade over the root helper daemon.
//
// The helper is a plain LaunchDaemon (see KeepAliveHelper/) that runs as root so
// it can reach Karabiner's root-only VHID socket at
//   /Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server/*.sock
// and post real HID pointing reports through the DriverKit dext. We bypass
// SMAppService entirely; install.sh drops the binary + plist in place and
// bootstraps the daemon manually (requires sudo once).
//
// IPC is a 1-byte AF_UNIX datagram to /var/run/keepalive.sock. Any byte = nudge.
// Non-blocking fire-and-forget; the helper logs failures to /var/log/keepalive-helper.log.
@MainActor
final class KarabinerBridge: ObservableObject {

    enum State: Equatable {
        case notRegistered            // helper socket not present
        case registering              // install script in flight
        case registrationFailed(String)
        case running                  // socket responds
        case unresponsive(String)
    }

    @Published private(set) var state: State = .notRegistered
    @Published private(set) var driverConnected = false
    @Published private(set) var pointingReady = false
    @Published private(set) var lastStatusError: String?

    nonisolated static let controlSocketPath = "/var/run/keepalive.sock"
    nonisolated static let daemonPlistPath = "/Library/LaunchDaemons/com.kevinlay.keepalive.helper.plist"
    nonisolated static let daemonLabel = "com.kevinlay.keepalive.helper"

    init() {
        refreshStateFromSMAppService()
    }

    // MARK: - Install / uninstall

    /// Kept named `register()` so MenuBarView doesn't need to change.
    /// Prompts for admin via osascript and runs install.sh, which compiles the
    /// helper with swiftc + drops it in /usr/local/libexec + boots the daemon.
    func register() {
        state = .registering
        guard let script = Self.installScriptPath() else {
            state = .registrationFailed("install.sh not found in app bundle or repo")
            return
        }
        Task.detached(priority: .userInitiated) { [script] in
            let (ok, output) = Self.runWithAdminPrompt(path: script)
            await MainActor.run {
                if ok {
                    self.refreshStateFromSMAppService()
                } else {
                    self.state = .registrationFailed(output)
                }
            }
        }
    }

    func unregister() {
        Task.detached(priority: .userInitiated) { [plist = Self.daemonPlistPath] in
            let cmd = "/bin/launchctl bootout system \(plist); /bin/rm -f /usr/local/libexec/keepalive-helper \(plist)"
            let (_, _) = Self.runWithAdminPrompt(inlineScript: cmd)
            await MainActor.run {
                self.state = .notRegistered
                self.driverConnected = false
                self.pointingReady = false
            }
        }
    }

    /// Check socket existence + poke daemon. Kept named for MenuBarView.
    func refreshStateFromSMAppService() {
        if access(Self.controlSocketPath, F_OK) != 0 {
            state = .notRegistered
            return
        }
        // Socket exists — assume running. We could probe `launchctl print system/<label>`
        // but that needs sudo; trust the socket for now.
        state = .running
        Task { await refreshStatus() }
    }

    // MARK: - Nudge / status

    /// Non-blocking fire-and-forget nudge. Returns false quickly if the helper
    /// is missing; caller (PowerManager) falls back to CGEvents.
    @discardableResult
    func nudge() async -> Bool {
        guard state == .running else { return false }
        // Run send off the main actor — sendto on a datagram socket is non-blocking
        // but opening the socket still briefly touches the filesystem.
        return await Task.detached(priority: .userInitiated) {
            Self.sendControlByte()
        }.value
    }

    /// Status probe. Currently just re-checks socket presence; driver_connected /
    /// pointing_ready aren't surfaced back through the 1-byte protocol. We could
    /// extend the helper to reply with a status byte — left as TODO since the
    /// presence of /var/run/keepalive.sock + a successful nudge (which no-ops
    /// safely if the driver isn't ready) is usually enough UI signal.
    func refreshStatus() async {
        if access(Self.controlSocketPath, F_OK) == 0 {
            driverConnected = true
            pointingReady = true
            lastStatusError = nil
        } else {
            driverConnected = false
            pointingReady = false
            lastStatusError = "socket \(Self.controlSocketPath) missing"
            state = .notRegistered
        }
    }

    // MARK: - Internals

    nonisolated private static func sendControlByte() -> Bool {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = controlSocketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, cstr, 103) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let byte: UInt8 = 0x4E // 'N'
        let rc = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                [byte].withUnsafeBufferPointer { buf in
                    sendto(fd, buf.baseAddress, 1, 0, sa, len)
                }
            }
        }
        return rc == 1
    }

    /// Returns the path to install.sh. Prefer the copy inside the running app bundle
    /// (Contents/Resources/install.sh), fall back to repo layout for dev builds.
    nonisolated private static func installScriptPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "install", ofType: "sh") {
            return bundled
        }
        let repoGuesses = [
            "../KeepAliveHelper/install.sh",
            "../../KeepAliveHelper/install.sh",
        ]
        let cwd = FileManager.default.currentDirectoryPath
        for rel in repoGuesses {
            let abs = (cwd as NSString).appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: abs) { return abs }
        }
        return nil
    }

    /// Invoke a script via osascript's "with administrator privileges" prompt,
    /// which surfaces macOS's system password dialog. Returns (success, stderr/stdout).
    nonisolated private static func runWithAdminPrompt(path: String? = nil, inlineScript: String? = nil) -> (Bool, String) {
        let escapedShell: String
        if let p = path {
            escapedShell = "/bin/bash " + quoted(p)
        } else if let s = inlineScript {
            escapedShell = s
        } else {
            return (false, "no script provided")
        }
        // osascript sends a single stdin; escape embedded quotes.
        let appleScript = "do shell script \"\(escapedShell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]

        let out = Pipe(); let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return (false, "osascript run failed: \(error)") }
        task.waitUntilExit()
        let combined = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                     + (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        return (task.terminationStatus == 0, combined)
    }

    nonisolated private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
