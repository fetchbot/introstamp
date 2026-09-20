import Foundation

enum SegmentValidationError: LocalizedError, Equatable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            text
        }
    }
}

enum SegmentValidator {
    static let minDurationMs = 5_000
    static let maxTimestampMs = 21_600_000
    static let maxIntroDurationMs = 200_000
    static let maxRecapDurationMs = 1_200_000
    static let maxCreditsDurationMs = 1_800_000
    static let maxPreviewDurationMs = 1_800_000
    static let minVideoDurationMs = 300_000

    static func makeTheIntroDBSubmissionRequest(from draft: SubmissionDraft, videoDurationMs: Int? = nil) throws -> TheIntroDBSubmissionRequest {
        guard draft.tmdbId > 0 else {
            throw SegmentValidationError.message("TMDB ID is required")
        }

        if let videoDurationMs {
            try validateVideoDuration(videoDurationMs)
        }

        // No-segment: bypass time validation and submit a zero-length segment.
        if draft.isNoSegment {
            switch draft.mediaType {
            case .movie:
                if draft.season != nil || draft.episode != nil {
                    throw SegmentValidationError.message("Season and episode must be empty for movie submissions")
                }
            case .tv:
                guard let season = draft.season, season >= 0,
                      let episode = draft.episode, episode > 0
                else {
                    throw SegmentValidationError.message("Season and episode are required for TV submissions")
                }
            }
            return TheIntroDBSubmissionRequest(
                tmdbId: draft.tmdbId,
                type: draft.mediaType,
                segment: draft.segment,
                season: draft.season,
                episode: draft.episode,
                startMs: 0,
                endMs: 0,
                videoDurationMs: videoDurationMs,
                tvdbId: nil,
                imdbId: normalizedImdb(draft.imdbId)
            )
        }

        switch draft.mediaType {
        case .movie:
            if draft.season != nil || draft.episode != nil {
                throw SegmentValidationError.message("Season and episode must be empty for movie submissions")
            }
        case .tv:
            guard let season = draft.season, season >= 0,
                  let episode = draft.episode, episode > 0
            else {
                throw SegmentValidationError.message("Season and episode are required for TV submissions")
            }
        }

        return try validatedTheIntroDBRequest(from: draft, videoDurationMs: videoDurationMs)
    }

    // Backward-compatible alias for existing call sites/tests.
    static func makeSubmissionRequest(from draft: SubmissionDraft) throws -> TheIntroDBSubmissionRequest {
        try makeTheIntroDBSubmissionRequest(from: draft)
    }

    static func makeIntroDBSubmissionRequest(from draft: SubmissionDraft, mediaDurationMs: Int) throws -> IntroDBSubmissionRequest {
        guard draft.mediaType == .tv else {
            throw SegmentValidationError.message("IntroDB supports TV episodes only")
        }

        guard let imdbId = normalizedImdb(draft.imdbId), Self.isValidIMDb(imdbId) else {
            throw SegmentValidationError.message("Valid IMDB ID is required for IntroDB uploads")
        }

        guard let season = draft.season, season >= 0,
              let episode = draft.episode, episode > 0
        else {
            throw SegmentValidationError.message("Season and episode are required for IntroDB uploads")
        }

        guard let introDBSegment = IntroDBSegmentType(from: draft.segment) else {
            throw SegmentValidationError.message("IntroDB does not support \(draft.segment.displayName) uploads")
        }

        let normalizedDraft = SubmissionDraft(
            tmdbId: draft.tmdbId,
            imdbId: draft.imdbId,
            mediaType: draft.mediaType,
            segment: draft.segment,
            season: season,
            episode: episode,
            startMs: draft.startMs,
            endMs: draft.endMs
        )

        let request = try validatedTheIntroDBRequest(from: normalizedDraft, videoDurationMs: nil)
        let endMs = request.endMs ?? mediaDurationMs

        return IntroDBSubmissionRequest(
            segmentType: introDBSegment,
            imdbId: imdbId,
            season: season,
            episode: episode,
            startSec: Double(request.startMs) / 1000.0,
            endSec: Double(endMs) / 1000.0,
            tvdbId: nil,
            tmdbId: request.tmdbId > 0 ? request.tmdbId : nil
        )
    }

