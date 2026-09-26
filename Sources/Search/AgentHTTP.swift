import Foundation
import Darwin

// MODULE: AgentHTTP
// PURPOSE: Accept bounded HTTP/JSON requests on IPv4 loopback and hand them to the runtime.
// CORE DATA STRUCTURES: One client object per socket; each request buffer is capped at 2 MiB.
// TO MODIFY BEHAVIOR: Edit parsing and response encoding here; browser policy belongs in AgentRuntime.
// DO NOT: Bind a wildcard interface or run WebKit work from a socket callback.
// EXTENSION POINT: The request handler closure supplies routing without coupling the transport to browser state.

@MainActor
final class AgentHTTPServer {
    typealias Handler = (String, String, [String: String], [String: Any], @escaping ([String: Any]) -> Void) -> Void
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var handler: Handler?
    private(set) var port: UInt16 = 0

    func start(_ handler: @escaping Handler) -> Bool {
        guard listener < 0 else { return true }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, Darwin.listen(fd, 32) == 0 else { Darwin.close(fd); return false }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &bound, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }) == 0 else { Darwin.close(fd); return false }
        port = UInt16(bigEndian: bound.sin_port)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.handler = handler
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel(); source = nil
        if listener >= 0 { Darwin.close(listener); listener = -1 }
        Array(clients.values).forEach { $0.close() }
        clients = [:]
        port = 0
    }

    private func accept() {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            let client = Client(fd: fd, handler: { [weak self] method, path, headers, body, reply in
                self?.handler?(method, path, headers, body, reply)
            }, gone: { [weak self] fd in self?.clients[fd] = nil })
            clients[fd] = client
        }
    }

    // Socket state is touched on the main queue; the writer owns a duplicated descriptor.
    private final class Client: @unchecked Sendable {
        let fd: Int32
        private var buffer = Data()
        private var source: DispatchSourceRead!
        private let handler: Handler
        private let gone: (Int32) -> Void
        private var answered = false
        private var closed = false

        init(fd: Int32, handler: @escaping Handler, gone: @escaping (Int32) -> Void) {
            self.fd = fd; self.handler = handler; self.gone = gone
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read() }
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { if count == 0 || errno != EAGAIN { close() }; return }
            buffer.append(contentsOf: chunk[..<count])
            guard buffer.count <= 2_000_000 else { respond(["ok": false, "error": ["code": "INVALID_ACTION", "message": "Request too large"]]); return }
            let delimiter = Data("\r\n\r\n".utf8)
            guard let range = buffer.range(of: delimiter) else { return }
            guard let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { close(); return }
            let lines = head.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count >= 2 else { close(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length >= 0, length <= 2_000_000 else { close(); return }
            let start = range.upperBound
            guard buffer.count - start >= length else { return }
            let body = length == 0 ? [:] : ((try? JSONSerialization.jsonObject(with: buffer[start..<(start + length)])) as? [String: Any])
            guard let body else { respond(["ok": false, "error": ["code": "INVALID_ACTION", "message": "Invalid JSON"]]); return }
            source.cancel()
            handler(String(first[0]), String(first[1]), headers, body) { [weak self] response in self?.respond(response) }
        }

        private func respond(_ object: [String: Any]) {
            guard !answered else { return }
            answered = true
            let safe: [String: Any] = JSONSerialization.isValidJSONObject(object)
                ? object : ["ok": false, "error": ["code": "INTERNAL_ERROR", "message": "Response was not JSON compatible"]]
            let data = (try? JSONSerialization.data(withJSONObject: safe)) ?? Data("{}".utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(data)
            let writeFD = Darwin.dup(fd)
            guard writeFD >= 0 else { close(); return }
            DispatchQueue.global(qos: .utility).async {
                response.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.write(writeFD, base + offset, bytes.count - offset)
                        if written > 0 { offset += written }
                        else if errno == EAGAIN { usleep(2000) }
                        else { break }
                    }
                }
                Darwin.close(writeFD)
                DispatchQueue.main.async { [weak self] in self?.close() }
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            if !source.isCancelled { source.cancel() }
            Darwin.close(fd)
            gone(fd)
        }
    }
}
