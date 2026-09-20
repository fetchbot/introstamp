import XCTest
@testable import IntroStamp

final class SegmentValidatorTests: XCTestCase {
    func testMakeSubmissionRequest_AllowsNilEndForCredits() throws {
        let draft = SubmissionDraft(
            tmdbId: 123,
            imdbId: nil,
            mediaType: .movie,
            segment: .credits,
            season: nil,
            episode: nil,
            startMs: 1600000,
            endMs: nil
        )

        let request = try SegmentValidator.makeSubmissionRequest(from: draft)

        XCTAssertEqual(request.startMs, 1600000)
        XCTAssertNil(request.endMs)
    }

    func testMakeSubmissionRequest_RejectsIntroWithoutEnd() {
        let draft = SubmissionDraft(
            tmdbId: 123,
            imdbId: nil,
            mediaType: .movie,
            segment: .intro,
            season: nil,
            episode: nil,
            startMs: 10000,
            endMs: nil
        )

        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testMakeSubmissionRequest_RejectsTooShortPreview() {
        let draft = SubmissionDraft(
            tmdbId: 123,
            imdbId: nil,
            mediaType: .movie,
            segment: .preview,
            season: nil,
            episode: nil,
            startMs: 100000,
            endMs: 102000
        )

        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testMakeSubmissionRequest_RequiresSeasonAndEpisodeForTV() {
        let draft = SubmissionDraft(
            tmdbId: 123,
            imdbId: nil,
            mediaType: .tv,
            segment: .recap,
            season: 1,
            episode: nil,
            startMs: 0,
            endMs: 30000
        )

        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    // MARK: - TMDB ID

    func testMakeSubmissionRequest_RejectsZeroTMDBID() {
        let draft = SubmissionDraft(tmdbId: 0, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 60000)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testMakeSubmissionRequest_RejectsMovieWithSeason() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: 1, episode: nil, startMs: 0, endMs: 60000)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testMakeSubmissionRequest_RequiresBothSeasonAndEpisodeForTV() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .tv, segment: .intro, season: nil, episode: 1, startMs: 0, endMs: 60000)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testMakeSubmissionRequest_AllowsSeasonZeroForTVSpecial() {
        let draft = SubmissionDraft(
            tmdbId: 123,
            imdbId: nil,
            mediaType: .tv,
            segment: .intro,
            season: 0,
            episode: 1,
            startMs: 0,
            endMs: 60_000
        )

        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testMakeTheIntroDBSubmissionRequest_AllowsZeroVideoDuration() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 60_000)
        XCTAssertNoThrow(try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft, videoDurationMs: 0))
    }

