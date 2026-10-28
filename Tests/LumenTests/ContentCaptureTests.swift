import Foundation
@testable import LumenKit

// F15: downloads are bounded during transfer, statuses and content types are
// validated, and successful fetches are cached by normalized URL.

func runCaptureTests() async {
    func makeService() -> ContentCaptureService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ContentCaptureService(session: URLSession(configuration: config))
    }

    func segment(url: URL) -> ActivitySegment {
        TestSupport.segment(
            from: Date().addingTimeInterval(-600),
            to: Date(),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Example",
            urlString: url.absoluteString,
            domain: url.host
        )
    }

    await runTest("capture: normal pages are captured and cached by normalized URL") {
        let url = URL(string: "https://example.com/article?utm_source=x&id=1")!
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data("<html><title>Hello</title><body><p>World content here</p></body></html>".utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let service = makeService()

        let first = await service.capture(for: segment(url: url))
        checkEqual(first.status, ContentStatus.ready, "captured")
        checkEqual(first.title, "Hello", "title extracted")
        check(first.text.contains("World content here"), "body text captured")
        checkEqual(first.source, "url-session", "came from the network")

        // Tracking parameters and fragment do not defeat the cache.
        let revisit = URL(string: "https://example.com/article?utm_source=y&id=1#top")!
        let second = await service.capture(for: segment(url: revisit))
        checkEqual(second.source, "cache", "normalized URL hits the cache")
    }

    await runTest("capture: oversized responses fail fast with a useful status") {
        let url = URL(string: "https://example.com/huge")!
        let body = Data(String(repeating: "a", count: 3_000_000).utf8)
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, body)
        }
        defer { MockURLProtocol.handler = nil }
        let service = makeService()

        let artifact = await service.capture(for: segment(url: url))
        checkEqual(artifact.status, ContentStatus.failed, "oversized fails")
        check(artifact.errorMessage?.contains("exceeded") == true, "failure explains the limit")
    }

    await runTest("capture: binary content types are rejected before parsing") {
        let url = URL(string: "https://example.com/image")!
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, Data(repeating: 0xFF, count: 1024))
        }
        defer { MockURLProtocol.handler = nil }
        let service = makeService()

        let artifact = await service.capture(for: segment(url: url))
        checkEqual(artifact.status, ContentStatus.failed, "binary rejected")
        check(artifact.errorMessage?.contains("Unsupported content type") == true, "failure names the type")
    }

    await runTest("capture: HTTP error statuses are reported") {
        let url = URL(string: "https://example.com/missing")!
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("not found".utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let service = makeService()

        let artifact = await service.capture(for: segment(url: url))
        checkEqual(artifact.status, ContentStatus.failed, "404 fails")
        checkEqual(artifact.errorMessage ?? "", "HTTP 404", "status surfaced")
    }

    await runTest("capture: declared oversized bodies are rejected at the headers") {
        let url = URL(string: "https://example.com/declared-huge")!
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html", "Content-Length": "3000000"]
            )!
            // The byte loop itself would accept this small body.
            return (response, Data("Small body".utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let artifact = await makeService().capture(for: segment(url: url))
        checkEqual(artifact.status, ContentStatus.failed, "declared size rejected")
        check(artifact.errorMessage?.contains("exceeded") == true, "header rejection explains the limit")
    }

    await runTest("capture: MIME parameter whitespace does not reject text") {
        let url = URL(string: "https://example.com/whitespace")!
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html ; charset=utf-8"]
            )!
            return (response, Data("<p>Readable body</p>".utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let artifact = await makeService().capture(for: segment(url: url))
        checkEqual(artifact.status, ContentStatus.ready, "valid MIME type accepted")
    }

    await runTest("capture: a cancelled task does not fetch or fall back to YouTube metadata") {
        let service = makeService()
        let input = segment(url: URL(string: "https://youtube.com/watch?v=dQw4w9WgXcQ")!)
        MockURLProtocol.handler = { _ in throw URLError(.unsupportedURL) }
        defer { MockURLProtocol.handler = nil }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.capture(for: input)
        }
        let artifact = await task.value
        checkEqual(artifact.errorMessage ?? "", "Capture cancelled", "cancelled before any request")
    }

    await runTest("capture: cache keys lowercase hosts") {
        checkEqual(
            ContentCaptureService.normalizedCacheKey(URL(string: "https://EXAMPLE.com/article")!),
            ContentCaptureService.normalizedCacheKey(URL(string: "https://example.com/article")!),
            "host case does not defeat the cache"
        )
    }

    await runTest("capture: YouTube IDs match exact hosts and true subdomains only") {
        func id(_ string: String) -> String? {
            ContentCaptureService.youtubeVideoID(from: URL(string: string)!)
        }
        checkEqual(id("https://www.youtube.com/watch?v=dQw4w9WgXcQ") ?? "", "dQw4w9WgXcQ", "www.youtube.com")
        checkEqual(id("https://music.youtube.com/watch?v=dQw4w9WgXcQ") ?? "", "dQw4w9WgXcQ", "music subdomain")
        checkEqual(id("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ") ?? "", "dQw4w9WgXcQ", "nocookie subdomain")
        checkEqual(id("https://youtu.be/dQw4w9WgXcQ") ?? "", "dQw4w9WgXcQ", "short host")
        check(id("https://fake-youtu.be/dQw4w9WgXcQ") == nil, "lookalike short host rejected")
        check(id("https://not-youtube.com/watch?v=dQw4w9WgXcQ") == nil, "lookalike watch host rejected")
        check(id("https://example.com/watch?v=dQw4w9WgXcQ") == nil, "other host rejected")
    }
}

/// In-memory URL protocol so capture tests never touch the network.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
