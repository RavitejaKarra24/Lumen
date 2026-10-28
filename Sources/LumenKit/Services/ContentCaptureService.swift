import Foundation

/// Fetches page text and YouTube transcripts for browser sessions.
actor ContentCaptureService {
    static let shared = ContentCaptureService()

    enum CaptureError: Error, LocalizedError {
        case httpStatus(Int)
        case unsupportedContentType(String)
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case let .httpStatus(code): "HTTP \(code)"
            case let .unsupportedContentType(type): "Unsupported content type: \(type)"
            case let .tooLarge(limit): "Response exceeded \(limit / 1_000_000) MB download limit"
            }
        }
    }

    private let session: URLSession
    private let maxTextCharacters = 20_000
    /// Download ceiling enforced during transfer, not after: the stream stops as
    /// soon as the budget is spent instead of loading a whole huge body first.
    private let maxResponseBytes = 2_000_000
    /// Content types we can meaningfully turn into text. Missing headers are
    /// allowed (some endpoints, e.g. YouTube timedtext, omit them).
    private let supportedContentTypes: Set<String> = [
        "text/html", "application/xhtml+xml", "text/plain",
        "application/xml", "text/xml", "application/json", "application/ld+json",
    ]

    private struct CachedText {
        var title: String?
        var text: String
        var fetchedAt: Date

        init(title: String?, text: String, fetchedAt: Date = .now) {
            self.title = title
            self.text = text
            self.fetchedAt = fetchedAt
        }
    }

    /// Successful downloads keyed by normalized URL, so revisiting a page within
    /// the expiry window does not re-download identical bytes.
    private var cache: [String: CachedText] = [:]
    private let cacheExpiry: TimeInterval = 6 * 60 * 60
    private let cacheLimit = 64

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 18
            config.timeoutIntervalForResource = 30
            config.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 Lumen/0.2",
                "Accept-Language": "en-US,en;q=0.9",
            ]
            self.session = URLSession(configuration: config)
        }
    }

    func capture(for segment: ActivitySegment) async -> ContentArtifact {
        guard !Task.isCancelled else {
            return failure(segment: segment, url: segment.urlString ?? "", kind: .page, message: "Capture cancelled")
        }
        guard let urlString = segment.urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            // Fall back to window title metadata only.
            let title = segment.windowTitle
            let text = [segment.windowTitle, segment.notes].filter { !$0.isEmpty }.joined(separator: "\n")
            return ContentArtifact(
                segmentID: segment.id,
                urlString: segment.urlString,
                kind: .metadata,
                title: title,
                text: text,
                status: text.isEmpty ? .skipped : .ready,
                source: "metadata"
            )
        }

        if let videoID = Self.youtubeVideoID(from: url) {
            return await captureYouTube(videoID: videoID, segment: segment, pageURL: url)
        }

        return await capturePage(url: url, segment: segment)
    }

    // MARK: - Page

    private func capturePage(url: URL, segment: ActivitySegment) async -> ContentArtifact {
        let key = Self.normalizedCacheKey(url)
        if let cached = cachedValue(for: key) {
            return ContentArtifact(
                segmentID: segment.id,
                urlString: url.absoluteString,
                kind: .page,
                title: cached.title ?? segment.windowTitle,
                text: cached.text,
                status: cached.text.isEmpty ? .failed : .ready,
                source: "cache"
            )
        }

        do {
            let (data, _) = try await fetchBounded(from: url)
            guard let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            else {
                return failure(segment: segment, url: url.absoluteString, kind: .page, message: "Unreadable encoding")
            }

            let title = Self.htmlTitle(html) ?? segment.windowTitle
            let text = String(Self.htmlToText(html).prefix(maxTextCharacters))
            if !text.isEmpty {
                store(CachedText(title: Self.htmlTitle(html), text: text), for: key)
            }
            return ContentArtifact(
                segmentID: segment.id,
                urlString: url.absoluteString,
                kind: .page,
                title: title,
                text: text,
                status: text.isEmpty ? .failed : .ready,
                errorMessage: text.isEmpty ? "Empty body" : nil,
                source: "url-session"
            )
        } catch {
            return failure(segment: segment, url: url.absoluteString, kind: .page, message: error.localizedDescription)
        }
    }

    // MARK: - Bounded transfer

    /// Streams the response body with a hard byte budget, validating status and
    /// content type up front. Reading stops (and the transfer is cancelled) as
    /// soon as the budget is spent, so a huge or binary body cannot balloon
    /// memory before the character cap ever applies.
    private func fetchBounded(from url: URL) async throws -> (data: Data, statusCode: Int) {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(from: url)
        // Dropping an AsyncBytes iterator is not a transfer cancellation contract.
        // Explicitly cancel on status/type/budget rejection as well as success.
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw CaptureError.httpStatus(0)
        }
        let status = http.statusCode
        guard (200..<400).contains(status) else {
            throw CaptureError.httpStatus(status)
        }
        if response.expectedContentLength > Int64(maxResponseBytes) {
            throw CaptureError.tooLarge(maxResponseBytes)
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            let type = (contentType.split(separator: ";").first.map(String.init) ?? contentType)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !supportedContentTypes.contains(type) {
                throw CaptureError.unsupportedContentType(type)
            }
        }

        var data = Data()
        data.reserveCapacity(65_536)
        var received = 0
        for try await byte in bytes {
            if received == maxResponseBytes {
                throw CaptureError.tooLarge(maxResponseBytes)
            }
            data.append(byte)
            received += 1
            if received.isMultiple(of: 16_384) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return (data, status)
    }

    // MARK: - Cache

    /// Normalizes a URL for caching: fragments and tracking parameters dropped,
    /// host lowercased, query sorted — repeated visits to the same page hit the
    /// same key.
    static func normalizedCacheKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        components.fragment = nil
        components.host = components.host?.lowercased()
        components.queryItems = components.queryItems?
            .filter {
                let name = $0.name.lowercased()
                return !name.hasPrefix("utm_") && name != "fbclid" && name != "gclid"
            }
            .sorted { $0.name < $1.name }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func cachedValue(for key: String) -> CachedText? {
        guard let hit = cache[key] else { return nil }
        guard hit.fetchedAt.addingTimeInterval(cacheExpiry) > Date() else {
            cache.removeValue(forKey: key)
            return nil
        }
        return hit
    }

    private func store(_ value: CachedText, for key: String) {
        if cache.count >= cacheLimit, cache[key] == nil {
            if let oldest = cache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
                cache.removeValue(forKey: oldest)
            }
        }
        cache[key] = value
    }

    // MARK: - YouTube

    private func captureYouTube(videoID: String, segment: ActivitySegment, pageURL: URL) async -> ContentArtifact {
        // 1) Try timedtext list → transcript
        if let transcript = await fetchYouTubeTranscript(videoID: videoID) {
            let title = segment.windowTitle.isEmpty ? "YouTube \(videoID)" : segment.windowTitle
            return ContentArtifact(
                segmentID: segment.id,
                urlString: pageURL.absoluteString,
                kind: .transcript,
                title: title,
                text: String(transcript.prefix(maxTextCharacters)),
                status: .ready,
                source: "youtube-timedtext"
            )
        }

        // 2) Fall back to watch page title + description-ish meta.
        let key = Self.normalizedCacheKey(pageURL)
        if let cached = cachedValue(for: key) {
            let text = cached.text
            return ContentArtifact(
                segmentID: segment.id,
                urlString: pageURL.absoluteString,
                kind: .metadata,
                title: cached.title ?? segment.windowTitle,
                text: text,
                status: text.isEmpty ? .failed : .ready,
                source: "youtube-meta"
            )
        }
        do {
            let (data, _) = try await fetchBounded(from: pageURL)
            if let html = String(data: data, encoding: .utf8) {
                let pageTitle = Self.htmlTitle(html)
                let title = pageTitle ?? segment.windowTitle
                let desc = Self.metaContent(html, property: "og:description")
                    ?? Self.metaContent(html, name: "description")
                    ?? ""
                let text = [title, desc].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !text.isEmpty {
                    store(CachedText(title: pageTitle, text: text), for: key)
                }
                return ContentArtifact(
                    segmentID: segment.id,
                    urlString: pageURL.absoluteString,
                    kind: .metadata,
                    title: title,
                    text: text,
                    status: text.isEmpty ? .failed : .ready,
                    errorMessage: text.isEmpty ? "No captions or description" : nil,
                    source: "youtube-meta"
                )
            }
        } catch {
            return failure(segment: segment, url: pageURL.absoluteString, kind: .transcript, message: error.localizedDescription)
        }

        return failure(segment: segment, url: pageURL.absoluteString, kind: .transcript, message: "Transcript unavailable")
    }

    private func fetchYouTubeTranscript(videoID: String) async -> String? {
        // List tracks
        guard let listURL = URL(string: "https://www.youtube.com/api/timedtext?type=list&v=\(videoID)") else {
            return nil
        }
        do {
            let (data, _) = try await fetchBounded(from: listURL)
            guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else { return nil }

            // Prefer en, then first track.
            let langs = Self.extractTimedTextLangs(xml)
            let lang = langs.first(where: { $0.hasPrefix("en") }) ?? langs.first
            guard let lang else { return nil }

            guard let trackURL = URL(string: "https://www.youtube.com/api/timedtext?v=\(videoID)&lang=\(lang)") else {
                return nil
            }
            let (trackData, _) = try await fetchBounded(from: trackURL)
            guard let trackXML = String(data: trackData, encoding: .utf8) else { return nil }
            let text = Self.extractTimedTextBody(trackXML)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func failure(segment: ActivitySegment, url: String, kind: ContentKind, message: String) -> ContentArtifact {
        ContentArtifact(
            segmentID: segment.id,
            urlString: url,
            kind: kind,
            title: segment.windowTitle,
            text: segment.windowTitle,
            status: .failed,
            errorMessage: message,
            source: "error"
        )
    }

    static func youtubeVideoID(from url: URL) -> String? {
        // Exact hosts or true subdomains only: substring matching made
        // notyoutube.be and fake-youtube.com look like YouTube.
        let host = url.host?.lowercased() ?? ""
        let isShortHost = host == "youtu.be" || host.hasSuffix(".youtu.be")
        let isWatchHost = host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        if isShortHost {
            let id = url.path.split(separator: "/").first.map(String.init)
            return validVideoID(id)
        }
        if isWatchHost {
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
                return validVideoID(v)
            }
            // /embed/ID or /shorts/ID
            let parts = url.path.split(separator: "/").map(String.init)
            if let idx = parts.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "live" }),
               idx + 1 < parts.count {
                return validVideoID(parts[idx + 1])
            }
        }
        return nil
    }

    private static func validVideoID(_ value: String?) -> String? {
        guard let value, value.range(of: #"^[\w-]{6,}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    static func htmlTitle(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let titleRange = Range(match.range(at: 1), in: html)
        else { return nil }
        return decodeHTMLEntities(String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func metaContent(_ html: String, property: String? = nil, name: String? = nil) -> String? {
        let key: String
        let value: String
        if let property {
            key = "property"
            value = property
        } else if let name {
            key = "name"
            value = name
        } else {
            return nil
        }
        let pattern = #"<meta[^>]*\#(key)\s*=\s*[\"']\#(value)[\"'][^>]*content\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#
        let alt = #"<meta[^>]*content\s*=\s*[\"']([^\"']+)[\"'][^>]*\#(key)\s*=\s*[\"']\#(value)[\"'][^>]*>"#
        for pat in [pattern, alt] {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
               let r = Range(match.range(at: 1), in: html) {
                return decodeHTMLEntities(String(html[r]))
            }
        }
        return nil
    }

    static func htmlToText(_ html: String) -> String {
        var work = html
        // Drop scripts/styles/noscript
        let stripPatterns = [
            #"<script[^>]*>[\s\S]*?</script>"#,
            #"<style[^>]*>[\s\S]*?</style>"#,
            #"<noscript[^>]*>[\s\S]*?</noscript>"#,
            #"<svg[^>]*>[\s\S]*?</svg>"#,
            #"<!--[\s\S]*?-->"#,
        ]
        for pattern in stripPatterns {
            work = work.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Break blocks into newlines
        work = work.replacingOccurrences(of: #"</(p|div|br|li|h1|h2|h3|h4|tr|section|article)[^>]*>"#, with: "\n", options: .regularExpression)
        work = work.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        work = decodeHTMLEntities(work)
        // Collapse whitespace
        let lines = work
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 2 }
        var seen = Set<String>()
        var unique: [String] = []
        for line in lines {
            let key = line.lowercased()
            if seen.insert(key).inserted {
                unique.append(line)
            }
        }
        return unique.joined(separator: "\n")
    }

    static func extractTimedTextLangs(_ xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"lang_code=\"([^\"]+)\""#, options: []) else {
            return []
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[r])
        }
    }

    static func extractTimedTextBody(_ xml: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<text[^>]*>([\s\S]*?)</text>"#, options: []) else {
            return ""
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let parts: [String] = regex.matches(in: xml, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: xml) else { return nil }
            return decodeHTMLEntities(String(xml[r]))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }

        // Dedup consecutive captions
        var out: [String] = []
        for part in parts {
            if out.last != part { out.append(part) }
        }
        return out.joined(separator: " ")
    }

    static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&#x27;", "'"),
            ("&#10;", "\n"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: result),
                      let numRange = Range(match.range(at: 1), in: result),
                      let value = Int(result[numRange]),
                      let scalar = UnicodeScalar(value)
                else { continue }
                result.replaceSubrange(full, with: String(Character(scalar)))
            }
        }
        return result
    }
}
