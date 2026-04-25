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
    var season: Int?
    var episode: Int?
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
    var intro: [SegmentRange]?
    var recap: [SegmentRange]?
    var credits: [SegmentRange]?
    var preview: [SegmentRange]?

    enum CodingKeys: String, CodingKey {
        case tmdbId = "tmdb_id"
        case type
        case season
        case episode
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
    var ok: Bool
    var submission: TheIntroDBSubmissionData
}

struct TheIntroDBSubmissionData: Decodable, Sendable {
    var id: UUID
    var tmdbId: Int
    var type: MediaType
    var segment: SegmentType
    var season: Int?
    var episode: Int?
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
    var season: Int?
    var episode: Int?
    var startMs: Int
    var endMs: Int?
    var imdbId: String?

    enum CodingKeys: String, CodingKey {
        case tmdbId = "tmdb_id"
        case type
        case segment
        case season
        case episode
        case startMs = "start_ms"
        case endMs = "end_ms"
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
