import Foundation

// MARK: - Goals

enum GoalMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepWorkMinutes
    case creationMinutes
    case learningMinutes
    case focusScore
    case maxDistractionMinutes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepWorkMinutes: "Deep work"
        case .creationMinutes: "Creation"
        case .learningMinutes: "Learning"
        case .focusScore: "Focus score"
        case .maxDistractionMinutes: "Max distraction"
        }
    }

    var symbolName: String {
        switch self {
        case .deepWorkMinutes: "brain.head.profile"
        case .creationMinutes: "hammer.fill"
        case .learningMinutes: "graduationcap.fill"
        case .focusScore: "target"
        case .maxDistractionMinutes: "flame"
        }
    }

    var unitLabel: String {
        switch self {
        case .focusScore: "pts"
        default: "min"
        }
    }
}

struct CreationGoal: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var metric: GoalMetric
    var targetValue: Double
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        metric: GoalMetric,
        targetValue: Double,
        isEnabled: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.metric = metric
        self.targetValue = targetValue
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

struct GoalProgress: Identifiable, Sendable {
    var id: UUID { goal.id }
    var goal: CreationGoal
    var currentValue: Double
    var unitLabel: String

    var ratio: Double {
        guard goal.targetValue > 0 else { return 0 }
        if goal.metric == .maxDistractionMinutes {
            // Under target is good.
            return min(1, currentValue / goal.targetValue)
        }
        return min(1.5, currentValue / goal.targetValue)
    }

    var isMet: Bool {
        switch goal.metric {
        case .maxDistractionMinutes:
            return currentValue <= goal.targetValue
        default:
            return currentValue >= goal.targetValue
        }
    }

    var statusLabel: String {
        if !goal.isEnabled { return "Disabled" }
        if goal.metric == .maxDistractionMinutes {
            return isMet ? "On track" : "Over limit"
        }
        return isMet ? "Done" : "In progress"
    }
}

// MARK: - Projects

struct ProjectDefinition: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var keywords: [String]
    var colorHex: String
    var isArchived: Bool
    var createdAt: Date
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        keywords: [String] = [],
        colorHex: String = "#5B8DEF",
        isArchived: Bool = false,
        createdAt: Date = .now,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.colorHex = colorHex
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.notes = notes
    }
}

struct ProjectScore: Identifiable, Sendable {
    var id: UUID { project.id }
    var project: ProjectDefinition
    var score: Double
    var activeDuration: TimeInterval
    var deepWorkDuration: TimeInterval
    var learningDuration: TimeInterval
    var distractionDuration: TimeInterval
    var sessionCount: Int
    var relatedTopics: [String]
    var momentum: Double
    var rationale: String
    var isInferred: Bool = false
}

// MARK: - Focus sessions

enum FocusSessionStatus: String, Codable, Sendable {
    case active
    case completed
    case endedEarly
}

struct FocusSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var startAt: Date
    var endAt: Date?
    var plannedDuration: TimeInterval
    var status: FocusSessionStatus

    init(
        id: UUID = UUID(),
        title: String = "Focus session",
        startAt: Date = .now,
        endAt: Date? = nil,
        plannedDuration: TimeInterval = 25 * 60,
        status: FocusSessionStatus = .active
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.plannedDuration = plannedDuration
        self.status = status
    }

    var scheduledEndAt: Date {
        startAt.addingTimeInterval(plannedDuration)
    }

    func duration(at date: Date = .now) -> TimeInterval {
        max(0, min(endAt ?? date, scheduledEndAt).timeIntervalSince(startAt))
    }
}

// MARK: - Warnings

enum WarningSeverity: String, Codable, Sendable {
    case info
    case caution
    case critical
}

struct BehaviourWarning: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var createdAt: Date
    var severity: WarningSeverity
    var title: String
    var message: String
    var domain: String?
    var appName: String?
    var segmentID: UUID?
    var dismissed: Bool
    var snoozedUntil: Date?
    var expiresAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        severity: WarningSeverity,
        title: String,
        message: String,
        domain: String? = nil,
        appName: String? = nil,
        segmentID: UUID? = nil,
        dismissed: Bool = false,
        snoozedUntil: Date? = nil,
        expiresAt: Date? = Date.now.addingTimeInterval(30 * 60)
    ) {
        self.id = id
        self.createdAt = createdAt
        self.severity = severity
        self.title = title
        self.message = message
        self.domain = domain
        self.appName = appName
        self.segmentID = segmentID
        self.dismissed = dismissed
        self.snoozedUntil = snoozedUntil
        self.expiresAt = expiresAt
    }

    var isActive: Bool {
        if dismissed { return false }
        if (expiresAt ?? createdAt.addingTimeInterval(30 * 60)) <= .now { return false }
        if let snoozedUntil, snoozedUntil > .now { return false }
        return true
    }
}

// MARK: - Weekly patterns

struct HourBucket: Identifiable, Sendable {
    var id: Int { hour }
    var hour: Int
    var activeDuration: TimeInterval
    var deepWorkDuration: TimeInterval
    var distractionDuration: TimeInterval
}

struct WeekdayBucket: Identifiable, Sendable {
    var id: Int { weekday }
    var weekday: Int
    var label: String
    var activeDuration: TimeInterval
    var focusScore: Double
    var deepWorkDuration: TimeInterval
    var distractionDuration: TimeInterval
}

struct WeeklyPatternReport: Sendable {
    var generatedAt: Date
    var rangeStart: Date
    var rangeEnd: Date
    var totalActive: TimeInterval
    var totalDeepWork: TimeInterval
    var totalDistraction: TimeInterval
    var averageFocusScore: Double
    var bestFocusHour: Int?
    var worstDistractionHour: Int?
    var bestWeekday: String?
    var hourBuckets: [HourBucket]
    var weekdayBuckets: [WeekdayBucket]
    var topInterests: [InterestSignal]
    var narrative: String
}

// MARK: - Next build

struct BuildRecommendation: Identifiable, Sendable {
    var id: UUID
    var title: String
    var summary: String
    var score: Double
    var reasons: [String]
    var relatedProjectName: String?
    var relatedTopics: [String]
    var suggestedFirstStep: String
    var sourceActionIDs: [UUID]
    var sourceIdeaIDs: [UUID]

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        score: Double,
        reasons: [String],
        relatedProjectName: String? = nil,
        relatedTopics: [String] = [],
        suggestedFirstStep: String,
        sourceActionIDs: [UUID] = [],
        sourceIdeaIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.score = score
        self.reasons = reasons
        self.relatedProjectName = relatedProjectName
        self.relatedTopics = relatedTopics
        self.suggestedFirstStep = suggestedFirstStep
        self.sourceActionIDs = sourceActionIDs
        self.sourceIdeaIDs = sourceIdeaIDs
    }
}

struct BehaviourSnapshot: Sendable {
    var generatedAt: Date
    var goalProgress: [GoalProgress]
    var projectScores: [ProjectScore]
    var weekly: WeeklyPatternReport?
    var recommendations: [BuildRecommendation]
    var activeWarning: BehaviourWarning?
    var todayDistractionMinutes: Double
    var todayDeepWorkMinutes: Double
    var todayCreationMinutes: Double
    var focusStreakDays: Int
}
