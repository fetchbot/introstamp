import Foundation
import SwiftUI

enum MediaType: String, Codable, CaseIterable, Hashable, Sendable {
    case movie
    case tv

    var displayName: String {
        switch self {
        case .movie:
            "Movie"
        case .tv:
            "TV"
        }
    }
}

enum AppMode: String, Codable, CaseIterable, Hashable, Sendable {
    case singleVideo
    case listReview

    var displayName: String {
        switch self {
        case .singleVideo:
            return "Single Video"
        case .listReview:
            return "List Review"
        }
    }
}

struct ListReviewItem: Identifiable, Hashable, Sendable {
    var identityKey: String
    var title: String
    var mediaType: MediaType
    var tmdbId: Int?
    var imdbId: String?
    var season: Int?
    var episode: Int?
    var posterURL: URL?
    var videoDurationMs: Int?
    var sourceLabel: String
    var segments: [SegmentType: SegmentRange]
    var segmentGroups: [SegmentType: [SegmentRange]] = [:]
    var draftSegments: [SegmentType: SegmentRange] = [:]
    var draftSegmentGroups: [SegmentType: [SegmentRange]] = [:]
    var noSegmentFlags: [SegmentType: Bool] = [:]
    var submitMessage: String?
    var isSubmitting: Bool = false

    var id: String { identityKey }

    var groupKey: String {
        let normalizedIMDb = imdbId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mediaType == .tv {
            if let tmdbId, tmdbId > 0 {
                return "tv|tmdb|\(tmdbId)"
            }
            return "tv|imdb|\(normalizedIMDb.lowercased())"
        }

        let tmdbPart = tmdbId.map(String.init) ?? "-1"
        return "\(mediaType.rawValue)|\(tmdbPart)|\(normalizedIMDb.lowercased())"
    }

    var rowLabel: String {
        if mediaType == .tv, let season, let episode {
            return "S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
        }
        return "Movie"
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let tmdbId {
            return "TMDB \(tmdbId)"
        }
        if let imdbId {
            return imdbId
        }
        return "Untitled"
    }
}

struct TheIntroDBMediaVersion: Decodable, Sendable {
    var durationMs: Int
    var averageDurationMs: Int?
    var submissionCount: Int

    enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case averageDurationMs = "average_duration_ms"
        case submissionCount = "submission_count"
    }
}

struct TheIntroDBMediaVersionListResponse: Decodable, Sendable {
    var versions: [TheIntroDBMediaVersion]
}

enum SegmentType: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case intro
    case recap
    case credits
    case preview

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var color: Color {
        switch self {
        case .intro:
            .blue
        case .recap:
            .orange
        case .credits:
            .green
        case .preview:
            .pink
        }
    }
}

struct SegmentRange: Codable, Hashable, Sendable {
    var startMs: Int?
    var endMs: Int?

    var normalizedStartMs: Int { max(startMs ?? 0, 0) }

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

struct SegmentDraft: Hashable, Sendable {
    var startMs: Int?
    var endMs: Int?

    static var empty: SegmentDraft {
        SegmentDraft(startMs: nil, endMs: nil)
    }
}

struct TimelineDensityTrack: Hashable, Sendable {
    var label: String
    var buckets: [Double]
    var musicLikelihoodBuckets: [Double]? = nil
    var recapHintBuckets: [Double]? = nil

    static var empty: TimelineDensityTrack {
        TimelineDensityTrack(label: "", buckets: [])
    }

    var hasContent: Bool {
        !label.isEmpty && !buckets.isEmpty
    }
}

struct MediaQuery: Hashable, Sendable {
    var tmdbId: Int?
    var imdbId: String?
    var tvdbId: Int?
    var season: Int?
    var episode: Int?
    var durationMs: Int?

