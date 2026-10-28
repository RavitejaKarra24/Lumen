import Foundation

enum ReportGenerator {
    static func markdown(for analytics: DayAnalytics) -> String {
        let day = analytics.dayStart
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none

        var lines: [String] = []
        lines.append("# Lumen Daily Report")
        lines.append("")
        lines.append("**\(formatter.string(from: day))**")
        lines.append("")
        lines.append("Generated \(ISO8601DateFormatter().string(from: .now))")
        lines.append("")

        lines.append("## Summary")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("| --- | --- |")
        lines.append("| Active time | \(DurationFormat.compact(analytics.activeDuration)) |")
        lines.append("| Idle time | \(DurationFormat.compact(analytics.idleDuration)) |")
        lines.append("| Focus score | \(String(format: "%.0f", analytics.focusScore))/100 |")
        lines.append("| Deep work (≥25m focus blocks) | \(DurationFormat.compact(analytics.deepWorkDuration)) |")
        lines.append("| Context switches | \(analytics.contextSwitches) |")
        lines.append("| Top app | \(analytics.topAppName) |")
        lines.append("| Top website | \(analytics.topDomain) |")
        lines.append("")

        if !analytics.deepWorkBlocks.isEmpty {
            let blockTimeFormatter = DateFormatter()
            blockTimeFormatter.dateFormat = "HH:mm"
            lines.append("## Deep work blocks")
            lines.append("")
            lines.append("| Window | Focused | Focus | Apps |")
            lines.append("| --- | --- | --- | --- |")
            for block in analytics.deepWorkBlocks {
                let window = "\(blockTimeFormatter.string(from: block.start))–\(blockTimeFormatter.string(from: block.end))"
                let source = block.isFocusSession ? "Focus session" : block.dominantCategory.displayName
                lines.append(
                    "| \(window) | \(DurationFormat.compact(block.focusedDuration)) | \(source) | \(block.appNames.joined(separator: ", ")) |"
                )
            }
            lines.append("")
        }

        lines.append("## Categories")
        lines.append("")
        if analytics.categoryUsages.isEmpty {
            lines.append("_No active categories recorded._")
        } else {
            lines.append("| Category | Time | Share |")
            lines.append("| --- | --- | --- |")
            for item in analytics.categoryUsages {
                let share = analytics.activeDuration > 0
                    ? (item.duration / analytics.activeDuration) * 100
                    : 0
                lines.append(
                    "| \(item.category.displayName) | \(DurationFormat.compact(item.duration)) | \(String(format: "%.0f%%", share)) |"
                )
            }
        }
        lines.append("")

        // Session kinds (Goalpost 2)
        var kindDurations: [SessionKind: TimeInterval] = [:]
        for segment in analytics.segments where !segment.isIdle {
            kindDurations[segment.sessionKind, default: 0] += AnalyticsService.clippedDuration(
                segment,
                dayStart: analytics.dayStart,
                dayEnd: analytics.dayEnd
            )
        }
        if !kindDurations.isEmpty {
            lines.append("## Session types")
            lines.append("")
            lines.append("| Type | Time |")
            lines.append("| --- | --- |")
            for (kind, duration) in kindDurations.sorted(by: { $0.value > $1.value }) {
                lines.append("| \(kind.displayName) | \(DurationFormat.compact(duration)) |")
            }
            lines.append("")
        }

        let topical = analytics.segments.flatMap(\.topics)
        if !topical.isEmpty {
            var counts: [String: Int] = [:]
            for t in topical { counts[t, default: 0] += 1 }
            let top = counts.sorted { $0.value > $1.value }.prefix(12)
            lines.append("## Topics")
            lines.append("")
            lines.append(top.map { "\($0.key) (\($0.value))" }.joined(separator: " · "))
            lines.append("")
        }

        lines.append("## Apps")
        lines.append("")
        if analytics.appUsages.isEmpty {
            lines.append("_No apps recorded._")
        } else {
            lines.append("| App | Category | Time |")
            lines.append("| --- | --- | --- |")
            for app in analytics.appUsages.prefix(20) {
                lines.append(
                    "| \(app.appName) | \(app.category.displayName) | \(DurationFormat.compact(app.duration)) |"
                )
            }
        }
        lines.append("")

        lines.append("## Websites")
        lines.append("")
        if analytics.domainUsages.isEmpty {
            lines.append("_No websites recorded (grant Accessibility to capture browser URLs)._")
        } else {
            lines.append("| Domain | Visits | Time |")
            lines.append("| --- | --- | --- |")
            for site in analytics.domainUsages.prefix(25) {
                lines.append(
                    "| \(site.domain) | \(site.visitCount) | \(DurationFormat.compact(site.duration)) |"
                )
            }
        }
        lines.append("")

        lines.append("## Timeline")
        lines.append("")
        let activeSegments = analytics.segments.filter { !$0.isIdle }
        if activeSegments.isEmpty {
            lines.append("_No timeline segments._")
        } else {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            for segment in activeSegments {
                let clippedStart = max(segment.startAt, analytics.dayStart)
                let clippedEnd = min(segment.endAt ?? .now, analytics.dayEnd)
                let clippedDuration = max(0, clippedEnd.timeIntervalSince(clippedStart))
                let start = timeFormatter.string(from: clippedStart)
                let end = timeFormatter.string(from: clippedEnd)
                let label: String
                if let domain = segment.domain, !domain.isEmpty {
                    label = "\(domain) · \(segment.appName)"
                } else if !segment.windowTitle.isEmpty {
                    label = "\(segment.windowTitle) · \(segment.appName)"
                } else {
                    label = segment.appName
                }
                let tags = segment.tags.isEmpty ? "" : " `" + segment.tags.joined(separator: "`, `") + "`"
                lines.append(
                    "- **\(start)–\(end)** (\(DurationFormat.compact(clippedDuration))) — \(label) · _\(segment.category.displayName)_\(tags)"
                )
            }
        }
        lines.append("")

        let tagged = analytics.segments.filter { !$0.tags.isEmpty || !$0.notes.isEmpty }
        if !tagged.isEmpty {
            lines.append("## Tagged sessions")
            lines.append("")
            for segment in tagged {
                let tagList = segment.tags.joined(separator: ", ")
                lines.append("### \(segment.displayTitle)")
                if !tagList.isEmpty {
                    lines.append("- Tags: \(tagList)")
                }
                if !segment.notes.isEmpty {
                    lines.append("- Notes: \(segment.notes)")
                }
                lines.append("")
            }
        }

        lines.append("---")
        lines.append("_Report generated by Lumen_")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func markdown(for analytics: DayAnalytics, behaviour: BehaviourSnapshot?) -> String {
        var base = markdown(for: analytics)
        guard let behaviour else { return base }

        var extra: [String] = []
        extra.append("## Behaviour")
        extra.append("")
        if let next = behaviour.recommendations.first {
            extra.append("**Build next:** \(next.title)")
            extra.append("")
            extra.append(next.summary)
            extra.append("")
            extra.append("_First step:_ \(next.suggestedFirstStep)")
            extra.append("")
        }
        if !behaviour.goalProgress.isEmpty {
            extra.append("### Goals")
            extra.append("")
            extra.append("| Goal | Progress | Status |")
            extra.append("| --- | --- | --- |")
            for item in behaviour.goalProgress {
                let progress = String(format: "%.0f / %.0f %@", item.currentValue, item.goal.targetValue, item.unitLabel)
                extra.append("| \(item.goal.title) | \(progress) | \(item.statusLabel) |")
            }
            extra.append("")
        }
        if !behaviour.projectScores.isEmpty {
            extra.append("### Projects")
            extra.append("")
            for project in behaviour.projectScores.prefix(8) {
                extra.append(
                    "- **\(project.project.name)** — score \(String(format: "%.0f", project.score))/100 · \(project.rationale)"
                )
            }
            extra.append("")
        }
        if let weekly = behaviour.weekly {
            extra.append("### Weekly patterns")
            extra.append("")
            extra.append(weekly.narrative)
            extra.append("")
        }

        // Insert behaviour section before final footer.
        if let range = base.range(of: "---\n_Report generated by Lumen_") {
            base.replaceSubrange(range, with: extra.joined(separator: "\n") + "\n---\n_Report generated by Lumen_")
        } else {
            base += "\n" + extra.joined(separator: "\n")
        }
        return base
    }

    /// One row per session, for spreadsheets and invoicing.
    static func csv(for analytics: DayAnalytics) -> String {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]

        var rows = [
            "start,end,duration_seconds,app,bundle_id,window_title,domain,url,category,session_kind,is_idle,tags,notes",
        ]
        for segment in analytics.segments {
            let start = max(segment.startAt, analytics.dayStart)
            let end = min(segment.endAt ?? .now, analytics.dayEnd)
            let duration = max(0, end.timeIntervalSince(start))
            let fields = [
                stamp.string(from: start),
                stamp.string(from: end),
                String(format: "%.0f", duration),
                segment.appName,
                segment.bundleIdentifier,
                segment.windowTitle,
                segment.domain ?? "",
                segment.urlString ?? "",
                segment.category.displayName,
                segment.sessionKind.displayName,
                segment.isIdle ? "true" : "false",
                segment.tags.joined(separator: "; "),
                segment.notes,
            ]
            rows.append(fields.map(escapeCSV).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func escapeCSV(_ value: String) -> String {
        // Strip newlines so every session stays on one row, then quote.
        let flattened = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(flattened.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func makeSnapshot(from analytics: DayAnalytics, behaviour: BehaviourSnapshot? = nil) -> DailySnapshot {
        DailySnapshot(
            dayStart: analytics.dayStart,
            generatedAt: .now,
            markdown: markdown(for: analytics, behaviour: behaviour),
            activeSeconds: analytics.activeDuration,
            idleSeconds: analytics.idleDuration,
            focusScore: analytics.focusScore,
            topAppName: analytics.topAppName,
            topDomain: analytics.topDomain
        )
    }
}
