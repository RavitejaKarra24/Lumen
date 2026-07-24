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
        "zoom", "meet.google", "teams", "webex", "standup", "stand-up", "1:1", "sync",
        "interview", "call with", "meeting",
    ]

    private static let creationKeywords = [
        "figma", "sketch", "photoshop", "illustrator", "keynote", "pages", "draft",
        "write", "design", "prototype", "canvas",
    ]

    private static let deepWorkKeywords = [
        "xcode", "vscode", "cursor", "terminal", "iterm", "pull request", "commit",
        "refactor", "debug", "build", "test", "swift", "typescript", "python",
    ]

    static func classify(_ segment: ActivitySegment, contentText: String? = nil) -> (kind: SessionKind, topics: [String], category: ActivityCategory) {
        if segment.isIdle {
            return (.idle, [], segment.category)
        }

        let title = segment.windowTitle.lowercased()
        let app = segment.appName.lowercased()
        let bundle = segment.bundleIdentifier.lowercased()
        let domain = (segment.domain ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let url = (segment.urlString ?? "").lowercased()
        let blob = [title, app, domain, url, contentText?.lowercased() ?? ""].joined(separator: " ")

        var kind: SessionKind = .unknown
        var category = segment.category

        // Meetings first (Zoom etc. even if title empty)
        if meetingKeywords.contains(where: { blob.contains($0) })
            || bundle.contains("zoom")
            || bundle.contains("teams")
            || bundle.contains("webex") {
            kind = .meeting
            category = .communication
        } else if distractionDomains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") })
            || category == .entertainment {
            // HN is borderline research; keep as distraction if short / social.
            if domain.contains("ycombinator") && segment.duration >= 10 * 60 {
                kind = .research
                category = .learning
            } else {
                kind = .distraction
                category = .entertainment
            }
        } else if category == .coding || deepWorkKeywords.contains(where: { blob.contains($0) }) {
            kind = segment.duration >= 5 * 60 ? .deepWork : .creation
            category = .coding
        } else if category == .design || creationKeywords.contains(where: { blob.contains($0) }) {
            kind = .creation
            category = category == .other ? .design : category
        } else if isYouTube(domain: domain, url: url) {
            // Educational vs entertainment YouTube via title heuristics.
            if looksEducational(title: title, content: contentText) {
                kind = .learning
                category = .learning
            } else {
                kind = .distraction
                category = .entertainment
            }
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

        let topicSources = [segment.windowTitle, segment.notes, segment.domain ?? "", contentText ?? ""]
            + segment.tags
        let topics = TopicExtractor.extract(from: topicSources, limit: 6)

        return (kind, topics, category)
    }

    private static func isYouTube(domain: String, url: String) -> Bool {
        domain.contains("youtube.com") || domain == "youtu.be" || url.contains("youtube.com/watch")
    }

    private static func looksEducational(title: String, content: String?) -> Bool {
        let edu = [
            "tutorial", "course", "lesson", "learn", "how to", "introduction", "guide",
            "explained", "crash course", "lecture", "documentary", "interview with",
            "swift", "python", "rust", "kubernetes", "algorithm", "architecture",
            "wwdc", "keynote", "deep dive", "handbook", "recipe for",
        ]
        let blob = (title + " " + (content ?? "")).lowercased()
        return edu.contains(where: { blob.contains($0) })
    }
}