    init(
        tmdbId: Int? = nil,
        imdbId: String? = nil,
        tvdbId: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.tvdbId = tvdbId
        self.season = season
        self.episode = episode
        self.durationMs = durationMs
    }
}

struct SubmissionDraft: Hashable, Sendable {
    var tmdbId: Int
    var imdbId: String?
    var mediaType: MediaType
    var segment: SegmentType
    var season: Int?
    var episode: Int?
    var startMs: Int?
    var endMs: Int?
    var isNoSegment: Bool = false
}

struct UsageHeaders: Hashable, Sendable {
    var rateLimit: Int?
    var rateRemaining: Int?
    var rateResetSeconds: Int?
    var usageLimit: Int?
    var usageRemaining: Int?
    var usageResetSeconds: Int?

    var shortDescription: String {
        var chunks: [String] = []
        if let rateRemaining, let rateLimit {
            chunks.append("rate \(rateRemaining)/\(rateLimit)")
        }
        if let usageRemaining, let usageLimit {
            chunks.append("usage \(usageRemaining)/\(usageLimit)")
        }
        if chunks.isEmpty {
            return "No limit headers"
        }
        return chunks.joined(separator: " • ")
    }
}

struct IntroDBErrorPayload: Decodable, Sendable {
    var error: String
    var details: String?
}

struct TheIntroDBMediaResponse: Decodable, Sendable {
    var tmdbId: Int
    var type: MediaType
    var season: Int?
    var episode: Int?
    var durationMs: Int?
    var intro: [SegmentRange]?
    var recap: [SegmentRange]?
    var credits: [SegmentRange]?
    var preview: [SegmentRange]?

    enum CodingKeys: String, CodingKey {
        case tmdbId = "tmdb_id"
        case type
        case season
        case episode
        case durationMs = "duration_ms"
        case intro
        case recap
        case credits
        case preview
    }

    func groupedSegments() -> [SegmentType: [SegmentRange]] {
        [
            .intro: intro ?? [],
            .recap: recap ?? [],
            .credits: credits ?? [],
            .preview: preview ?? []
        ]
    }
}

struct TheIntroDBSubmissionResponse: Decodable, Sendable {
    var submissions: [TheIntroDBSubmissionData]

    var ok: Bool {
        !submissions.isEmpty
    }

    var submission: TheIntroDBSubmissionData? {
        submissions.first
    }

    private enum CodingKeys: String, CodingKey {
        case submissions
        case submission
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let list = try container.decodeIfPresent([TheIntroDBSubmissionData].self, forKey: .submissions) {
            submissions = list
            return
        }

        if let single = try container.decodeIfPresent(TheIntroDBSubmissionData.self, forKey: .submission) {
            submissions = [single]
            return
        }

        submissions = []
    }
}

struct TheIntroDBSubmissionData: Decodable, Sendable {
    var id: UUID
    var tmdbId: Int
    var type: MediaType
    var segment: SegmentType
    var season: Int?
    var episode: Int?
    var videoDurationMs: Int?
    var startMs: Int?
    var endMs: Int?
    var status: SubmissionStatus
    var weight: Double

    enum CodingKeys: String, CodingKey {
        case id
        case tmdbId
        case type
        case segment
        case season
        case episode
        case videoDurationMs
        case startMs
        case endMs
        case status
        case weight
    }
}

enum SubmissionStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
}

struct TheIntroDBSubmissionRequest: Encodable, Sendable {
    var tmdbId: Int
    var type: MediaType
    var segment: SegmentType
    var season: Int? = nil
    var episode: Int? = nil
    var startMs: Int
    var endMs: Int? = nil
    var videoDurationMs: Int? = nil
    var tvdbId: Int? = nil
    var imdbId: String? = nil