    private static func validatedTheIntroDBRequest(from draft: SubmissionDraft, videoDurationMs: Int?) throws -> TheIntroDBSubmissionRequest {
        switch draft.segment {
        case .intro:
            return try validateIntroOrRecap(draft: draft, maxDurationMs: maxIntroDurationMs, videoDurationMs: videoDurationMs)
        case .recap:
            return try validateIntroOrRecap(draft: draft, maxDurationMs: maxRecapDurationMs, videoDurationMs: videoDurationMs)
        case .credits:
            return try validateCreditsOrPreview(draft: draft, maxDurationMs: maxCreditsDurationMs, videoDurationMs: videoDurationMs)
        case .preview:
            return try validateCreditsOrPreview(draft: draft, maxDurationMs: maxPreviewDurationMs, videoDurationMs: videoDurationMs)
        }
    }

    private static func validateIntroOrRecap(draft: SubmissionDraft, maxDurationMs: Int, videoDurationMs: Int?) throws -> TheIntroDBSubmissionRequest {
        let start = max(draft.startMs ?? 0, 0)
        guard let end = draft.endMs else {
            throw SegmentValidationError.message("\(draft.segment.displayName) end is required")
        }

        try assertTimestampBounds(start)
        try assertTimestampBounds(end)

        guard end >= start else {
            throw SegmentValidationError.message("End must be greater than or equal to start")
        }

        let duration = end - start
        if duration != 0 {
            guard duration >= minDurationMs && duration <= maxDurationMs else {
                throw SegmentValidationError.message("\(draft.segment.displayName) duration must be 0 or between \(minDurationMs / 1000)s and \(maxDurationMs / 1000)s")
            }
        }

        return TheIntroDBSubmissionRequest(
            tmdbId: draft.tmdbId,
            type: draft.mediaType,
            segment: draft.segment,
            season: draft.season,
            episode: draft.episode,
            startMs: start,
            endMs: end,
            videoDurationMs: videoDurationMs,
            tvdbId: nil,
            imdbId: normalizedImdb(draft.imdbId)
        )
    }

    private static func validateCreditsOrPreview(draft: SubmissionDraft, maxDurationMs: Int, videoDurationMs: Int?) throws -> TheIntroDBSubmissionRequest {
        guard let start = draft.startMs else {
            throw SegmentValidationError.message("\(draft.segment.displayName) start is required")
        }

        try assertTimestampBounds(start)

        if draft.segment == .credits, start != 0, start < minDurationMs {
            throw SegmentValidationError.message("Credits start must be 0 or at least \(minDurationMs / 1000)s")
        }

        if let end = draft.endMs {
            try assertTimestampBounds(end)
            guard end > start else {
                throw SegmentValidationError.message("End must be greater than start")
            }

            let duration = end - start
            guard duration >= minDurationMs && duration <= maxDurationMs else {
                throw SegmentValidationError.message("\(draft.segment.displayName) duration must be between \(minDurationMs / 1000)s and \(maxDurationMs / 1000)s")
            }
        }

        return TheIntroDBSubmissionRequest(
            tmdbId: draft.tmdbId,
            type: draft.mediaType,
            segment: draft.segment,
            season: draft.season,
            episode: draft.episode,
            startMs: start,
            endMs: draft.endMs,
            videoDurationMs: videoDurationMs,
            tvdbId: nil,
            imdbId: normalizedImdb(draft.imdbId)
        )
    }

    private static func validateVideoDuration(_ value: Int) throws {
        guard value == 0 || (value >= minVideoDurationMs && value <= maxTimestampMs) else {
            throw SegmentValidationError.message("video_duration_ms must be 0 or between \(minVideoDurationMs) and \(maxTimestampMs)")
        }
    }

    private static func assertTimestampBounds(_ value: Int) throws {
        guard value >= 0 && value <= maxTimestampMs else {
            throw SegmentValidationError.message("Timestamp must be between 0 and \(maxTimestampMs)")
        }
    }

    private static func normalizedImdb(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isValidIMDb(_ imdb: String) -> Bool {
        let pattern = "^tt[0-9]{7,8}$"
        return imdb.range(of: pattern, options: .regularExpression) != nil
    }
}
