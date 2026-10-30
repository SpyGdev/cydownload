import Foundation

enum CydiaClientError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case network(String)
    case tooLarge(Int64)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .network(let message):
            return message
        case .tooLarge(let limit):
            return "The download exceeded the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) limit."
        case .invalidResponse:
            return "The server returned an invalid response."
        }
    }
}

protocol RepoDownloading: AnyObject {
    func download(_ url: URL, maxBytes: Int, progress: @escaping (TransferProgress) -> Void) async throws -> Data
    func downloadFile(
        from url: URL,
        to destination: URL,
        maxBytes: Int64,
        progress: @escaping (TransferProgress) -> Void
    ) async throws
}

/// Downloads with the same Cydia client headers the original app sent, and follows redirects.
/// Each URLSession task keeps its own state so overlapping requests cannot corrupt one another.
final class CydiaClient: NSObject, RepoDownloading, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let headers = [
        "X-Machine": "iPhone6,1",
        "X-Unique-ID": "8843d7f92416211de9ebb963ff4ce28125932878",
        "X-Firmware": "10.1.1",
        "User-Agent": "Telesphoreo APT-HTTP/1.0.592",
    ]

    private struct DataTransfer {
        var buffer = Data()
        var expected: Int64 = -1
        var status = 0
        var limit = 0
        var continuation: CheckedContinuation<Data, Error>?
        var progress: ((TransferProgress) -> Void)?
    }

    private struct FileTransfer {
        var handle: FileHandle
        var partialURL: URL
        var destination: URL
        var expected: Int64 = -1
        var status = 0
        var limit: Int64 = 0
        var received: Int64 = 0
        var continuation: CheckedContinuation<Void, Error>?
        var progress: ((TransferProgress) -> Void)?
    }

    private let sessionConfiguration: URLSessionConfiguration
    private lazy var session: URLSession = {
        URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
    }()

    private let lock = NSLock()
    private var dataTransfers: [Int: DataTransfer] = [:]
    private var fileTransfers: [Int: FileTransfer] = [:]

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.sessionConfiguration = sessionConfiguration
        super.init()
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 300
    }

    func download(_ url: URL, maxBytes: Int, progress: @escaping (TransferProgress) -> Void) async throws -> Data {
        var request = URLRequest(url: url)
        applyHeaders(to: &request)

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            dataTransfers[task.taskIdentifier] = DataTransfer(
                limit: maxBytes,
                continuation: continuation,
                progress: progress
            )
            lock.unlock()
            task.resume()
        }
    }

    func downloadFile(
        from url: URL,
        to destination: URL,
        maxBytes: Int64,
        progress: @escaping (TransferProgress) -> Void
    ) async throws {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).part-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CydiaClientError.network("Could not create the download file.")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw CydiaClientError.network(error.localizedDescription)
        }

        var request = URLRequest(url: url)
        applyHeaders(to: &request)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.dataTask(with: request)
                lock.lock()
                fileTransfers[task.taskIdentifier] = FileTransfer(
                    handle: handle,
                    partialURL: partial,
                    destination: destination,
                    limit: maxBytes,
                    continuation: continuation,
                    progress: progress
                )
                lock.unlock()
                task.resume()
            }
        } catch {
            // The completion handler already closed the handle and removed the
            // partial file; this cleanup covers the case where it did not.
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let expected = response.expectedContentLength
        let id = dataTask.taskIdentifier

        lock.lock()
        if var transfer = dataTransfers[id] {
            if (200..<300).contains(code) && !(200..<300).contains(transfer.status) {
                transfer.buffer.removeAll(keepingCapacity: true)
            }
            transfer.status = code
            transfer.expected = expected
            dataTransfers[id] = transfer
            lock.unlock()
            transfer.progress?(expected > 0 ? .fraction(0) : .indeterminate)
        } else if var transfer = fileTransfers[id] {
            if (200..<300).contains(code) && !(200..<300).contains(transfer.status) {
                try? transfer.handle.truncate(atOffset: 0)
                transfer.received = 0
            }
            transfer.status = code
            transfer.expected = expected
            fileTransfers[id] = transfer
            lock.unlock()
            transfer.progress?(expected > 0 ? .fraction(0) : .indeterminate)
        } else {
            lock.unlock()
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier

        lock.lock()
        if var transfer = dataTransfers[id] {
            transfer.buffer.append(data)
            let count = transfer.buffer.count
            let limit = transfer.limit
            let expected = transfer.expected
            let progress = transfer.progress

            if count > limit {
                dataTransfers.removeValue(forKey: id)
                lock.unlock()
                dataTask.cancel()
                progress?(.indeterminate)
                transfer.continuation?.resume(throwing: CydiaClientError.tooLarge(Int64(limit)))
                return
            }

            dataTransfers[id] = transfer
            lock.unlock()
            progress?(expected > 0 ? .fraction(min(1, Double(count) / Double(expected))) : .indeterminate)
            return
        }

        if var transfer = fileTransfers[id] {
            transfer.received += Int64(data.count)
            let received = transfer.received
            let expected = transfer.expected
            let limit = transfer.limit
            let progress = transfer.progress

            if received > limit {
                fileTransfers.removeValue(forKey: id)
                lock.unlock()
                dataTask.cancel()
                try? transfer.handle.close()
                try? FileManager.default.removeItem(at: transfer.partialURL)
                progress?(.indeterminate)
                transfer.continuation?.resume(throwing: CydiaClientError.tooLarge(limit))
                return
            }

            do {
                try transfer.handle.write(contentsOf: data)
            } catch {
                fileTransfers.removeValue(forKey: id)
                lock.unlock()
                dataTask.cancel()
                try? transfer.handle.close()
                try? FileManager.default.removeItem(at: transfer.partialURL)
                transfer.continuation?.resume(throwing: CydiaClientError.network(error.localizedDescription))
                return
            }

            fileTransfers[id] = transfer
            lock.unlock()
            progress?(expected > 0 ? .fraction(min(1, Double(received) / Double(expected))) : .indeterminate)
            return
        }

        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier

        lock.lock()
        let isFile = fileTransfers[id] != nil
        let isData = dataTransfers[id] != nil
        lock.unlock()

        if isFile {
            finishFileTransfer(id: id, error: error)
        } else if isData {
            finishDataTransfer(id: id, error: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        applyHeaders(to: &redirected)
        completionHandler(redirected)
    }

    private func finishDataTransfer(id: Int, error: Error?) {
        lock.lock()
        guard let transfer = dataTransfers.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let error {
            transfer.continuation?.resume(throwing: CydiaClientError.network(error.localizedDescription))
            return
        }
        guard (200..<300).contains(transfer.status) else {
            transfer.continuation?.resume(throwing: CydiaClientError.httpStatus(transfer.status))
            return
        }
        transfer.progress?(.fraction(1))
        transfer.continuation?.resume(returning: transfer.buffer)
    }

    private func finishFileTransfer(id: Int, error: Error?) {
        lock.lock()
        guard let transfer = fileTransfers.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let error {
            try? transfer.handle.close()
            try? FileManager.default.removeItem(at: transfer.partialURL)
            transfer.continuation?.resume(throwing: CydiaClientError.network(error.localizedDescription))
            return
        }

        guard (200..<300).contains(transfer.status) else {
            try? transfer.handle.close()
            try? FileManager.default.removeItem(at: transfer.partialURL)
            transfer.continuation?.resume(throwing: CydiaClientError.httpStatus(transfer.status))
            return
        }

        do {
            try transfer.handle.close()
            if FileManager.default.fileExists(atPath: transfer.destination.path) {
                _ = try FileManager.default.replaceItemAt(transfer.destination, withItemAt: transfer.partialURL)
            } else {
                try FileManager.default.moveItem(at: transfer.partialURL, to: transfer.destination)
            }
            transfer.progress?(.fraction(1))
            transfer.continuation?.resume()
        } catch {
            try? FileManager.default.removeItem(at: transfer.partialURL)
            transfer.continuation?.resume(throwing: CydiaClientError.network(error.localizedDescription))
        }
    }

    private func applyHeaders(to request: inout URLRequest) {
        for (key, value) in Self.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}