    enum CodingKeys: String, CodingKey {
        case tmdbId = "tmdb_id"
        case type
        case segment
        case season
        case episode
        case startMs = "start_ms"
        case endMs = "end_ms"
        case videoDurationMs = "video_duration_ms"
        case tvdbId = "tvdb_id"
        case imdbId = "imdb_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tmdbId, forKey: .tmdbId)
        try container.encode(type, forKey: .type)
        try container.encode(segment, forKey: .segment)
        try container.encode(startMs, forKey: .startMs)
        try container.encodeIfPresent(season, forKey: .season)
        try container.encodeIfPresent(episode, forKey: .episode)
        try container.encodeIfPresent(endMs, forKey: .endMs)
        try container.encodeIfPresent(videoDurationMs, forKey: .videoDurationMs)
        try container.encodeIfPresent(tvdbId, forKey: .tvdbId)
        try container.encodeIfPresent(imdbId, forKey: .imdbId)
    }
}

enum IntroDBSegmentType: String, Codable, Sendable {
    case intro
    case recap
    case outro

    init?(from segment: SegmentType) {
        switch segment {
        case .intro:
            self = .intro
        case .recap:
            self = .recap
        case .credits:
            self = .outro
        case .preview:
            return nil
        }
    }

    var appSegment: SegmentType {
        switch self {
        case .intro:
            return .intro
        case .recap:
            return .recap
        case .outro:
            return .credits
        }
    }
}

struct IntroDBMediaResponse: Decodable, Sendable {
    var imdbId: String
    var season: Int
    var episode: Int
    var intro: IntroDBSegmentAggregate?
    var recap: IntroDBSegmentAggregate?
    var outro: IntroDBSegmentAggregate?

    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
        case season
        case episode
        case intro
        case recap
        case outro
    }

    func groupedSegments() -> [SegmentType: [SegmentRange]] {
        let introRanges = intro.map { [SegmentRange(startMs: $0.startMs, endMs: $0.endMs)] } ?? []
        let recapRanges = recap.map { [SegmentRange(startMs: $0.startMs, endMs: $0.endMs)] } ?? []
        let creditsRanges = outro.map { [SegmentRange(startMs: $0.startMs, endMs: $0.endMs)] } ?? []

        return [
            .intro: introRanges,
            .recap: recapRanges,
            .credits: creditsRanges,
            .preview: []
        ]
    }
}

struct IntroDBSegmentAggregate: Decodable, Sendable {
    var startMs: Int
    var endMs: Int
    var startSec: Double?
    var endSec: Double?
    var confidence: Double?
    var submissionCount: Int?

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
        case startSec = "start_sec"
        case endSec = "end_sec"
        case confidence
        case submissionCount = "submission_count"
    }
}

struct IntroDBSubmissionRequest: Encodable, Sendable {
    var segmentType: IntroDBSegmentType
    var imdbId: String
    var season: Int
    var episode: Int
    var startSec: Double
    var endSec: Double
    var tvdbId: Int?
    var tmdbId: Int?

    enum CodingKeys: String, CodingKey {
        case segmentType = "segment_type"
        case imdbId = "imdb_id"
        case season
        case episode
        case startSec = "start_sec"
        case endSec = "end_sec"
        case tvdbId = "tvdb_id"
        case tmdbId = "tmdb_id"
    }
}

struct IntroDBSubmissionResponse: Decodable, Sendable {
    var ok: Bool
    var submission: IntroDBSubmissionData
}

struct IntroDBSubmissionData: Decodable, Sendable {
    var id: UUID
    var imdbId: String?
    var season: Int?
    var episode: Int?
    var startMs: Int?
    var endMs: Int?
    var status: SubmissionStatus?
    var weight: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case imdbId
        case season
        case episode
        case startMs
        case endMs
        case status
        case weight
    }
}

struct AutoLookupResult: Hashable, Sendable {
    var tmdbId: Int
    var imdbId: String?
    var mediaType: MediaType
    var season: Int?
    var episode: Int?
    var title: String
    var matchedYear: Int?
    var posterURL: URL?
}

struct ParsedFilenameHint: Hashable, Sendable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?

    var mediaTypeHint: MediaType {
        (season != nil || episode != nil) ? .tv : .movie
    }
}

