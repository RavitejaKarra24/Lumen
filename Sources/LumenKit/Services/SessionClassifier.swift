import Foundation

enum SessionClassifier {
    private static let distractionDomains: Set<String> = [
        "twitter.com", "x.com", "reddit.com", "instagram.com", "tiktok.com",
        "facebook.com", "netflix.com", "twitch.tv", "9gag.com", "news.ycombinator.com",
    ]

    private static let learningDomains: Set<String> = [
        "youtube.com", "youtu.be", "coursera.org", "udemy.com", "edx.org",
        "khanacademy.org", "developer.apple.com", "docs.python.org", "swift.org",
        "stackoverflow.com", "developer.mozilla.org", "medium.com", "dev.to",
        "css-tricks.com", "arxiv.org", "leetcode.com", "wikipedia.org", "raywenderlich.com",
        "hackingwithswift.com", "objc.io", "github.com",
    ]

    private static let researchDomains: Set<String> = [
        "google.com", "bing.com", "duckduckgo.com", "perplexity.ai", "chat.openai.com",
        "claude.ai", "gemini.google.com", "kagi.com", "scholar.google.com",
    ]

    private static let meetingKeywords = [
        "zoom", "meet.google", "teams", "webex", "standup", "standups", "stand-up", "stand-ups", "1:1",
        "sync", "syncs", "interview", "interviews", "call with", "meeting", "meetings",
    ]

    private static let creationKeywords = [
        "figma", "sketch", "photoshop", "illustrator", "keynote", "pages", "draft",
        "write", "design", "prototype", "canvas",
    ]

    private static let deepWorkKeywords = [
        "xcode", "vscode", "cursor", "terminal", "iterm", "pull request", "commit",
        "refactor", "debug", "build", "test", "swift", "typescript", "python",
    ]

    /// - Parameter extractTopics: topic extraction runs an `NLTagger` pass, which is
    ///   too slow for the recorder's polling loop. The recorder passes `false` and
    ///   the intelligence cycle fills topics in later, off the hot path.
    static func classify(
        _ segment: ActivitySegment,
        contentText: String? = nil,
        extractTopics: Bool = true
    ) -> (kind: SessionKind, topics: [String], category: ActivityCategory) {
        if segment.isIdle {
            return (.idle, [], segment.category)
        }

        let title = segment.windowTitle.lowercased()
        let app = segment.appName.lowercased()
        let bundle = segment.bundleIdentifier.lowercased()
        let domain = (segment.domain ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let url = (segment.urlString ?? "").lowercased()
        let learningSite = learningDomains.contains { domain == $0 || domain.hasSuffix(".\($0)") }
        let meetingSite = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]
            .contains { domain == $0 || domain.hasSuffix(".\($0)") }
        let blob = [title, app, domain, url, contentText?.lowercased() ?? ""].joined(separator: " ")

        var kind: SessionKind = .unknown
        // Stored category is a derived result, not a user override. Recompute
        // from app/domain evidence before applying the latest text heuristics.
        var category = CategoryClassifier.classify(
            bundleIdentifier: segment.bundleIdentifier,
            appName: segment.appName,
            domain: segment.domain
        )

        // A transcript discussing meetings is not evidence of attending one.
        // Known learning sites and coding/design tools also outrank generic
        // title words; real conferencing apps/sites remain explicit evidence.
        let titleSuggestsMeeting = !learningSite && !isYouTube(domain: domain, url: url)
            && category != .coding && category != .design
            && meetingKeywords.contains(where: { containsPhrase(title, $0) })
        if titleSuggestsMeeting || meetingSite
            || bundle.contains("zoom")
            || bundle.contains("teams")
            || bundle.contains("webex") {
            kind = .meeting
            category = .communication
        } else if distractionDomains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") }) {
            // HN is borderline research; keep as distraction if short / social.
            if domain.contains("ycombinator") && segment.duration >= 10 * 60 {
                kind = .research
                category = .learning
            } else {
                kind = .distraction
                category = .entertainment
            }
        } else if isYouTube(domain: domain, url: url) {
            // Decide YouTube from its own evidence (title + captured content),
            // never from a previously derived entertainment category — content
            // that arrives later must be able to reclassify the session.
            if looksEducational(title: title, content: contentText) {
                kind = .learning
                category = .learning
            } else {
                kind = .distraction
                category = .entertainment
            }
        } else if category == .entertainment {
            kind = .distraction
            category = .entertainment
        } else if category == .coding || deepWorkKeywords.contains(where: { containsPhrase(blob, $0) }) {
            kind = segment.duration >= 5 * 60 ? .deepWork : .creation
            category = .coding
        } else if category == .design || creationKeywords.contains(where: { containsPhrase(blob, $0) }) {
            kind = .creation
            category = category == .other ? .design : category
        } else if learningDomains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") })
            || category == .learning {
            kind = domain.contains("github") && (title.contains("pull") || blob.contains("issue"))
                ? .deepWork
                : .learning
            if kind == .learning { category = .learning }
            if kind == .deepWork { category = .coding }
        } else if researchDomains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") })
            || title.contains("search") {
            kind = .research
            category = .browsing
        } else if category == .communication {
            kind = .communication
        } else if category == .productivity || category == .system {
            kind = .admin
        } else if category == .browsing {
            kind = .research
        } else if category == .media {
            kind = looksEducational(title: title, content: contentText) ? .learning : .distraction
        } else {
            kind = .unknown
        }

