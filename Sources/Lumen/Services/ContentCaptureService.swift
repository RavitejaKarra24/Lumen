import Foundation

/// Fetches page text and YouTube transcripts for browser sessions.
actor ContentCaptureService {
    static let shared = ContentCaptureService()

    private let session: URLSession
    private let maxTextCharacters = 20_000

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 Lumen/0.2",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        session = URLSession(configuration: config)
    }

    func capture(for segment: ActivitySegment) async -> ContentArtifact {
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
        do {
            let (data, response) = try await session.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<400).contains(statusCode) else {
                return failure(segment: segment, url: url.absoluteString, kind: .page, message: "HTTP \(statusCode)")
            }
            guard let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            else {
                return failure(segment: segment, url: url.absoluteString, kind: .page, message: "Unreadable encoding")
            }

            let title = Self.htmlTitle(html) ?? segment.windowTitle
            let text = Self.htmlToText(html)
            let clipped = String(text.prefix(maxTextCharacters))
            return ContentArtifact(
                segmentID: segment.id,
                urlString: url.absoluteString,
                kind: .page,
                title: title,
                text: clipped,
                status: clipped.isEmpty ? .failed : .ready,
                errorMessage: clipped.isEmpty ? "Empty body" : nil,
                source: "url-session"
            )
        } catch {
            return failure(segment: segment, url: url.absoluteString, kind: .page, message: error.localizedDescription)
        }
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
        do {
            let (data, _) = try await session.data(from: pageURL)
            if let html = String(data: data, encoding: .utf8) {
                let title = Self.htmlTitle(html) ?? segment.windowTitle
                let desc = Self.metaContent(html, property: "og:description")
                    ?? Self.metaContent(html, name: "description")
                    ?? ""
                let text = [title, desc].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
            let (data, _) = try await session.data(from: listURL)
            guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else { return nil }

            // Prefer en, then first track.
            let langs = Self.extractTimedTextLangs(xml)
            let lang = langs.first(where: { $0.hasPrefix("en") }) ?? langs.first
            guard let lang else { return nil }

            guard let trackURL = URL(string: "https://www.youtube.com/api/timedtext?v=\(videoID)&lang=\(lang)") else {
                return nil
            }
            let (trackData, _) = try await session.data(from: trackURL)
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
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtu.be") {
            let id = url.path.split(separator: "/").first.map(String.init)
            return validVideoID(id)
        }
        if host.contains("youtube.com") {
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