struct SceneChange: Hashable, Sendable, Comparable {
    enum TransitionType: String, Hashable, Sendable {
        case hardCut = "hard_cut"
        case dissolve = "dissolve"
        case fadeIn = "fade_in"
        case fadeOut = "fade_out"
    }

    let index: Int
    let timestampMs: Int
    let endTimestampMs: Int?
    let score: Double
    let type: TransitionType

    var timeString: String {
        let t = Double(timestampMs) / 1000.0
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        let ms = Int((t.truncatingRemainder(dividingBy: 1)) * 1000)
        return h > 0
            ? String(format: "%d:%02d:%02d.%03d", h, m, s, ms)
            : String(format: "%02d:%02d.%03d", m, s, ms)
    }

    var endTimeString: String? {
        guard let ms = endTimestampMs else { return nil }
        let t = Double(ms) / 1000.0
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        let ms2 = Int((t.truncatingRemainder(dividingBy: 1)) * 1000)
        return h > 0
            ? String(format: "%d:%02d:%02d.%03d", h, m, s, ms2)
            : String(format: "%02d:%02d.%03d", m, s, ms2)
    }

    static func < (lhs: SceneChange, rhs: SceneChange) -> Bool {
        lhs.timestampMs < rhs.timestampMs
    }
}

actor SegmentSubmitPersistentLogger {
    static let shared = SegmentSubmitPersistentLogger()
    private static let submissionLoggingEnabledDefaultsKey = "submission_logging_enabled_v1"
    private static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }()

    private let fileManager: FileManager
    private let logsDirectoryURL: URL

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        guard !Self.isRunningTests else {
            self.logsDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent("introstamp-test-logs", isDirectory: true)
            return
        }

        self.logsDirectoryURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)

        if !fileManager.fileExists(atPath: logsDirectoryURL.path) {
            try? fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        }
    }

    func log(
        service: String,
        url: String,
        requestBody: String,
        statusCode: Int?,
        responseBody: String?,
        errorMessage: String?
    ) {
        guard !Self.isRunningTests else { return }

        let hasStoredPreference = UserDefaults.standard.object(forKey: Self.submissionLoggingEnabledDefaultsKey) != nil
        let isEnabled = hasStoredPreference
            ? UserDefaults.standard.bool(forKey: Self.submissionLoggingEnabledDefaultsKey)
            : true
        guard isEnabled else { return }

        _ = url
        _ = requestBody
        _ = statusCode
        _ = errorMessage

        guard let responseBody,
              !responseBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isValidJSON(responseBody)
        else {
            return
        }

        do {
            try append(responseBody.data(using: .utf8) ?? Data(), service: service)
            try append(Data([0x0A]), service: service)
        } catch {
            // Intentionally ignore logger errors to avoid affecting submit requests.
        }
    }

    private func append(_ data: Data, service: String) throws {
        let logFileURL = logFileURL(for: service)
        if !fileManager.fileExists(atPath: logFileURL.path) {
            _ = fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: logFileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func logFileURL(for service: String) -> URL {
        let normalizedService = service
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let fileName = normalizedService.isEmpty
            ? "segment_submit_responses.jsonl"
            : "segment_submit_responses_\(normalizedService).jsonl"
        return logsDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

// MARK: - Submission Backup Models

struct TheIntroDBSubmissionsResponse: Decodable, Sendable {
    var submissions: [TheIntroDBSubmissionListItem]
    var total: Int
    var limit: Int
    var offset: Int

    enum CodingKeys: String, CodingKey {
        case submissions
        case total
        case limit
        case offset
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        submissions = try container.decode([TheIntroDBSubmissionListItem].self, forKey: .submissions)
        
        // These fields may not always be present in the response
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? Int.max
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? submissions.count
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

struct TheIntroDBSubmissionListItem: Codable, Sendable {
    var id: UUID
    var userId: String
    var tmdbId: Int?
    var imdbId: String?
    var type: MediaType
    var segment: SegmentType
    var season: Int?
    var episode: Int?
    var videoDurationMs: Int?
    var startMs: Int
    var endMs: Int?
    var status: SubmissionStatus
    var submittedAt: Int
    var weight: Double?
    var flagVotes: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case tmdbId = "tmdb_id"
        case imdbId = "imdb_id"
        case type
        case segment
        case season
        case episode
        case videoDurationMs = "video_duration_ms"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case status
        case submittedAt = "submitted_at"
        case weight
        case flagVotes = "flag_votes"
    }
}

struct IntroDBSubmissionsResponse: Decodable, Sendable {
    var submissions: [IntroDBSubmissionListItem]
    var stats: IntroDBStats
    var pagination: IntroDBPagination

    enum CodingKeys: String, CodingKey {
        case submissions
        case stats
        case pagination
    }
}

struct IntroDBSubmissionListItem: Codable, Sendable {
    var id: UUID
    var imdbId: String?
    var segmentType: String
    var tvdbId: Int?
    var tmdbId: Int?
    var season: Int?
    var episode: Int?
    var startSec: Double?
    var endSec: Double?
    var startMs: Int
    var endMs: Int?
    var status: String
    var weight: Int?
    var createdAt: String?
    var updatedAt: String?
    var aggregateStartMs: Int?
    var aggregateEndMs: Int?
    var aggregateUpdatedAt: String?
    var openReports: Int?
    var reportPressure: Int?
    var incidentStatus: String?
    var netVotes: Int?
    var upVotes: Int?
    var downVotes: Int?
    var votesToAccept: Int?
    var show: IntroDBShow?

    enum CodingKeys: String, CodingKey {
        case id
        case imdbId = "imdb_id"
        case segmentType = "segment_type"
        case tvdbId = "tvdb_id"
        case tmdbId = "tmdb_id"
        case season
        case episode
        case startSec = "start_sec"
        case endSec = "end_sec"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case status
        case weight
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case aggregateStartMs = "aggregate_start_ms"
        case aggregateEndMs = "aggregate_end_ms"
        case aggregateUpdatedAt = "aggregate_updated_at"
        case openReports = "open_reports"
        case reportPressure = "report_pressure"
        case incidentStatus = "incident_status"
        case netVotes = "net_votes"
        case upVotes = "up_votes"
        case downVotes = "down_votes"
        case votesToAccept = "votes_to_accept"
        case show
    }
}

struct IntroDBShow: Codable, Sendable {
    var title: String?
    var posterUrl: String?
    var source: String?
    var year: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case posterUrl = "posterUrl"
        case source
        case year
    }
}

struct IntroDBStats: Codable, Sendable {
    var total: Int?
    var live: Int?
    var review: Int?
    var pending: Int?
    var accepted: Int?
    var rejected: Int?
    var liveRate: Int?
    var acceptanceRate: Int?
    var streakCurrentDays: Int?
    var streakBestDays: Int?
    var topShows: [IntroDBTopShow]

    enum CodingKeys: String, CodingKey {
        case total
        case live
        case review
        case pending
        case accepted
        case rejected
        case liveRate = "live_rate"
        case acceptanceRate = "acceptance_rate"
        case streakCurrentDays = "streak_current_days"
        case streakBestDays = "streak_best_days"
        case topShows = "top_shows"
    }
}

struct IntroDBTopShow: Codable, Sendable {
    var imdbId: String
    var title: String
    var posterUrl: String
    var count: Int

    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
        case title
        case posterUrl = "poster_url"
        case count
    }
}

struct IntroDBPagination: Decodable, Sendable {
    var page: Int?
    var perPage: Int?
    var totalPages: Int?
    var totalItems: Int?

    enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case totalPages = "total_pages"
        case totalItems = "total_items"
    }
}

// MARK: - Clerk Session Models

struct ClerkSession: Sendable {
    var sessionId: String
    var currentToken: String
    var clientCookie: String
    var createdAt: Date = Date()
}

struct ClerkTokenResponse: Decodable, Sendable {
    let jwt: String
}
