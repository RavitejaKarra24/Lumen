import Foundation

// MARK: - Session intelligence

enum SessionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepWork
    case learning
    case research
    case communication
    case meeting
    case creation
    case distraction
    case admin
    case idle
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepWork: "Deep work"
        case .learning: "Learning"
        case .research: "Research"
        case .communication: "Communication"
        case .meeting: "Meeting"
        case .creation: "Creation"
        case .distraction: "Distraction"
        case .admin: "Admin"
        case .idle: "Idle"
        case .unknown: "Unclassified"
        }
    }

    var symbolName: String {
        switch self {
        case .deepWork: "brain.head.profile"
        case .learning: "graduationcap.fill"
        case .research: "magnifyingglass"
        case .communication: "bubble.left.and.bubble.right.fill"
        case .meeting: "person.3.fill"
        case .creation: "hammer.fill"
        case .distraction: "flame.fill"
        case .admin: "tray.full.fill"
        case .idle: "moon.zzz.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var isHighValue: Bool {
        switch self {
        case .deepWork, .learning, .creation, .research: true
        default: false
        }
    }
}

enum ContentKind: String, Codable, Sendable {
    case page
    case transcript
    case windowText
    case metadata
}

enum ContentStatus: String, Codable, Sendable {
    case none
    case pending
    case ready
    case failed
    case skipped
}

struct ContentArtifact: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var segmentID: UUID
    var urlString: String?
    var kind: ContentKind
    var title: String
    var text: String
    var wordCount: Int
    var status: ContentStatus
    var errorMessage: String?
    var fetchedAt: Date
    var source: String

    init(
        id: UUID = UUID(),
        segmentID: UUID,
        urlString: String? = nil,
        kind: ContentKind,
        title: String = "",
        text: String = "",
        status: ContentStatus = .ready,
        errorMessage: String? = nil,
        fetchedAt: Date = .now,
        source: String = "lumen"
    ) {
        self.id = id
        self.segmentID = segmentID
        self.urlString = urlString
        self.kind = kind
        self.title = title
        self.text = text
        self.wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        self.status = status
        self.errorMessage = errorMessage
        self.fetchedAt = fetchedAt
        self.source = source
    }
}

enum InsightKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case learningSummary
    case interest
    case idea
    case actionItem
    case sessionNote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .learningSummary: "Learning"
        case .interest: "Interest"
        case .idea: "Idea"
        case .actionItem: "Action"
        case .sessionNote: "Note"
        }
    }

    var symbolName: String {
        switch self {
        case .learningSummary: "book.fill"
        case .interest: "sparkles"
        case .idea: "lightbulb.fill"
        case .actionItem: "checklist"
        case .sessionNote: "note.text"
        }
    }
}

struct InsightRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var dayStart: Date
    var kind: InsightKind
    var title: String
    var body: String
    var confidence: Double
    var topics: [String]
    var sourceSegmentIDs: [UUID]
    var isPinned: Bool
    var isCompleted: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        dayStart: Date,
        kind: InsightKind,
        title: String,
        body: String = "",
        confidence: Double = 0.5,
        topics: [String] = [],
        sourceSegmentIDs: [UUID] = [],
        isPinned: Bool = false,
        isCompleted: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.dayStart = dayStart
        self.kind = kind
        self.title = title
        self.body = body
        self.confidence = confidence
        self.topics = topics
        self.sourceSegmentIDs = sourceSegmentIDs
        self.isPinned = isPinned
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct InterestSignal: Identifiable, Hashable, Sendable {
    var id: String { topic }
    var topic: String
    var score: Double
    var duration: TimeInterval
    var occurrences: Int
    var domains: [String]
    var sampleTitles: [String]
}

struct IntelligenceReport: Sendable {
    var dayStart: Date
    var interests: [InterestSignal]
    var learningSummary: String
    var ideas: [InsightRecord]
    var actionItems: [InsightRecord]
    var classifiedCounts: [SessionKind: Int]
    var capturedContentCount: Int
    var transcriptCount: Int
}

// MARK: - Segment enrichment helpers (stored on ActivitySegment)

extension ActivitySegment {
    var sessionKind: SessionKind {
        get { SessionKind(rawValue: sessionKindRaw ?? "") ?? .unknown }
        set { sessionKindRaw = newValue.rawValue }
    }

    var contentStatus: ContentStatus {
        get { ContentStatus(rawValue: contentStatusRaw ?? "") ?? .none }
        set { contentStatusRaw = newValue.rawValue }
    }
}
