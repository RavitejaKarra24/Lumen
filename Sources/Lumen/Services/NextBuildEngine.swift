import Foundation

/// Picks the most valuable thing to build next from interests, projects, ideas, and open actions.
enum NextBuildEngine {
    static func recommend(
        projectScores: [ProjectScore],
        interests: [InterestSignal],
        ideas: [InsightRecord],
        actions: [InsightRecord],
        weekly: WeeklyPatternReport?,
        limit: Int = 5
    ) -> [BuildRecommendation] {
        var candidates: [BuildRecommendation] = []

        // 1) Open action items — high priority if recent/high confidence.
        for action in actions where !action.isCompleted {
            let topicBoost = interestOverlap(action.topics, interests: interests) * 12
            let pinBoost = action.isPinned ? 15.0 : 0
            let score = 55 + action.confidence * 25 + topicBoost + pinBoost
            candidates.append(
                BuildRecommendation(
                    title: action.title,
                    summary: action.body.isEmpty ? "Open action item from your sessions." : action.body,
                    score: score,
                    reasons: reasonList([
                        "Open action item",
                        action.isPinned ? "Pinned" : nil,
                        topicBoost > 0 ? "Matches a repeated interest" : nil,
                    ]),
                    relatedProjectName: matchingProject(action.topics, in: projectScores)?.project.name,
                    relatedTopics: action.topics,
                    suggestedFirstStep: "Block 25 minutes and finish: \(action.title)",
                    sourceActionIDs: [action.id]
                )
            )
        }

        // 2) Ideas with interest/project support.
        for idea in ideas where !idea.isCompleted {
            let overlap = interestOverlap(idea.topics + [idea.title], interests: interests)
            let project = matchingProject(idea.topics + [idea.title], in: projectScores)
            let projectBoost = (project?.score ?? 0) * 0.25
            let score = 40 + idea.confidence * 20 + overlap * 18 + projectBoost + (idea.isPinned ? 10 : 0)
            candidates.append(
                BuildRecommendation(
                    title: idea.title,
                    summary: idea.body.isEmpty ? "Idea captured from your work." : idea.body,
                    score: score,
                    reasons: reasonList([
                        "Captured idea",
                        overlap > 0.4 ? "Aligned with repeated interests" : nil,
                        project != nil ? "Linked to project \(project!.project.name)" : nil,
                    ]),
                    relatedProjectName: project?.project.name,
                    relatedTopics: idea.topics,
                    suggestedFirstStep: "Spike a tiny prototype or write a one-pager for: \(idea.title)",
                    sourceIdeaIDs: [idea.id]
                )
            )
        }

        // 3) Top projects that need momentum or have high score.
        for project in projectScores.prefix(6) {
            let interestHit = interestOverlap(project.relatedTopics + [project.project.name], interests: interests)
            let needsRestart = project.momentum < 0.35 && project.activeDuration > 0
            let hot = project.score >= 55
            guard needsRestart || hot || interestHit > 0.3 else { continue }

            let title: String
            if needsRestart {
                title = "Restart \(project.project.name)"
            } else {
                title = "Advance \(project.project.name)"
            }

            let score = project.score * 0.7 + interestHit * 20 + (needsRestart ? 12 : 0) + project.momentum * 15
            candidates.append(
                BuildRecommendation(
                    title: title,
                    summary: project.rationale,
                    score: score,
                    reasons: reasonList([
                        String(format: "Project score %.0f/100", project.score),
                        needsRestart ? "Momentum cooling — restart now" : "Healthy momentum",
                        interestHit > 0.3 ? "Interest overlap" : nil,
                        project.deepWorkDuration > 30 * 60 ? "Already has deep-work history" : nil,
                    ]),
                    relatedProjectName: project.project.name,
                    relatedTopics: project.relatedTopics,
                    suggestedFirstStep: needsRestart
                        ? "Schedule a 45m deep-work block on \(project.project.name) today."
                        : "Ship one visible slice of \(project.project.name) this week."
                )
            )
        }

        // 4) Pure interest → product opportunity when no project exists.
        for interest in interests.prefix(5) {
            let alreadyCovered = projectScores.contains {
                $0.project.name.localizedCaseInsensitiveContains(interest.topic)
                    || $0.relatedTopics.contains(where: { $0.caseInsensitiveCompare(interest.topic) == .orderedSame })
            }
            if alreadyCovered { continue }
            let score = min(70, 25 + interest.score / 80 + Double(interest.occurrences) * 3)
            candidates.append(
                BuildRecommendation(
                    title: "Explore a build around “\(interest.topic)”",
                    summary: "You’ve returned to this topic repeatedly (\(interest.occurrences)×, \(DurationFormat.compact(interest.duration)) weighted).",
                    score: score,
                    reasons: [
                        "Repeated interest without a named project",
                        "\(interest.occurrences) occurrences this period",
                    ],
                    relatedTopics: [interest.topic],
                    suggestedFirstStep: "Create a project named \(interest.topic.capitalized) and define a one-week MVP."
                )
            )
        }

        // 5) Weekly pattern nudge — protect best focus hour with a build block.
        if let weekly, let hour = weekly.bestFocusHour {
            let topProject = projectScores.first
            let title = topProject.map { "Use your \(formatHour(hour)) focus peak on \($0.project.name)" }
                ?? "Protect a build block at \(formatHour(hour))"
            candidates.append(
                BuildRecommendation(
                    title: title,
                    summary: weekly.narrative,
                    score: 48 + (topProject?.score ?? 20) * 0.2,
                    reasons: reasonList([
                        "Historical deep-work peak",
                        topProject.map { "Top project: \($0.project.name)" },
                    ]),
                    relatedProjectName: topProject?.project.name,
                    relatedTopics: topProject?.relatedTopics ?? [],
                    suggestedFirstStep: "Calendar a recurring \(formatHour(hour)) deep-work block."
                )
            )
        }

        // Dedup by normalized title, keep highest score.
        var bestByTitle: [String: BuildRecommendation] = [:]
        for candidate in candidates {
            let key = candidate.title.lowercased()
            if let existing = bestByTitle[key] {
                if candidate.score > existing.score {
                    bestByTitle[key] = candidate
                }
            } else {
                bestByTitle[key] = candidate
            }
        }

        return bestByTitle.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private static func interestOverlap(_ topics: [String], interests: [InterestSignal]) -> Double {
        guard !topics.isEmpty, !interests.isEmpty else { return 0 }
        let interestTopics = interests.map { $0.topic.lowercased() }
        var hits = 0
        for topic in topics {
            let t = topic.lowercased()
            if interestTopics.contains(where: { $0.contains(t) || t.contains($0) }) {
                hits += 1
            }
        }
        return min(1, Double(hits) / Double(min(topics.count, 3)))
    }

    private static func matchingProject(_ topics: [String], in scores: [ProjectScore]) -> ProjectScore? {
        let lowered = topics.map { $0.lowercased() }
        return scores.first { score in
            let keys = ([score.project.name] + score.project.keywords + score.relatedTopics).map { $0.lowercased() }
            return keys.contains { key in
                lowered.contains { $0.contains(key) || key.contains($0) }
            }
        }
    }

    private static func reasonList(_ items: [String?]) -> [String] {
        items.compactMap { $0 }
    }

    private static func formatHour(_ hour: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        let date = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "ha"
        return f.string(from: date).lowercased()
    }
}
