import Foundation
import Network
@testable import CyDownload

final class LocalHTTPServer {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    typealias Handler = (String, [String: String]) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "CyDownloadTests.LocalHTTPServer")
    private let handler: Handler
    let port: UInt16

    init(handler: @escaping Handler) throws {
        self.handler = handler

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "LocalHTTPServer", code: 1)
        }
        self.port = port
    }

    deinit {
        listener.cancel()
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let data {
                buffer.append(data)
            }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? ""
                let parts = requestLine.split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
                self.send(self.handler(path, headers), on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: buffer)
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"

        var head = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 302: return "Found"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

final class FakeDownloader: RepoDownloading {
    enum Stub {
        case data(Data)
        case failure(Error)
    }

    private let lock = NSLock()
    private var stubs: [String: Stub] = [:]
    private var requests: [String] = []
    private var fileRequests: [(source: URL, destination: URL)] = []
    var delay: Duration?

    func stub(_ url: URL, data: Data) {
        lock.lock()
        stubs[url.absoluteString] = .data(data)
        lock.unlock()
    }

    func stub(_ url: URL, error: Error) {
        lock.lock()
        stubs[url.absoluteString] = .failure(error)
        lock.unlock()
    }

    func requestedURLs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func requestedFiles() -> [(source: URL, destination: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return fileRequests
    }

    func requestCount(for url: URL) -> Int {
        requestedURLs().filter { $0 == url.absoluteString }.count
    }

    func download(_ url: URL, maxBytes: Int, progress: @escaping (TransferProgress) -> Void) async throws -> Data {
        lock.lock()
        requests.append(url.absoluteString)
        let stub = stubs[url.absoluteString]
        let delay = delay
        lock.unlock()

        if let delay {
            try? await Task.sleep(for: delay)
        }

        switch stub {
        case .data(let data):
            progress(.fraction(1))
            return data
        case .failure(let error):
            throw error
        case nil:
            throw CydiaClientError.httpStatus(404)
        }
    }

    func downloadFile(
        from url: URL,
        to destination: URL,
        maxBytes: Int64,
        progress: @escaping (TransferProgress) -> Void
    ) async throws {
        lock.lock()
        requests.append(url.absoluteString)
        fileRequests.append((url, destination))
        let stub = stubs[url.absoluteString]
        let delay = delay
        lock.unlock()

        if let delay {
            try? await Task.sleep(for: delay)
        }

        switch stub {
        case .data(let data):
            try data.write(to: destination, options: .atomic)
            progress(.fraction(1))
        case .failure(let error):
            throw error
        case nil:
            throw CydiaClientError.httpStatus(404)
        }
    }
}

enum TestData {
    static let packageText = """
    Package: com.example.test
    Version: 1.0
    Section: Tweaks
    Description: Test package

    """

    static let gzipBase64 = "H4sIAAAAAAAAAwtITM5OTE+1UkjOz9VLrUjMLchJ1StJLS7hCkstKs7Mz7NSMNQz4ApOTS4Bc0LKUxOzi7lcUouTizILoGJA5QoFEIO4AJbuII1RAAAA"
    static let bzip2Base64 = "QlpoOTFBWSZTWcOzyK4AAAnfgAAQQAFgEAQATQAqr9zAIABIamhpMgGGmk9QpoAaAANF7PUwCng6UR0N3QBL0gNrjbyKKTYyl825HEQ2gq5IA6SPbiE3yDwMJoiyS/i7kinChIYdnkVw"

    static var gzip: Data {
        Data(base64Encoded: gzipBase64, options: .ignoreUnknownCharacters)!
    }

    static var bzip2: Data {
        Data(base64Encoded: bzip2Base64, options: .ignoreUnknownCharacters)!
    }
}