        // Duration polish: long coding blocks are deep work.
        if category == .coding, segment.duration >= 15 * 60 {
            kind = .deepWork
        }

        guard extractTopics else {
            return (kind, segment.topics, category)
        }

        let topicSources = [segment.windowTitle, segment.notes, segment.domain ?? "", contentText ?? ""]
            + segment.tags
        let topics = TopicExtractor.extract(from: topicSources, limit: 6)

        return (kind, topics, category)
    }

    /// Matches a keyword on token boundaries: anchored with `\b` wherever the
    /// phrase begins or ends with a word character. Substring matching made
    /// "sync" match `async.swift` and "test" match "latest".
    private static func containsPhrase(_ blob: String, _ phrase: String) -> Bool {
        var pattern = ""
        if phrase.first?.isLetter == true || phrase.first?.isNumber == true {
            pattern += "\\b"
        }
        pattern += NSRegularExpression.escapedPattern(for: phrase)
        if phrase.last?.isLetter == true || phrase.last?.isNumber == true {
            pattern += "\\b"
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return blob.contains(phrase)
        }
        let range = NSRange(blob.startIndex..<blob.endIndex, in: blob)
        return regex.firstMatch(in: blob, options: [], range: range) != nil
    }

    private static func isYouTube(domain: String, url: String) -> Bool {
        let host = domain.isEmpty ? (URL(string: url)?.host?.lowercased() ?? "") : domain
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtu.be" || host.hasSuffix(".youtu.be")
    }

    private static func looksEducational(title: String, content: String?) -> Bool {
        // Keep common inflections explicit: token boundaries should reject
        // accidental substrings, not turn "Guitar tutorials" into distraction.
        let edu = [
            "tutorial", "tutorials", "course", "courses", "lesson", "lessons",
            "learn", "learning", "how to", "introduction", "introductions", "guide", "guides",
            "explained", "crash course", "lecture", "lectures", "documentary", "documentaries", "interview with",
            "swift", "swiftui", "python", "rust", "kubernetes", "algorithm", "algorithms", "architecture",
            "wwdc", "keynote", "keynotes", "deep dive", "handbook", "recipe for", "recipes for",
        ]
        let blob = (title + " " + (content ?? "")).lowercased()
        return edu.contains(where: { containsPhrase(blob, $0) })
    }
}
