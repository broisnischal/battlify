import Foundation
import BattPieKit

/// Unix-domain-socket server the daemon runs so the GUI can query status and push
/// config changes. Each connection carries one newline-delimited JSON request and
/// receives one JSON response. Runs its accept loop on a background thread.
final class ControlServer {
    private let path: String
    private let handler: @Sendable (ControlRequest) -> ControlResponse
    private var listenFD: Int32 = -1

    init(path: String = ControlSocket.path,
         handler: @escaping @Sendable (ControlRequest) -> ControlResponse) {
        self.path = path
        self.handler = handler
    }

    func start() {
        unlink(path) // remove stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { perror("socket"); return }

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
        guard bound == 0 else { perror("bind"); close(fd); return }

        // Personal-tool permissions: any local user may toggle the charge limit.
        // (The only capability exposed is battery charge control.)
        chmod(path, 0o666)

        guard listen(fd, 8) == 0 else { perror("listen"); close(fd); return }
        listenFD = fd

        let handler = self.handler
        Thread.detachNewThread {
            ControlServer.acceptLoop(fd, handler: handler)
        }
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
        guard let reqData = readLine(fd),
              let req = try? JSONDecoder().decode(ControlRequest.self, from: reqData) else {
            return
        }
        let resp = handler(req)
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
