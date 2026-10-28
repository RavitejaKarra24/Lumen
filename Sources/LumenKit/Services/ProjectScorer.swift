import Foundation

enum ProjectScorer {
    /// Score projects from recent segments + insights.
    static func score(
        projects: [ProjectDefinition],
        segments: [ActivitySegment],
        insights: [InsightRecord] = [],
        now: Date = .now
    ) -> [ProjectScore] {
        let activeProjects = projects.filter { !$0.isArchived }
        guard !activeProjects.isEmpty else {
            // Synthesize soft projects from top tags/topics if user has none.
            return synthesizeFromActivity(segments: segments, insights: insights)
        }

        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 86400)
        let recent = segments.filter { !$0.isIdle && $0.startAt >= weekAgo }

        return activeProjects.map { project in
            let matched = recent.filter { matches(project, segment: $0) }
            var active: TimeInterval = 0
            var deep: TimeInterval = 0
            var learn: TimeInterval = 0
            var distract: TimeInterval = 0
            var topics: [String: Int] = [:]

            for segment in matched {
                let d = segment.duration
                active += d
                switch segment.sessionKind {
                case .deepWork, .creation: deep += d
                case .learning, .research: learn += d
                case .distraction: distract += d
                default: break
                }
                for t in segment.topics { topics[t, default: 0] += 1 }
            }

            let relatedInsights = insights.filter { insight in
                let blob = (insight.title + " " + insight.body + " " + insight.topics.joined(separator: " ")).lowercased()
                let keys = ([project.name] + project.keywords).map { $0.lowercased() }
                return keys.contains { !$0.isEmpty && blob.contains($0) }
            }

            let deepRatio = active > 0 ? deep / active : 0
            let insightBoost = Double(relatedInsights.filter { !$0.isCompleted }.count) * 8
            let momentum = computeMomentum(matched: matched, now: now)

            // Score 0...100
            let timeScore = min(40, (active / 3600) * 12)
            let qualityScore = deepRatio * 30
            let learnScore = min(15, (learn / 3600) * 10)
            let distractPenalty = min(20, (distract / 3600) * 15)
            let score = max(0, min(100, timeScore + qualityScore + learnScore + insightBoost + momentum * 10 - distractPenalty))

            let topTopics = topics.sorted { $0.value > $1.value }.prefix(5).map(\.key)
            let rationale = buildRationale(
                active: active,
                deepRatio: deepRatio,
                momentum: momentum,
                openInsights: relatedInsights.filter { !$0.isCompleted }.count
            )

            return ProjectScore(
                project: project,
                score: score,
                activeDuration: active,
                deepWorkDuration: deep,
                learningDuration: learn,
                distractionDuration: distract,
                sessionCount: matched.count,
                relatedTopics: topTopics,
                momentum: momentum,
                rationale: rationale
            )
        }
        .sorted { $0.score > $1.score }
    }

    static func matches(_ project: ProjectDefinition, segment: ActivitySegment) -> Bool {
        let keys = ([project.name] + project.keywords)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !keys.isEmpty else { return false }

        let blob = [
            segment.appName,
            segment.windowTitle,
            segment.domain ?? "",
            segment.urlString ?? "",
            segment.notes,
            segment.tags.joined(separator: " "),
            segment.topics.joined(separator: " "),
        ]
        .joined(separator: " ")
        .lowercased()

        return keys.contains { blob.contains($0) }
    }

    private static func computeMomentum(matched: [ActivitySegment], now: Date) -> Double {
        // 0...1 based on recency of last work and consistency last 3 days.
        guard let last = matched.map(\.startAt).max() else { return 0 }
        let hoursSince = now.timeIntervalSince(last) / 3600
        let recency = max(0, 1 - hoursSince / 72)

        let cal = Calendar.current
        var daysWithWork = Set<Date>()
        for segment in matched {
            daysWithWork.insert(cal.startOfDay(for: segment.startAt))
        }
        let consistency = min(1, Double(daysWithWork.count) / 3.0)
        return (recency * 0.6) + (consistency * 0.4)
    }

    private static func buildRationale(active: TimeInterval, deepRatio: Double, momentum: Double, openInsights: Int) -> String {
        var parts: [String] = []
        if active < 10 * 60 {
            parts.append("Little recent time logged.")
        } else {
            parts.append("\(DurationFormat.compact(active)) in the last 7 days.")
        }
        if deepRatio >= 0.5 {
            parts.append("Strong deep-work ratio.")
        } else if deepRatio > 0 {
            parts.append("Some deep work, room to focus more.")
        }
        if momentum >= 0.6 {
            parts.append("Momentum is warm.")
        } else if momentum <= 0.25 {
            parts.append("Cooling off — needs a restart.")
        }
        if openInsights > 0 {
            parts.append("\(openInsights) open idea/action link\(openInsights == 1 ? "" : "s").")
        }
        return parts.joined(separator: " ")
    }

    private static func synthesizeFromActivity(segments: [ActivitySegment], insights: [InsightRecord]) -> [ProjectScore] {
        // Build pseudo-projects from top tags.
        var tagDurations: [String: TimeInterval] = [:]
        for segment in segments where !segment.isIdle {
            for tag in segment.tags {
                tagDurations[tag, default: 0] += segment.duration
            }
        }
        let top = tagDurations.sorted { $0.value > $1.value }.prefix(5)
        return top.enumerated().map { index, pair in
            let def = ProjectDefinition(name: pair.key, keywords: [pair.key], colorHex: "#8B5CF6")
            return ProjectScore(
                project: def,
                score: max(10, 70 - Double(index) * 8),
                activeDuration: pair.value,
                deepWorkDuration: pair.value * 0.4,
                learningDuration: 0,
                distractionDuration: 0,
                sessionCount: 0,
                relatedTopics: [pair.key],
                momentum: 0.4,
                rationale: "Inferred from tag “\(pair.key)”. Save it as a project to score this properly.",
                isInferred: true
            )
        }
    }
}
