import Foundation
import Darwin

// VHID daemon IPC client. Speaks Karabiner-DriverKit-VirtualHIDDevice v6.5.0's
// Unix domain datagram protocol.
//
// Lifecycle:
//   1. init() opens sockets, starts background recv loop.
//   2. Call initializePointing() once at startup.
//   3. When pointingReady becomes true (observed in recv loop), nudge() will succeed.
//   4. Helper process is long-lived under launchd; deinit happens on shutdown only.
//
// All outbound sends are serialized on a single queue so writes don't interleave.

final class VHIDClient {

    // MARK: - Protocol constants

    static let rootOnlyDir = "/Library/Application Support/org.pqrs/tmp/rootonly"
    static let serverSocketDir = "\(rootOnlyDir)/vhidd_server"
    static let clientSocketDir = "\(rootOnlyDir)/vhidd_client"
    static let protocolVersion: UInt16 = 5

    enum Request: UInt8 {
        case virtualHIDPointingInitialize = 4
        case postPointingInputReport = 12
    }

    enum Response: UInt8 {
        case driverActivated = 1
        case driverConnected = 2
        case driverVersionMismatched = 3
        case virtualHIDKeyboardReady = 4
        case virtualHIDPointingReady = 5
    }

    // MARK: - State (writes confined to ioQueue)

    private let ioQueue = DispatchQueue(label: "keepalive.helper.vhid")
    private var fd: Int32 = -1
    private var serverPath: String = ""
    private var clientPath: String = ""

    private(set) var driverConnected = false
    private(set) var driverActivated = false
    private(set) var driverVersionMismatched = false
    private(set) var pointingReady = false
    private(set) var lastError: String?

    private var recvThread: Thread?
    private var stopping = false

    // MARK: - Init

    init() throws {
        guard getuid() == 0 else {
            throw NSError(domain: "VHIDClient", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "helper must run as root"])
        }
        guard let server = Self.findServerSocket() else {
            throw NSError(domain: "VHIDClient", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "no VHID server socket under \(Self.serverSocketDir)"])
        }
        serverPath = server
        clientPath = Self.makeClientSocketPath()

        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        if fd < 0 { throw Self.posixError("socket") }

        unlink(clientPath)
        var addr = Self.makeSockaddrUn(path: clientPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 { throw Self.posixError("bind(\(clientPath))") }
        chmod(clientPath, 0o600)

        // 500ms recv timeout so the thread can exit promptly.
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        NSLog("VHIDClient: server=%@ client=%@", serverPath, clientPath)

        startRecvLoop()
    }

    deinit {
        stopping = true
        if fd >= 0 { close(fd) }
        unlink(clientPath)
    }

    // MARK: - Public API

    func initializePointing() {
        send(request: .virtualHIDPointingInitialize)
    }

    /// Post +1 / -1 dx pair. No-op if pointing isn't ready yet.
    /// Returns (success, error).
    func nudge() -> (Bool, String?) {
        if !pointingReady {
            return (false, "pointing not ready (driverConnected=\(driverConnected) mismatched=\(driverVersionMismatched))")
        }
        send(request: .postPointingInputReport, payload: Self.pointingReport(dx: 1))
        usleep(80_000)
        send(request: .postPointingInputReport, payload: Self.pointingReport(dx: -1))
        return (true, nil)
    }

    // MARK: - Wire send

    private func send(request: Request, payload: Data = Data()) {
        ioQueue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var buf = Data()
            buf.append(0x63) // 'c'
            buf.append(0x70) // 'p'
            var v = Self.protocolVersion.littleEndian
            withUnsafeBytes(of: &v) { buf.append(contentsOf: $0) }
            buf.append(request.rawValue)
            buf.append(payload)

            var remoteAddr = Self.makeSockaddrUn(path: self.serverPath)
            let sent = buf.withUnsafeBytes { rawBuf -> ssize_t in
                withUnsafePointer(to: &remoteAddr) { addrPtr -> ssize_t in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(self.fd,
                               rawBuf.baseAddress, buf.count, 0,
                               saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            if sent < 0 {
                let errStr = String(cString: strerror(errno))
                NSLog("VHIDClient: sendto failed req=%d errno=%d %@",
                      Int(request.rawValue), errno, errStr)
                self.lastError = "sendto \(request): \(errStr)"
            }
        }
    }

    // MARK: - Recv loop (own thread, not GCD, so we can use blocking recvfrom cleanly)

    private func startRecvLoop() {
        let t = Thread { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 1024)
            while !self.stopping {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> ssize_t in
                    Darwin.recv(self.fd, ptr.baseAddress, ptr.count, 0)
                }
                if n <= 0 { continue } // timeout or transient
                guard let resp = Response(rawValue: buf[0]) else { continue }
                let value: UInt8 = n >= 2 ? buf[1] : 0
                self.handleResponse(resp, value: value)
            }
        }
        t.name = "vhid-recv"
        t.start()
        recvThread = t
    }

    private func handleResponse(_ resp: Response, value: UInt8) {
        // Mutations are low-rate, single-reader; a barrier queue isn't worth the
        // complexity. If we ever expose these to the XPC handler mid-transition
        // we get stale-by-one, which is fine.
        switch resp {
        case .driverActivated:
            driverActivated = (value == 1)
            NSLog("VHIDClient: driver_activated=%d", Int(value))
        case .driverConnected:
            driverConnected = (value == 1)
            NSLog("VHIDClient: driver_connected=%d", Int(value))
        case .driverVersionMismatched:
            driverVersionMismatched = (value == 1)
            if value == 1 { lastError = "driver_version_mismatched" }
            NSLog("VHIDClient: driver_version_mismatched=%d", Int(value))
        case .virtualHIDPointingReady:
            pointingReady = (value == 1)
            NSLog("VHIDClient: pointing_ready=%d", Int(value))
        case .virtualHIDKeyboardReady:
            break // unused
        }
    }

    // MARK: - Helpers

    static func findServerSocket() -> String? {
        guard let dir = opendir(serverSocketDir) else { return nil }
        defer { closedir(dir) }
        var matches: [String] = []
        while let entPtr = readdir(dir) {
            let ent = entPtr.pointee
            let name = withUnsafeBytes(of: ent.d_name) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name.hasSuffix(".sock") {
                matches.append("\(serverSocketDir)/\(name)")
            }
        }
        return matches.sorted().last
    }

    static func makeClientSocketPath() -> String {
        mkdir(clientSocketDir, 0o700)
        while true {
            let ns = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            let path = String(format: "%@/%llx.sock", clientSocketDir, ns)
            if access(path, F_OK) != 0 { return path }
        }
    }

    static func makeSockaddrUn(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        precondition(pathBytes.count < 104, "sun_path overflow")
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
            raw.storeBytes(of: 0, toByteOffset: pathBytes.count, as: UInt8.self)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Packed pointing_input = buttons(u32 LE) + x(i8) + y(i8) + vwheel(i8) + hwheel(i8) = 8 bytes.
    static func pointingReport(dx: Int8 = 0, dy: Int8 = 0) -> Data {
        var d = Data(count: 8)
        d[4] = UInt8(bitPattern: dx)
        d[5] = UInt8(bitPattern: dy)
        return d
    }

    static func posixError(_ op: String) -> NSError {
        NSError(domain: "VHIDClient", code: 100,
                userInfo: [NSLocalizedDescriptionKey:
                           "\(op) failed: \(String(cString: strerror(errno))) (errno=\(errno))"])
    }
}
