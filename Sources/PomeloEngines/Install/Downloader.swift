import Darwin
import Foundation

/// Fetches one file. Throws `InstallError.downloadFailed` or `.tooLarge`, or `CancellationError` when the calling
/// task is cancelled; on any failure the file it created is gone.
public protocol Downloader: Sendable {
    /// Writes the body of `url` to `file`, which must not exist yet, stopping once more than `maxBytes` arrive.
    func download(
        _ url: URL, to file: URL, maxBytes: Int64,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws
}

/// Downloads over `https` only, through an ephemeral session (no cookies, no cache, no credentials stored).
public struct URLSessionDownloader: Downloader {
    private let configuration: URLSessionConfiguration

    public init() { self.init(configuration: .ephemeral) }

    /// Tests pass a configuration whose `protocolClasses` answer every request without the network.
    init(configuration: URLSessionConfiguration) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        self.configuration = configuration
    }

    public func download(
        _ url: URL, to file: URL, maxBytes: Int64,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws {
        guard url.scheme?.lowercased() == "https" else { throw InstallError.downloadFailed }
        try Task.checkCancellation()
        // O_EXCL: never write into something already there; 0600: nobody else reads the unverified bytes.
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw InstallError.downloadFailed }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        let transfer = Transfer(output: output, maxBytes: maxBytes, progress: progress)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        let task = session.dataTask(with: URLRequest(url: url))
        let failure: (any Error)? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                transfer.start(task, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel(with: CancellationError())
        }
        session.invalidateAndCancel()
        try? output.close()
        if let failure {
            try? FileManager.default.removeItem(at: file)
            throw failure is CancellationError || Task.isCancelled ? CancellationError() : failure
        }
    }
}

/// One transfer's delegate. The session's serial delegate queue calls it; `cancel` may come from any thread, so
/// the state is behind a lock and the continuation is resumed exactly once.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let output: FileHandle
    private let maxBytes: Int64
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<(any Error)?, Never>?
    private var failure: (any Error)?
    private var finished = false
    private var received: Int64 = 0
    private var expected: Int64?

    init(output: FileHandle, maxBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.output = output
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func start(_ task: URLSessionTask, continuation: CheckedContinuation<(any Error)?, Never>) {
        let cancelledAlready = lock.withLock {
            self.task = task
            self.continuation = continuation
            return failure != nil
        }
        if cancelledAlready { finish() } else { task.resume() }
    }

    /// Records the first failure and stops the task; its completion (or `start`) resumes the caller.
    func cancel(with error: any Error) {
        let task = lock.withLock {
            if failure == nil { failure = error }
            return self.task
        }
        task?.cancel()
    }

    private func finish(_ transportError: (any Error)? = nil) {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<(any Error)?, Never>?, (any Error)?) in
            guard !finished, let continuation else { return (nil, nil) }
            finished = true
            self.continuation = nil
            return (continuation, failure ?? transportError.map { _ in InstallError.downloadFailed })
        }
        continuation?.resume(returning: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            cancel(with: InstallError.downloadFailed)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            response.url?.scheme?.lowercased() == "https"
        else {
            cancel(with: InstallError.downloadFailed)
            completionHandler(.cancel)
            return
        }
        let length = response.expectedContentLength
        if length > maxBytes {
            cancel(with: InstallError.tooLarge)
            completionHandler(.cancel)
            return
        }
        lock.withLock { expected = length > 0 ? length : nil }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (total, expected, stopped) = lock.withLock { () -> (Int64, Int64?, Bool) in
            if failure != nil { return (received, self.expected, true) }
            received += Int64(data.count)
            return (received, self.expected, false)
        }
        guard !stopped else { return }
        guard total <= maxBytes else {
            cancel(with: InstallError.tooLarge)
            return
        }
        do {
            try output.write(contentsOf: data)
        } catch {
            cancel(with: InstallError.downloadFailed)
            return
        }
        progress(total, expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error)
    }
}
