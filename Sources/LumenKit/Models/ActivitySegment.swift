import Foundation

struct ActivitySegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var startAt: Date
    var endAt: Date?
    var lastObservedAt: Date?
    var appName: String
    var bundleIdentifier: String
    var windowTitle: String
    var urlString: String?
    var domain: String?
    var isIdle: Bool
    var categoryRaw: String
    var notes: String
    var tags: [String]

    // Goalpost 2 enrichment
    var sessionKindRaw: String?
    var topics: [String]
    var contentStatusRaw: String?
    var contentSummary: String?

    init(
        id: UUID = UUID(),
        startAt: Date = .now,
        endAt: Date? = nil,
        lastObservedAt: Date? = nil,
        appName: String,
        bundleIdentifier: String,
        windowTitle: String = "",
        urlString: String? = nil,
        domain: String? = nil,
        isIdle: Bool = false,
        category: ActivityCategory = .other,
        notes: String = "",
        tags: [String] = [],
        sessionKind: SessionKind = .unknown,
        topics: [String] = [],
        contentStatus: ContentStatus = .none,
        contentSummary: String? = nil
    ) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.lastObservedAt = lastObservedAt ?? startAt
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.urlString = urlString
        self.domain = domain
        self.isIdle = isIdle
        self.categoryRaw = category.rawValue
        self.notes = notes
        self.tags = tags
        self.sessionKindRaw = sessionKind == .unknown ? nil : sessionKind.rawValue
        self.topics = topics
        self.contentStatusRaw = contentStatus == .none ? nil : contentStatus.rawValue
        self.contentSummary = contentSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startAt = try c.decode(Date.self, forKey: .startAt)
        endAt = try c.decodeIfPresent(Date.self, forKey: .endAt)
        lastObservedAt = try c.decodeIfPresent(Date.self, forKey: .lastObservedAt) ?? endAt ?? startAt
        appName = try c.decode(String.self, forKey: .appName)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle) ?? ""
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        isIdle = try c.decodeIfPresent(Bool.self, forKey: .isIdle) ?? false
        categoryRaw = try c.decodeIfPresent(String.self, forKey: .categoryRaw) ?? ActivityCategory.other.rawValue
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        sessionKindRaw = try c.decodeIfPresent(String.self, forKey: .sessionKindRaw)
        topics = try c.decodeIfPresent([String].self, forKey: .topics) ?? []
        contentStatusRaw = try c.decodeIfPresent(String.self, forKey: .contentStatusRaw)
        contentSummary = try c.decodeIfPresent(String.self, forKey: .contentSummary)
    }

    var category: ActivityCategory {
        get { ActivityCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var duration: TimeInterval {
        let end = endAt ?? .now
        return max(0, end.timeIntervalSince(startAt))
    }

    var isOpen: Bool { endAt == nil }

    var displayTitle: String {
        if let domain, !domain.isEmpty { return domain }
        if !windowTitle.isEmpty { return windowTitle }
        return appName
    }
}

enum ActivityCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case coding
    case browsing
    case communication
    case design
    case media
    case productivity
    case system
    case entertainment
    case learning
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coding: "Coding"
        case .browsing: "Browsing"
        case .communication: "Communication"
        case .design: "Design"
        case .media: "Media"
        case .productivity: "Productivity"
        case .system: "System"
        case .entertainment: "Entertainment"
        case .learning: "Learning"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .browsing: "globe"
        case .communication: "bubble.left.and.bubble.right"
        case .design: "paintbrush"
        case .media: "play.rectangle"
        case .productivity: "checkmark.circle"
        case .system: "gearshape"
        case .entertainment: "gamecontroller"
        case .learning: "book"
        case .other: "square.grid.2x2"
        }
    }

    var focusWeight: Double {
        switch self {
        case .coding, .design, .learning, .productivity: 1.0
        case .communication: 0.55
        case .browsing: 0.4
        case .media: 0.25
        case .entertainment: 0.1
        case .system, .other: 0.35
        }
    }
}

struct TagDefinition: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#5B8DEF",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}

struct DailySnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var dayStart: Date
    var generatedAt: Date
    var markdown: String
    var activeSeconds: Double
    var idleSeconds: Double
    var focusScore: Double
    var topAppName: String
    var topDomain: String

    init(
        id: UUID = UUID(),
        dayStart: Date,
        generatedAt: Date = .now,
        markdown: String = "",
        activeSeconds: Double = 0,
        idleSeconds: Double = 0,
        focusScore: Double = 0,
        topAppName: String = "",
        topDomain: String = ""
    ) {
        self.id = id
        self.dayStart = dayStart
        self.generatedAt = generatedAt
        self.markdown = markdown
        self.activeSeconds = activeSeconds
        self.idleSeconds = idleSeconds
        self.focusScore = focusScore
        self.topAppName = topAppName
        self.topDomain = topDomain
    }
}
