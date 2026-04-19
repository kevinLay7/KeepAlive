import Foundation
import Darwin

// Root-only LaunchDaemon. Two jobs:
//   1. Talk to Karabiner-DriverKit-VirtualHIDDevice daemon (root-only socket) to post
//      real HID pointing reports into the kernel's HID stack.
//   2. Listen on /var/run/keepalive.sock for a 1-byte "nudge" from the user-space
//      KeepAlive.app. Any byte triggers a jiggle (+1 / -1 pixel pointer delta).

// MARK: - Karabiner VHID client

// Wire protocol v5 (Karabiner-DriverKit-VirtualHIDDevice v6.8.0):
//   request  = [0x63 'c'][0x70 'p'][uint16 LE protocol=5][uint8 request_ordinal][payload]
//   response = [uint8 response_ordinal][uint8 bool]
enum VHIDRequest: UInt8 {
    case virtualHidPointingInitialize = 4
    case postPointingInputReport = 12
}

enum VHIDResponse: UInt8 {
    case virtualHidPointingReady = 5
}

// pointing_input, __attribute__((packed)), sizeof == 8:
//   uint32 buttons; uint8 x; uint8 y; uint8 vertical_wheel; uint8 horizontal_wheel;
// x/y/wheels are int8 deltas despite uint8_t field type.
struct PointingInput {
    var buttons: UInt32 = 0
    var x: UInt8 = 0
    var y: UInt8 = 0
    var vWheel: UInt8 = 0
    var hWheel: UInt8 = 0
}

final class VHIDClient {
    private static let rootOnly = "/Library/Application Support/org.pqrs/tmp/rootonly"
    private static let serverDir = "\(rootOnly)/vhidd_server"
    private static let clientDir = "\(rootOnly)/vhidd_client"

