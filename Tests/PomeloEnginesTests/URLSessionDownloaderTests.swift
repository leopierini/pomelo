import Darwin
import Foundation
import Testing
import os
@testable import PomeloEngines
import PomeloTestSupport

/// Answers every request of a session from a table keyed by URL: no request leaves the process.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        /// A status, headers, the body in chunks, and whether to stall after the first chunk until stopped.
        case body(status: Int, headers: [String: String], chunks: [Data], stalls: Bool = false)
        case redirect(to: URL)
    }

    private static let state = OSAllocatedUnfairLock(initialState: (replies: [URL: Reply](), requested: [URL]()))

    static func serve(_ url: URL, _ reply: Reply) { state.withLock { $0.replies[url] = reply } }
    static func requested(_ url: URL) -> Bool { state.withLock { $0.requested.contains(url) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.state.withLock { state -> Reply? in
            state.requested.append(url)
            return state.replies[url]
        }
        switch reply {
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .body(let status, let headers, let chunks, let stalls):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for (index, chunk) in chunks.enumerated() {
                client?.urlProtocol(self, didLoad: chunk)
                if stalls && index == 0 { return }
            }
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }

    override func stopLoading() {}
}

@Suite struct URLSessionDownloaderTests {
    private let downloader: URLSessionDownloader = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionDownloader(configuration: configuration)
    }()

    private func uniqueURL(_ scheme: String = "https") -> URL {
        URL(string: "\(scheme)://\(UUID().uuidString.lowercased()).example.invalid/file.zip")!
    }

    private func failure(_ body: () async throws -> Void) async -> (any Error)? {
        do { try await body(); return nil } catch { return error }
    }

    @Test func writesTheBodyPrivatelyAndReportsProgress() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL()
        let chunks = [Data(repeating: 1, count: 300), Data(repeating: 2, count: 200)]
        StubProtocol.serve(url, .body(status: 200, headers: ["Content-Length": "500"], chunks: chunks))
        let reports = OSAllocatedUnfairLock(initialState: [Int64]())
        let file = dir.appending(path: "download")

        try await downloader.download(url, to: file, maxBytes: 500) { received, expected in
            #expect(expected == 500)
            reports.withLock { $0.append(received) }
        }

        #expect(try Data(contentsOf: file) == chunks[0] + chunks[1])
        var info = stat()
        #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(reports.withLock { $0.last } == 500)
    }

    @Test func plainHTTPIsRefusedWithoutARequest() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL("http")
        StubProtocol.serve(url, .body(status: 200, headers: [:], chunks: [Data([1])]))

        let error = await failure { try await downloader.download(url, to: dir.appending(path: "d"), maxBytes: 10) { _, _ in } }

        #expect(error as? InstallError == .downloadFailed)
        #expect(!StubProtocol.requested(url))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "d").path))
    }

    @Test func aRedirectToHTTPIsRefused() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL()
        let target = uniqueURL("http")
        StubProtocol.serve(url, .redirect(to: target))
        StubProtocol.serve(target, .body(status: 200, headers: [:], chunks: [Data([1])]))

        let error = await failure { try await downloader.download(url, to: dir.appending(path: "d"), maxBytes: 10) { _, _ in } }

        #expect(error as? InstallError == .downloadFailed)
        #expect(!StubProtocol.requested(target))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "d").path))
    }

    @Test func aRedirectToHTTPSIsFollowed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL()
        let target = uniqueURL()
        StubProtocol.serve(url, .redirect(to: target))
        StubProtocol.serve(target, .body(status: 200, headers: [:], chunks: [Data([7, 8])]))
        let file = dir.appending(path: "d")

        try await downloader.download(url, to: file, maxBytes: 10) { _, _ in }

        #expect(try Data(contentsOf: file) == Data([7, 8]))
    }

    @Test func aBodyPastTheCapIsStopped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL()
        StubProtocol.serve(url, .body(status: 200, headers: [:], chunks: [Data(count: 60), Data(count: 60), Data(count: 60)]))

        let error = await failure { try await downloader.download(url, to: dir.appending(path: "d"), maxBytes: 100) { _, _ in } }

        #expect(error as? InstallError == .tooLarge)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "d").path))
    }

    @Test func aDeclaredLengthPastTheCapIsStoppedBeforeTheBody() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL()
        StubProtocol.serve(url, .body(status: 200, headers: ["Content-Length": "1000"], chunks: [Data(count: 10)]))
        let reports = OSAllocatedUnfairLock(initialState: 0)

        let error = await failure {
            try await downloader.download(url, to: dir.appending(path: "d"), maxBytes: 100) { _, _ in
                reports.withLock { $0 += 1 }
            }
        }

        #expect(error as? InstallError == .tooLarge)
        #expect(reports.withLock { $0 } == 0)
    }

    @Test func anErrorStatusFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL()
        StubProtocol.serve(url, .body(status: 404, headers: [:], chunks: [Data("not found".utf8)]))

        let error = await failure { try await downloader.download(url, to: dir.appending(path: "d"), maxBytes: 100) { _, _ in } }

        #expect(error as? InstallError == .downloadFailed)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "d").path))
    }

    @Test func anExistingFileIsNeverOverwritten() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL()
        StubProtocol.serve(url, .body(status: 200, headers: [:], chunks: [Data([1])]))
        let file = dir.appending(path: "d")
        try Data("mine".utf8).write(to: file)

        let error = await failure { try await downloader.download(url, to: file, maxBytes: 100) { _, _ in } }

        #expect(error as? InstallError == .downloadFailed)
        #expect(try Data(contentsOf: file) == Data("mine".utf8))
    }

    @Test func cancellingStopsTheDownload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = uniqueURL()
        // A typed body of 1 KB: without a Content-Type, URLSession holds the first bytes back to sniff one.
        let headers = ["Content-Type": "application/zip"]
        StubProtocol.serve(url, .body(status: 200, headers: headers, chunks: [Data(count: 1024), Data(count: 10)], stalls: true))
        let (received, receivedContinuation) = AsyncStream<Void>.makeStream()
        let file = dir.appending(path: "d")

        let task = Task {
            try await downloader.download(url, to: file, maxBytes: 4096) { _, _ in receivedContinuation.yield() }
        }
        Task { _ = try? await task.value; receivedContinuation.finish() }
        var iterator = received.makeAsyncIterator()
        _ = await iterator.next()
        let cancelled = ContinuousClock.now
        task.cancel()

        let error = await failure { try await task.value }
        #expect(error is CancellationError)
        // The session's own request timeout (60 s) would end it too: only a prompt stop is the cancel.
        #expect(ContinuousClock.now - cancelled < .seconds(10))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
