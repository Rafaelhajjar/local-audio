import Foundation

protocol ModelDownloading: Sendable {
    func download(_ file: ModelManifestFile, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

struct StreamingModelDownloader: ModelDownloading {
    private let makeSession: @Sendable () -> URLSession
    init(makeSession: @escaping @Sendable () -> URLSession = StreamingModelDownloader.ephemeralSession) {
        self.makeSession = makeSession
    }
    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        return URLSession(configuration: configuration)
    }
    func download(_ file: ModelManifestFile, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = ModelDownloadProgress(limit: file.size, callback: progress)
        var request = URLRequest(url: file.url)
        request.setValue("LocalAudio model setup", forHTTPHeaderField: "User-Agent")
        let result: (URL, URLResponse)
        do {
            result = try await session.download(for: request, delegate: delegate)
        } catch {
            if delegate.wasOversized {
                throw ModelSetupError.message("The model server sent more bytes than expected for \(file.path). The file was rejected.")
            }
            throw error
        }
        let (temporary, response) = result
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelSetupError.message("Model server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Retry the download.")
        }
        guard (response.url?.scheme == "https") else {
            throw ModelSetupError.message("The model server redirected to an insecure URL.")
        }
        guard Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == file.size else {
            throw ModelSetupError.message("The model server sent an unexpected file size for \(file.path). Retry setup.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let callback: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var oversized = false
    var wasOversized: Bool { lock.withLock { oversized } }
    init(limit: Int64, callback: @escaping @Sendable (Int64) -> Void) {
        self.limit = limit
        self.callback = callback
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit,
              totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown || totalBytesExpectedToWrite <= limit else {
            lock.withLock { oversized = true }
            downloadTask.cancel()
            return
        }
        callback(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Hugging Face may redirect immutable assets to signed CDN URLs. Only
        // HTTPS is allowed; the expected byte hash remains the trust boundary.
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
