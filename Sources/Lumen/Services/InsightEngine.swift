import Foundation

/// Local-first insight generation: learning summaries, ideas, action items.
enum InsightEngine {
    private static let actionPatterns: [NSRegularExpression] = {
        let raw = [
            #"(?i)\b(todo|to-do)\b[:\s-]*(.+)"#,
            #"(?i)\b(action item|next step)s?\b[:\s-]*(.+)"#,
            #"(?i)\b(need to|needs to|have to|must|should)\b\s+(.+)"#,
            #"(?i)\b(remember to|don't forget to|make sure to)\b\s+(.+)"#,
            #"(?i)\b(implement|build|fix|ship|write|refactor|investigate|research)\b\s+(.+)"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let ideaPatterns: [NSRegularExpression] = {
        let raw = [
            #"(?i)\b(idea|insight|hypothesis)\b[:\s-]*(.+)"#,
            #"(?i)\b(what if|maybe we|could we|it would be cool if)\b\s+(.+)"#,
            #"(?i)\b(inspired by|takeaway|lesson)\b[:\s-]*(.+)"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func analyze(
        dayStart: Date,
        segments: [ActivitySegment],
        contentBySegment: [UUID: ContentArtifact]
    ) -> (report: IntelligenceReport, insights: [InsightRecord]) {
        let active = segments.filter { !$0.isIdle }

        let interests = InterestDetector.detect(segments: active, contentBySegment: contentBySegment)
        let learningSegments = active.filter {
            $0.sessionKind == .learning || $0.sessionKind == .research || $0.category == .learning
        }

        let learningSummary = buildLearningSummary(learningSegments: learningSegments, contentBySegment: contentBySegment, interests: interests)
        let extracted = extractIdeasAndActions(segments: active, contentBySegment: contentBySegment, dayStart: dayStart)

        var kindCounts: [SessionKind: Int] = [:]
        for segment in active {
            kindCounts[segment.sessionKind, default: 0] += 1
        }

        let transcriptCount = contentBySegment.values.filter { $0.kind == .transcript && $0.status == .ready }.count
        let captured = contentBySegment.values.filter { $0.status == .ready }.count

        var insights: [InsightRecord] = []

        if !learningSummary.isEmpty {
            insights.append(
                InsightRecord(
                    dayStart: dayStart,
                    kind: .learningSummary,
                    title: "Learning summary",
                    body: learningSummary,
                    confidence: learningSegments.isEmpty ? 0.3 : 0.75,
                    topics: Array(interests.prefix(5).map(\.topic)),
                    sourceSegmentIDs: learningSegments.map(\.id)
                )
            )
        }

        for interest in interests.prefix(8) {
            insights.append(
                InsightRecord(
                    dayStart: dayStart,
                    kind: .interest,
                    title: interest.topic,
                    body: interestBlurb(interest),
                    confidence: min(0.95, 0.35 + interest.score / 5000),
                    topics: [interest.topic],
                    sourceSegmentIDs: []
                )
            )
        }

        insights.append(contentsOf: extracted.ideas)
        insights.append(contentsOf: extracted.actions)

        let report = IntelligenceReport(
            dayStart: dayStart,
            interests: interests,
            learningSummary: learningSummary,
            ideas: extracted.ideas,
            actionItems: extracted.actions,
            classifiedCounts: kindCounts,
            capturedContentCount: captured,
            transcriptCount: transcriptCount
        )

        return (report, insights)
    }

    // MARK: - Learning summary

    private static func buildLearningSummary(
        learningSegments: [ActivitySegment],
        contentBySegment: [UUID: ContentArtifact],
        interests: [InterestSignal]
    ) -> String {
        guard !learningSegments.isEmpty else {
            return "No clear learning sessions yet today. Visit docs, courses, or educational videos and Lumen will summarize them here."
        }

        let total = learningSegments.reduce(0.0) { $0 + $1.duration }
        var lines: [String] = []
        lines.append(
            "You spent \(DurationFormat.compact(total)) on learning/research across \(learningSegments.count) session\(learningSegments.count == 1 ? "" : "s")."
        )

        let topTopics = interests.prefix(5).map(\.topic)
        if !topTopics.isEmpty {
            lines.append("Recurring themes: " + topTopics.joined(separator: ", ") + ".")
        }

        // Highlight notable sessions
        let notable = learningSegments.sorted { $0.duration > $1.duration }.prefix(5)
        if !notable.isEmpty {
            lines.append("")
            lines.append("Highlights:")
            for segment in notable {
                let label = segment.windowTitle.isEmpty ? (segment.domain ?? segment.appName) : segment.windowTitle
                var line = "- \(DurationFormat.compact(segment.duration)) — \(label)"
                if let summary = segment.contentSummary, !summary.isEmpty {
                    line += " — \(summary)"
                } else if let content = contentBySegment[segment.id], !content.text.isEmpty {
                    let snip = summarizeText(content.text, maxSentences: 1)
                    if !snip.isEmpty { line += " — \(snip)" }
                }
                lines.append(line)
            }
        }

        // Pull takeaways from content
        let takeaways = learningSegments.compactMap { segment -> String? in
            guard let content = contentBySegment[segment.id], content.status == .ready else { return nil }
            let s = summarizeText(content.text, maxSentences: 2)
            return s.isEmpty ? nil : s
        }
        .prefix(4)

        if !takeaways.isEmpty {
            lines.append("")
            lines.append("Takeaways:")
            for t in takeaways {
                lines.append("- \(t)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func interestBlurb(_ interest: InterestSignal) -> String {
        var parts: [String] = []
        parts.append("Seen \(interest.occurrences)× · \(DurationFormat.compact(interest.duration)) weighted time.")
        if !interest.domains.isEmpty {
            parts.append("Domains: " + interest.domains.prefix(4).joined(separator: ", ") + ".")
        }
        if let title = interest.sampleTitles.first {
            parts.append("e.g. “\(title)”")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Ideas & actions

    private static func extractIdeasAndActions(
        segments: [ActivitySegment],
        contentBySegment: [UUID: ContentArtifact],
        dayStart: Date
    ) -> (ideas: [InsightRecord], actions: [InsightRecord]) {
        var ideas: [InsightRecord] = []
        var actions: [InsightRecord] = []
        var seenAction = Set<String>()
        var seenIdea = Set<String>()

        for segment in segments {
            let sources: [(
                text: String,
                actionPatterns: [NSRegularExpression],
                ideaPatterns: [NSRegularExpression]
            )] = {
                var values: [(String, [NSRegularExpression], [NSRegularExpression])] = []
                if !segment.notes.isEmpty {
                    values.append((segment.notes, actionPatterns, ideaPatterns))
                }
                if let content = contentBySegment[segment.id], content.status == .ready {
                    // Web content feeds summaries and interests. It is too noisy for tasks:
                    // headings such as “must watch” or “build faster” are not user intent.
                    values.append((String(content.text.prefix(4000)), [], []))
                }
                return values
            }()

            for source in sources {
                for line in source.text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= 8, trimmed.count <= 280 else { continue }

                    if let action = matchFirst(trimmed, patterns: source.actionPatterns) {
                        let key = action.lowercased()
                        if seenAction.insert(key).inserted {
                            actions.append(
                                InsightRecord(
                                    dayStart: dayStart,
                                    kind: .actionItem,
                                    title: cleanupCapture(action),
                                    body: "From \(segment.displayTitle)",
                                    confidence: 0.7,
                                    topics: segment.topics,
                                    sourceSegmentIDs: [segment.id]
                                )
                            )
                        }
                    } else if let idea = matchFirst(trimmed, patterns: source.ideaPatterns) {
                        let key = idea.lowercased()
                        if seenIdea.insert(key).inserted {
                            ideas.append(
                                InsightRecord(
                                    dayStart: dayStart,
                                    kind: .idea,
                                    title: cleanupCapture(idea),
                                    body: "From \(segment.displayTitle)",
                                    confidence: 0.65,
                                    topics: segment.topics,
                                    sourceSegmentIDs: [segment.id]
                                )
                            )
                        }
                    }
                }
            }

            // Title-based soft ideas for long learning sessions.
            if segment.sessionKind == .learning || segment.sessionKind == .research,
               segment.duration >= 8 * 60,
               !segment.windowTitle.isEmpty {
                let title = segment.windowTitle
                let key = "learn:\(title.lowercased())"
                if seenIdea.insert(key).inserted {
                    ideas.append(
                        InsightRecord(
                            dayStart: dayStart,
                            kind: .idea,
                            title: "Explore further: \(title)",
                            body: "You spent \(DurationFormat.compact(segment.duration)) here — consider turning it into a note or prototype.",
                            confidence: 0.45,
                            topics: segment.topics,
                            sourceSegmentIDs: [segment.id]
                        )
                    )
                }
            }
        }

        // Cap noise
        return (Array(ideas.prefix(20)), Array(actions.prefix(20)))
    }

    private static func matchFirst(_ line: String, patterns: [NSRegularExpression]) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for regex in patterns {
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            // Prefer last capture group content.
            let last = match.numberOfRanges - 1
            if last >= 1, let r = Range(match.range(at: last), in: line) {
                let value = String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count >= 4 { return value }
            }
            if let r = Range(match.range, in: line) {
                return String(line[r])
            }
        }
        return nil
    }

    private static func cleanupCapture(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix(";") {
            t = String(t.dropLast())
        }
        if let first = t.first {
            t = String(first).uppercased() + t.dropFirst()
        }
        return t
    }

    /// Naive extractive summary: first few sentence-like chunks.
    static func summarizeText(_ text: String, maxSentences: Int = 3) -> String {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        let parts = normalized
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 40 && $0.count <= 280 }

        let chosen = Array(parts.prefix(maxSentences))
        if chosen.isEmpty {
            return String(normalized.prefix(220))
        }
        return chosen.joined(separator: ". ") + "."
    }
}
