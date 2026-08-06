import Foundation
import BattlifyKit

/// Unix-domain-socket server: one newline-delimited JSON request/response per connection.
final class ControlServer {
    private let path: String
    private let handler: @Sendable (ControlRequest) -> ControlResponse
    private var listenFD: Int32 = -1
    /// The inode our listener is bound to. If the path later points somewhere else, another
    /// instance has taken it and nothing can reach us — see `ownsSocketPath`.
    private var boundInode: (dev: Int32, ino: UInt64)?

    init(path: String = ControlSocket.path,
         handler: @escaping @Sendable (ControlRequest) -> ControlResponse) {
        self.path = path
        self.handler = handler
    }

    /// Bring the listener up. Fatal on failure, deliberately: a daemon with no control
    /// socket looks alive to launchd while the app hangs waiting for an answer that can never
    /// come. Exiting hands the problem to launchd, which restarts us and usually clears it.
    func start() {
        unlink(path) // remove stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); fail("bind") }

        // any local user may toggle the charge limit (the only capability exposed)
        chmod(path, 0o666)

        guard listen(fd, 8) == 0 else { close(fd); fail("listen") }
        listenFD = fd
        // Remember which inode we own, so a stolen path is detectable later.
        var info = stat()
        if stat(path, &info) == 0 {
            boundInode = (info.st_dev, info.st_ino)
        }
        FileHandle.standardError.write(Data("battlify-helper: control socket listening at \(path)\n".utf8))

        let handler = self.handler
        Thread.detachNewThread {
            ControlServer.acceptLoop(fd, handler: handler)
        }
    }

    /// False once the socket path no longer refers to the inode we bound.
    ///
    /// This is what a lost control channel actually looks like in practice. Two daemons
    /// briefly overlap during an install; the second unlinks the first's socket and binds its
    /// own; the second then goes away. The survivor is still listening — on an inode nothing
    /// can reach by name — so the app gets "connection refused" from a daemon that reports
    /// itself perfectly healthy. Checked from the tick loop, which exits when it goes false.
    var ownsSocketPath: Bool {
        guard let boundInode else { return true }   // never bound cleanly; nothing to compare
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return info.st_dev == boundInode.dev && info.st_ino == boundInode.ino
    }

    private func fail(_ what: String) -> Never {
        perror(what)
        FileHandle.standardError.write(
            Data("battlify-helper: error: cannot serve the control socket at \(path); exiting so launchd retries\n".utf8))
        exit(5)
    }

    private static func acceptLoop(_ fd: Int32,
                                   handler: @escaping @Sendable (ControlRequest) -> ControlResponse) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            handleClient(client, handler: handler)
            close(client)
        }
    }

    private static func handleClient(_ fd: Int32,
                                     handler: (ControlRequest) -> ControlResponse) {
        guard let reqData = readLine(fd) else { return }

        let resp: ControlResponse
        if let req = try? JSONDecoder().decode(ControlRequest.self, from: reqData) {
            resp = handler(req)
        } else {
            // reply anyway so a version-skewed client sees an error, not a hang
            resp = ControlResponse(
                ok: false, config: .default, batteryPercent: 0,
                chargingEnabled: false, schemeDescription: "",
                message: "unrecognized request")
        }

        guard var out = try? JSONEncoder().encode(resp) else { return }
        out.append(0x0A)
        _ = out.withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress, raw.count)
        }
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var out = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n == 0 { break }
            if n < 0 { return nil }
            if byte == 0x0A { break }
            out.append(byte)
        }
        return out.isEmpty ? nil : out
    }
}
