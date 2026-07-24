import Foundation

enum InterestDetector {
    /// Score repeated interests across a window of segments (duration × frequency).
    static func detect(segments: [ActivitySegment], contentBySegment: [UUID: ContentArtifact] = [:], limit: Int = 12) -> [InterestSignal] {
        struct Acc {
            var duration: TimeInterval = 0
            var occurrences: Int = 0
            var domains: Set<String> = []
            var titles: [String] = []
        }

        var map: [String: Acc] = [:]

        for segment in segments where !segment.isIdle {
            let content = contentBySegment[segment.id]
            let sources = [segment.windowTitle, segment.domain ?? "", segment.notes, content?.title ?? "", String((content?.text ?? "").prefix(1500))]
                + segment.topics
                + segment.tags

            var topics = segment.topics
            if topics.isEmpty {
                topics = TopicExtractor.extract(from: sources, limit: 5)
            }

            // Always include cleaned domain as a weak interest.
            if let domain = segment.domain?.lowercased().replacingOccurrences(of: "www.", with: ""),
               !domain.isEmpty {
                topics.append(domain)
            }

            let uniqueTopics = Array(Set(topics.map { $0.lowercased() })).prefix(8)
            let share = max(segment.duration, 1) / Double(max(uniqueTopics.count, 1))

            for topic in uniqueTopics {
                var acc = map[topic] ?? Acc()
                acc.duration += share
                acc.occurrences += 1
                if let domain = segment.domain { acc.domains.insert(domain) }
                if !segment.windowTitle.isEmpty, acc.titles.count < 4 {
                    if !acc.titles.contains(segment.windowTitle) {
                        acc.titles.append(segment.windowTitle)
                    }
                }
                map[topic] = acc
            }
        }

        return map.map { topic, acc in
            // Score: time spent + repeat bonus.
            let score = acc.duration + Double(acc.occurrences) * 90
            return InterestSignal(
                topic: topic,
                score: score,
                duration: acc.duration,
                occurrences: acc.occurrences,
                domains: Array(acc.domains).sorted(),
                sampleTitles: acc.titles
            )
        }
        .filter { $0.occurrences >= 1 && $0.duration >= 20 }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }
}