    private var fd: Int32 = -1
    private var clientPath: String = ""
    private var pointingReady = false

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        if !clientPath.isEmpty { unlink(clientPath); clientPath = "" }
    }

    // Find latest server socket (lexicographically last *.sock).
    private static func latestServerSocket() -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: serverDir) else {
            return nil
        }
        let socks = entries.filter { $0.hasSuffix(".sock") }.sorted()
        guard let last = socks.last else { return nil }
        return "\(serverDir)/\(last)"
    }

    private func connect() throws {
        guard let serverPath = Self.latestServerSocket() else {
            throw NSError(domain: "VHID", code: 1, userInfo: [NSLocalizedDescriptionKey: "server socket not found"])
        }

        // Unique client socket path under vhidd_client/
        let ns = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        clientPath = String(format: "\(Self.clientDir)/%llx.sock", ns)

        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        if fd < 0 { throw posixErr("socket") }

        // Bind our end so server can reply.
        var cliAddr = sockaddr_un()
        cliAddr.sun_family = sa_family_t(AF_UNIX)
        setSunPath(&cliAddr, clientPath)
        unlink(clientPath)
        let cliLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        if withUnsafePointer(to: &cliAddr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, cliLen) }
        }) < 0 { throw posixErr("bind") }

        // Connect to server (lets us use send()).
        var srvAddr = sockaddr_un()
        srvAddr.sun_family = sa_family_t(AF_UNIX)
        setSunPath(&srvAddr, serverPath)
        let srvLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        if withUnsafePointer(to: &srvAddr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, srvLen) }
        }) < 0 { throw posixErr("connect") }
    }

    private func setSunPath(_ addr: UnsafeMutablePointer<sockaddr_un>, _ path: String) {
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.pointee.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
                    strncpy(buf, cstr, 103)
                }
            }
        }
    }

    private func posixErr(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }

    // Wire frame: [type=user_data=0x01][VHID payload: 'c','p',<u16 LE proto=5>,<req>,<args>].
    // The leading 0x01 is cpp-local_datagram's send_entry::type::user_data discriminator —
    // server strips it and passes the rest to its VHID handler. Heartbeats use type=0x00.
    private func buildFrame(_ req: VHIDRequest, payload: Data = Data()) -> Data {
        var d = Data(capacity: 6 + payload.count)
        d.append(0x01) // send_entry::type::user_data
        d.append(0x63) // 'c'
        d.append(0x70) // 'p'
        d.append(0x05); d.append(0x00) // protocol v5 LE
        d.append(req.rawValue)
        d.append(payload)
        return d
    }

    private func send(_ frame: Data) throws {
        let n = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        if n < 0 { throw posixErr("send") }
    }

    private func drainReadyOrTimeout(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 256)
        while Date() < deadline {
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)
            var rfds = fd_set()
            fdZero(&rfds); fdSet(fd, &rfds)
            let r = select(fd + 1, &rfds, nil, nil, &tv)
            if r <= 0 { continue }
            let n = buf.withUnsafeMutableBufferPointer { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            // Strip leading send_entry::type byte. Heartbeats (type=0) from peer we ignore;
            // VHID responses are wrapped as user_data (type=1) containing [resp_enum][bool].
            if n < 1 { continue }
            let t = buf[0]
            if t != 0x01 { continue } // not user_data; skip heartbeats etc.
            if n < 2 { continue }
            let respEnum = buf[1]
            let payloadByte: UInt8 = n >= 3 ? buf[2] : 0
            NSLog("VHID recv n=%ld enum=%d payload=%d", n, respEnum, payloadByte)
            if let resp = VHIDResponse(rawValue: respEnum), resp == .virtualHidPointingReady, payloadByte == 1 {
                pointingReady = true
                return
            }
        }
        NSLog("VHID: timeout waiting for pointing_ready")
    }

    func ensureReady() throws {
        if fd < 0 { try connect() }
        if pointingReady { return }
        try send(buildFrame(.virtualHidPointingInitialize))
        // Daemon's initialize_timer_ fires every 5s to poke the dext, so allow >5s.
        drainReadyOrTimeout(timeout: 10.0)
    }

    func jiggle() throws {
        try ensureReady()
        guard pointingReady else {
            throw NSError(domain: "VHID", code: 2, userInfo: [NSLocalizedDescriptionKey: "pointing not ready"])
        }
        try postDelta(x: 1)
        usleep(20_000)
        try postDelta(x: 0xFF) // -1 as int8
    }

    private func postDelta(x: UInt8) throws {
        var report = PointingInput()
        report.x = x
        let payload = withUnsafeBytes(of: &report) { Data($0) }
        // Defensive: packed struct in Swift should be 8 bytes already (no padding between u32 + u8*4),
        // but verify at compile/runtime.
        precondition(payload.count == 8, "PointingInput must pack to 8 bytes, got \(payload.count)")
        try send(buildFrame(.postPointingInputReport, payload: payload))
    }
}

// select() helpers (Swift doesn't expose FD_ZERO/FD_SET macros).
func fdZero(_ set: inout fd_set) {
    set = fd_set()
}
func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutablePointer(to: &set.fds_bits) {
        $0.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= mask
        }
    }
}

// MARK: - Control socket (app -> helper)

let controlPath = "/var/run/keepalive.sock"

func runControlLoop(vhid: VHIDClient) {
    unlink(controlPath)
    let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard fd >= 0 else { NSLog("KeepAliveHelper: control socket() failed: %s", strerror(errno)); exit(1) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    controlPath.withCString { cstr in
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, cstr, 103) }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
    }
    guard rc == 0 else { NSLog("KeepAliveHelper: bind failed: %s", strerror(errno)); exit(1) }
    chmod(controlPath, 0o666) // user app needs send perm

    NSLog("KeepAliveHelper: listening on %@", controlPath)

    var buf = [UInt8](repeating: 0, count: 64)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        if n <= 0 { continue }
        do {
            try vhid.jiggle()
            NSLog("KeepAliveHelper: jiggled")
        } catch {
            NSLog("KeepAliveHelper: jiggle failed: %@", "\(error)")
            // Drop state so next call re-inits.
            vhid.close()
        }
    }
}

// MARK: - main

setbuf(stdout, nil)
NSLog("KeepAliveHelper: starting (uid=%d)", getuid())

let vhid = VHIDClient()
runControlLoop(vhid: vhid)