    func testMakeTheIntroDBSubmissionRequest_RejectsVideoDurationBelowMinimum() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 60_000)
        XCTAssertThrowsError(try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft, videoDurationMs: 299_999))
    }

    // MARK: - Intro

    func testIntro_AllowsNilStart_TreatedAsZero() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: nil, endMs: 60000)
        let req = try SegmentValidator.makeSubmissionRequest(from: draft)
        XCTAssertEqual(req.startMs, 0)
        XCTAssertEqual(req.endMs, 60000)
    }

    func testIntro_AllowsZeroStart() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 60000)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testIntro_AllowsZeroDuration() throws {
        // duration 0 means "no intro"
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 0)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testIntro_AllowsMinDuration() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 5000)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testIntro_AllowsMaxDuration() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 200000)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testIntro_RejectsMissingEnd() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: nil)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testIntro_RejectsDurationBelowMin() {
        // 4999ms is between 1 and minDuration-1
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 4999)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testIntro_RejectsDurationAboveMax() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 200001)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testIntro_RejectsEndBeforeStart() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 50000, endMs: 40000)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testIntro_RejectsEndExceedingMaxTimestamp() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 21_600_001)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    // MARK: - Recap

    func testRecap_AllowsNilStart() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .recap, season: nil, episode: nil, startMs: nil, endMs: 120000)
        let req = try SegmentValidator.makeSubmissionRequest(from: draft)
        XCTAssertEqual(req.startMs, 0)
    }

    func testRecap_AllowsZeroDuration() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .recap, season: nil, episode: nil, startMs: 0, endMs: 0)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testRecap_AllowsMaxDuration() throws {
        // 1200s = 1200000ms
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .recap, season: nil, episode: nil, startMs: 0, endMs: 1_200_000)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testRecap_RejectsMissingEnd() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .recap, season: nil, episode: nil, startMs: 0, endMs: nil)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testRecap_RejectsDurationBelowMin() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .recap, season: nil, episode: nil, startMs: 0, endMs: 4999)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testRecap_RejectsDurationAboveMax() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .recap, season: nil, episode: nil, startMs: 0, endMs: 1_200_001)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    // MARK: - Credits

    func testCredits_RejectsMissingStart() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: nil, endMs: nil)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_AllowsZeroStart_NoCreditsMarker() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 0, endMs: nil)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_RejectsStartBetweenOneAndMinDuration() {
        // 1ms ≤ start < 5000ms is invalid (must be 0 or ≥ 5s)
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 4999, endMs: nil)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_AllowsStartAtMinDuration() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 5000, endMs: nil)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_AllowsNilEnd_ReturnsNilEndInRequest() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 1_600_000, endMs: nil)
        let req = try SegmentValidator.makeSubmissionRequest(from: draft)
        XCTAssertNil(req.endMs)
    }

    func testCredits_AllowsMinDurationWhenEndProvided() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 100_000, endMs: 105_000)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_AllowsMaxDurationWhenEndProvided() throws {
        // duration exactly 1800s
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 100_000, endMs: 1_900_000)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_RejectsDurationBelowMinWhenEndProvided() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 100_000, endMs: 104_999)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_RejectsDurationAboveMaxWhenEndProvided() {
        // duration 1800001ms > 1800000ms
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 100_000, endMs: 1_900_001)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_RejectsEndNotGreaterThanStart() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 100_000, endMs: 100_000)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testCredits_RejectsStartExceedingMaxTimestamp() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits, season: nil, episode: nil, startMs: 21_600_001, endMs: nil)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    // MARK: - Preview

    func testPreview_RejectsMissingStart() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .preview, season: nil, episode: nil, startMs: nil, endMs: 1_740_000)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testPreview_AllowsNilEnd_ReturnsNilEndInRequest() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .preview, season: nil, episode: nil, startMs: 1_680_000, endMs: nil)
        let req = try SegmentValidator.makeSubmissionRequest(from: draft)
        XCTAssertNil(req.endMs)
    }

    func testPreview_AllowsMinDurationWhenEndProvided() throws {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .preview, season: nil, episode: nil, startMs: 100_000, endMs: 105_000)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testPreview_AllowsMaxDurationWhenEndProvided() throws {
        // duration exactly 1800s
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .preview, season: nil, episode: nil, startMs: 100_000, endMs: 1_900_000)
        XCTAssertNoThrow(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testPreview_RejectsDurationBelowMinWhenEndProvided() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .preview, season: nil, episode: nil, startMs: 100_000, endMs: 104_999)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    func testPreview_RejectsDurationAboveMaxWhenEndProvided() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .preview, season: nil, episode: nil, startMs: 100_000, endMs: 1_900_001)
        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))
    }

    // MARK: - makeIntroDBSubmissionRequest

    private func tvDraft(segment: SegmentType, startMs: Int?, endMs: Int?) -> SubmissionDraft {
        SubmissionDraft(tmdbId: 1, imdbId: "tt1234567", mediaType: .tv, segment: segment, season: 1, episode: 1, startMs: startMs, endMs: endMs)
    }

    func testIntroDB_RejectsMovieMediaType() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: "tt1234567", mediaType: .movie, segment: .intro, season: nil, episode: nil, startMs: 0, endMs: 60000)
        XCTAssertThrowsError(try SegmentValidator.makeIntroDBSubmissionRequest(from: draft, mediaDurationMs: 3_600_000))
    }

    func testIntroDB_RejectsMissingImdbId() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: nil, mediaType: .tv, segment: .intro, season: 1, episode: 1, startMs: 0, endMs: 60000)
        XCTAssertThrowsError(try SegmentValidator.makeIntroDBSubmissionRequest(from: draft, mediaDurationMs: 3_600_000))
    }

    func testIntroDB_RejectsInvalidImdbIdFormat() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: "1234567", mediaType: .tv, segment: .intro, season: 1, episode: 1, startMs: 0, endMs: 60000)
        XCTAssertThrowsError(try SegmentValidator.makeIntroDBSubmissionRequest(from: draft, mediaDurationMs: 3_600_000))
    }

    func testIntroDB_RejectsMissingEpisode() {
        let draft = SubmissionDraft(tmdbId: 1, imdbId: "tt1234567", mediaType: .tv, segment: .intro, season: 1, episode: nil, startMs: 0, endMs: 60000)
        XCTAssertThrowsError(try SegmentValidator.makeIntroDBSubmissionRequest(from: draft, mediaDurationMs: 3_600_000))
    }

    func testIntroDB_AllowsSeasonZeroForTVSpecial() throws {
        let draft = SubmissionDraft(
            tmdbId: 1,
            imdbId: "tt1234567",
            mediaType: .tv,
            segment: .intro,
            season: 0,
            episode: 1,
            startMs: 0,
            endMs: 60_000
        )

        XCTAssertNoThrow(try SegmentValidator.makeIntroDBSubmissionRequest(from: draft, mediaDurationMs: 3_600_000))
    }

    func testIntroDB_RejectsPreviewSegment() {
        XCTAssertThrowsError(try SegmentValidator.makeIntroDBSubmissionRequest(from: tvDraft(segment: .preview, startMs: 100_000, endMs: 160_000), mediaDurationMs: 3_600_000))
    }

    func testIntroDB_Intro_MapsNilStartToZero() throws {
        let req = try SegmentValidator.makeIntroDBSubmissionRequest(from: tvDraft(segment: .intro, startMs: nil, endMs: 60000), mediaDurationMs: 3_600_000)
        XCTAssertEqual(req.startSec, 0.0)
    }

    func testIntroDB_Intro_ValidRange() throws {
        let req = try SegmentValidator.makeIntroDBSubmissionRequest(from: tvDraft(segment: .intro, startMs: 10000, endMs: 70000), mediaDurationMs: 3_600_000)
        XCTAssertEqual(req.startSec, 10.0)
        XCTAssertEqual(req.endSec, 70.0)
    }

    func testIntroDB_Intro_RejectsMissingEnd() {
        XCTAssertThrowsError(try SegmentValidator.makeIntroDBSubmissionRequest(from: tvDraft(segment: .intro, startMs: 0, endMs: nil), mediaDurationMs: 3_600_000))
    }

    func testIntroDB_Recap_MapsNilStartToZero() throws {
        let req = try SegmentValidator.makeIntroDBSubmissionRequest(from: tvDraft(segment: .recap, startMs: nil, endMs: 90000), mediaDurationMs: 3_600_000)
        XCTAssertEqual(req.startSec, 0.0)
    }

    func testIntroDB_Credits_MapsNilEndToMediaDuration() throws {
        // open end → mediaDurationMs
        let req = try SegmentValidator.makeIntroDBSubmissionRequest(from: tvDraft(segment: .credits, startMs: 3_000_000, endMs: nil), mediaDurationMs: 3_600_000)
        XCTAssertEqual(req.endSec, 3600.0)
    }

    func testIntroDB_Credits_UsesExplicitEndWhenProvided() throws {
        let req = try SegmentValidator.makeIntroDBSubmissionRequest(from: tvDraft(segment: .credits, startMs: 3_000_000, endMs: 3_060_000), mediaDurationMs: 3_600_000)
        XCTAssertEqual(req.endSec, 3060.0)
    }

    func testIntroDB_Credits_RejectsMissingStart() {
        XCTAssertThrowsError(try SegmentValidator.makeIntroDBSubmissionRequest(from: tvDraft(segment: .credits, startMs: nil, endMs: nil), mediaDurationMs: 3_600_000))
    }

    // MARK: - No Segment

    func testNoSegment_Movie_Intro_UsesZeroLengthRange() throws {
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        let req = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft)
        XCTAssertEqual(req.startMs, 0)
        XCTAssertEqual(req.endMs, 0)
    }

    func testNoSegment_Movie_Recap_UsesZeroLengthRange() throws {
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .recap,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        let req = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft)
        XCTAssertEqual(req.startMs, 0)
        XCTAssertEqual(req.endMs, 0)
    }

    func testNoSegment_Movie_Credits_UsesZeroLengthRange() throws {
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        let req = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft)
        XCTAssertEqual(req.startMs, 0)
        XCTAssertEqual(req.endMs, 0)
    }

    func testNoSegment_Movie_Preview_UsesZeroLengthRange() throws {
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .preview,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        let req = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft)
        XCTAssertEqual(req.startMs, 0)
        XCTAssertEqual(req.endMs, 0)
    }

    func testNoSegment_TV_Intro_UsesZeroLengthRange() throws {
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .tv, segment: .intro,
            season: 1, episode: 1, startMs: nil, endMs: nil, isNoSegment: true
        )
        let req = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft)
        XCTAssertEqual(req.season, 1)
        XCTAssertEqual(req.episode, 1)
        XCTAssertEqual(req.startMs, 0)
        XCTAssertEqual(req.endMs, 0)
    }

    func testNoSegment_TVSpecial_Intro_AllowsSeasonZero() throws {
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .tv, segment: .intro,
            season: 0, episode: 1, startMs: nil, endMs: nil, isNoSegment: true
        )
        let req = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft)
        XCTAssertEqual(req.season, 0)
        XCTAssertEqual(req.episode, 1)
        XCTAssertEqual(req.startMs, 0)
        XCTAssertEqual(req.endMs, 0)
    }

    func testNoSegment_BypassesTimeValidation_CreditsWouldNormallyFailMissingStart() throws {
        // Credits normally requires startMs – with isNoSegment it must not throw.
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .credits,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        XCTAssertNoThrow(try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft))
    }

    func testNoSegment_BypassesTimeValidation_IntroWouldNormallyFailMissingEnd() throws {
        // Intro normally requires endMs – with isNoSegment it must not throw.
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        XCTAssertNoThrow(try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft))
    }

    func testNoSegment_StillRejectsZeroTMDBID() {
        let draft = SubmissionDraft(
            tmdbId: 0, imdbId: nil, mediaType: .movie, segment: .intro,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        XCTAssertThrowsError(try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft))
    }

    func testNoSegment_TV_StillRejectsMissingEpisode() {
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .tv, segment: .intro,
            season: 1, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        XCTAssertThrowsError(try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft))
    }

    func testNoSegment_Movie_StillRejectsSeasonPresent() {
        let draft = SubmissionDraft(
            tmdbId: 1, imdbId: nil, mediaType: .movie, segment: .intro,
            season: 1, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        XCTAssertThrowsError(try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft))
    }

    func testNoSegment_RequestEncoding_UsesZeroLengthPayload() throws {
        let draft = SubmissionDraft(
            tmdbId: 42, imdbId: nil, mediaType: .movie, segment: .intro,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        let req = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft)
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["tmdb_id", "type", "segment", "start_ms", "end_ms"]))
        XCTAssertEqual(json["start_ms"] as? Int, 0)
        XCTAssertEqual(json["end_ms"] as? Int, 0)
    }

    func testNoSegment_RequestEncoding_IncludesVideoDurationWhenProvided() throws {
        let draft = SubmissionDraft(
            tmdbId: 42, imdbId: nil, mediaType: .movie, segment: .intro,
            season: nil, episode: nil, startMs: nil, endMs: nil, isNoSegment: true
        )
        let req = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft, videoDurationMs: 3_600_000)
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(json.keys), Set(["tmdb_id", "type", "segment", "start_ms", "end_ms", "video_duration_ms"]))
        XCTAssertEqual(json["video_duration_ms"] as? Int, 3_600_000)
    }
}
