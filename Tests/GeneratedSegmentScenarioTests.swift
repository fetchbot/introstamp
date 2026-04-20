import XCTest
@testable import IntroStamp

// Generated from Tests/segment_scenarios.csv via scripts/generate_segment_tests.swift
final class GeneratedSegmentScenarioTests: XCTestCase {
    func testValidator_MakeSubmissionRequest_AllowsNilEndForCredits() throws {
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

    func testValidator_MakeSubmissionRequest_RejectsIntroWithoutEnd() throws {
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

    func testValidator_MakeSubmissionRequest_RejectsTooShortPreview() throws {
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

    func testValidator_MakeSubmissionRequest_RequiresSeasonAndEpisodeForTV() throws {
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

    @MainActor
    func testSetDraftEnd_AfterClosedSegment_CreatesRangeFromPreviousEnd() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 25000
        model.setDraftEnd(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 20000, end: 25000)
    }

    @MainActor
    func testSetDraftEnd_BeforeFirstCreditsSegment_CreatesEndOnlyDraft() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 20000, endMs: 30000)]])
        model.timeline.currentTimeMs = 5000
        model.setDraftEnd(.credits)
        assertDraftExists(in: model.drafts(for: .credits), start: nil, end: 5000)
    }

    @MainActor
    func testSetDraftEnd_WithPendingStartOnlyPreview_CompletesDraft() {
        let model = makeModel(drafts: [.preview: [SegmentDraft(startMs: 70000, endMs: nil)]])
        model.timeline.currentTimeMs = 90000
        model.setDraftEnd(.preview)
        assertDraftExists(in: model.drafts(for: .preview), start: 70000, end: 90000)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
    }

    @MainActor
    func testSetDraftEnd_InsideGap_CreatesRangeFromPreviousEnd() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 50000)]])
        model.timeline.currentTimeMs = 30000
        model.setDraftEnd(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 20000, end: 30000)
        XCTAssertFalse(model.drafts(for: .intro).contains(where: { $0.startMs == 20000 && $0.endMs == 40000 }))
    }

    @MainActor
    func testSetDraftEnd_InsideClosedSegment_TrimsToLeftSide() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 15000
        model.setDraftEnd(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 15000)
    }

    @MainActor
    func testSetDraftStart_BeforeFirstClosedSegment_CreatesRangeToNextStart() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 5000
        model.setDraftStart(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 5000, end: 10000)
    }

    @MainActor
    func testSetDraftStart_WithPendingEndOnlyRecap_CompletesDraft() {
        let model = makeModel(drafts: [.recap: [SegmentDraft(startMs: nil, endMs: 60000)]])
        model.timeline.currentTimeMs = 50000
        model.setDraftStart(.recap)
        assertDraftExists(in: model.drafts(for: .recap), start: 50000, end: 60000)
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
    }

    @MainActor
    func testSetDraftStart_InsideGap_CreatesRangeToNextStart() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 50000)]])
        model.timeline.currentTimeMs = 30000
        model.setDraftStart(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 30000, end: 40000)
        XCTAssertFalse(model.drafts(for: .intro).contains(where: { $0.startMs == 20000 && $0.endMs == 40000 }))
    }

    @MainActor
    func testSetDraftStart_InsideClosedSegment_TrimsToRightSide() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 15000
        model.setDraftStart(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 15000, end: 20000)
    }

    @MainActor
    func testHistory_UndoRedo_RestoresSingleDraftCreation() {
        let model = makeModel(drafts: [:])
        model.timeline.currentTimeMs = 12000
        model.setDraftStart(.intro)
        model.undoSegmentChange()
        model.redoSegmentChange()
        assertDraftExists(in: model.drafts(for: .intro), start: 12000, end: nil)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.canUndoSegmentChange, true)
    }

    @MainActor
    func testHistory_ReplacesOpenDraftWithClosedDraftOnSecondStart() {
        let model = makeModel(drafts: [:])
        model.timeline.currentTimeMs = 1000
        model.setDraftStart(.intro)
        model.timeline.currentTimeMs = 2000
        model.setDraftStart(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 1000, end: 2000)
        assertDraftExists(in: model.drafts(for: .intro), start: 2000, end: nil)
        XCTAssertFalse(model.drafts(for: .intro).contains(where: { $0.startMs == 1000 && $0.endMs == nil }))
        XCTAssertEqual(model.drafts(for: .intro).count, 2)
    }

    @MainActor
    func testClearDraft_RemovesOnlySelectedSegmentType() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 1000, endMs: 2000)], .preview: [SegmentDraft(startMs: 3000, endMs: 4000)]])
        model.clearDraft(.intro)
        assertDraftExists(in: model.drafts(for: .preview), start: 3000, end: 4000)
        XCTAssertTrue(model.drafts(for: .intro).isEmpty)
    }

    @MainActor
    func testMoveDraftAcrossTypes_MovesRangeToTargetType() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.moveDraft(.intro, index: 0, to: .recap, startMs: 12000, endMs: 22000)
        assertDraftExists(in: model.drafts(for: .recap), start: 12000, end: 22000)
        XCTAssertTrue(model.drafts(for: .intro).isEmpty)
    }

    @MainActor
    func testSetDraftRange_RejectsOverlapAcrossSegmentTypes() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.setDraftRange(.recap, startMs: 15000, endMs: 18000)
        XCTAssertTrue(model.drafts(for: .recap).isEmpty)
        XCTAssertFalse(model.errorMessage.isEmpty)
    }

    @MainActor
    func testSetDraftStart_InsideOtherTypeSegment_ShiftsRecapStartToBoundary() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 30000)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftStart(.recap)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 30000)
        assertDraftExists(in: model.drafts(for: .recap), start: 30000, end: nil)
    }

    @MainActor
    func testSetDraftStart_BetweenOtherTypeSegments_CreatesClosedCreditsGap() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 30000)], .preview: [SegmentDraft(startMs: 40000, endMs: 50000)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftStart(.credits)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 30000)
        assertDraftExists(in: model.drafts(for: .credits), start: 30000, end: 40000)
        assertDraftExists(in: model.drafts(for: .preview), start: 40000, end: 50000)
    }

    @MainActor
    func testSetDraftStart_BeforeExistingPreview_CreatesPreviewGapRange() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 30000)], .preview: [SegmentDraft(startMs: 40000, endMs: 50000)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftStart(.preview)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 30000)
        assertDraftExists(in: model.drafts(for: .preview), start: 30000, end: 40000)
        assertDraftExists(in: model.drafts(for: .preview), start: 40000, end: 50000)
    }

    @MainActor
    func testSetDraftEnd_InsideFirstOfAdjacentPreviewSegments_TrimsActiveSegment() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 30000)], .preview: [SegmentDraft(startMs: 30000, endMs: 40000), SegmentDraft(startMs: 40000, endMs: 50000)]])
        model.timeline.currentTimeMs = 35000
        model.setDraftEnd(.preview)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 30000)
        assertDraftExists(in: model.drafts(for: .preview), start: 30000, end: 35000)
        assertDraftExists(in: model.drafts(for: .preview), start: 40000, end: 50000)
    }

    @MainActor
    func testMultiSegment_SetDraftStart_CapsCreditsToNearestNextSegment() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 30000)], .preview: [SegmentDraft(startMs: 40000, endMs: 50000)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftStart(.credits)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 30000)
        assertDraftExists(in: model.drafts(for: .credits), start: 30000, end: 40000)
        assertDraftExists(in: model.drafts(for: .preview), start: 40000, end: 50000)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
    }

    @MainActor
    func testMultiSegment_SetDraftEnd_FloorsCreditsFromNearestPreviousSegment() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)], .preview: [SegmentDraft(startMs: 40000, endMs: 50000)], .recap: [SegmentDraft(startMs: 25000, endMs: 30000)]])
        model.timeline.currentTimeMs = 35000
        model.setDraftEnd(.credits)
        assertDraftExists(in: model.drafts(for: .credits), start: 30000, end: 35000)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .recap), start: 25000, end: 30000)
        assertDraftExists(in: model.drafts(for: .preview), start: 40000, end: 50000)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
    }

    @MainActor
    func testMultiSegment_UndoRedo_RestoresCrossTypeMove() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)], .preview: [SegmentDraft(startMs: 40000, endMs: 50000)]])
        model.moveDraft(.intro, index: 0, to: .recap, startMs: 12000, endMs: 22000)
        model.undoSegmentChange()
        model.redoSegmentChange()
        assertDraftExists(in: model.drafts(for: .recap), start: 12000, end: 22000)
        assertDraftExists(in: model.drafts(for: .preview), start: 40000, end: 50000)
        XCTAssertTrue(model.drafts(for: .intro).isEmpty)
        XCTAssertEqual(model.canUndoSegmentChange, true)
    }

    @MainActor
    func testMultiSegment_SetDraftRange_RejectsOverlapInDenseTimeline() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 26000, endMs: 30000)], .preview: [SegmentDraft(startMs: 32000, endMs: 38000)]])
        model.setDraftRange(.credits, startMs: 27000, endMs: 29000)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .intro), start: 26000, end: 30000)
        assertDraftExists(in: model.drafts(for: .preview), start: 32000, end: 38000)
        XCTAssertTrue(model.drafts(for: .credits).isEmpty)
        XCTAssertFalse(model.errorMessage.isEmpty)
    }

    @MainActor
    func testMultiSegment_ClearDraft_PreservesOtherTypesAndRanges() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 1000, endMs: 2000), SegmentDraft(startMs: 3000, endMs: 3500)], .preview: [SegmentDraft(startMs: 9000, endMs: 10000)], .recap: [SegmentDraft(startMs: 6000, endMs: 7000)]])
        model.clearDraft(.intro)
        assertDraftExists(in: model.drafts(for: .recap), start: 6000, end: 7000)
        assertDraftExists(in: model.drafts(for: .preview), start: 9000, end: 10000)
        XCTAssertTrue(model.drafts(for: .intro).isEmpty)
    }

    @MainActor
    func testMultiSegment_UndoAfterClearDraft_RestoresAllRemovedIntroRanges() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 8000, endMs: 9000)], .intro: [SegmentDraft(startMs: 1000, endMs: 2000), SegmentDraft(startMs: 3000, endMs: 3500)]])
        model.clearDraft(.intro)
        model.undoSegmentChange()
        assertDraftExists(in: model.drafts(for: .intro), start: 1000, end: 2000)
        assertDraftExists(in: model.drafts(for: .intro), start: 3000, end: 3500)
        assertDraftExists(in: model.drafts(for: .credits), start: 8000, end: 9000)
        XCTAssertEqual(model.drafts(for: .intro).count, 2)
    }

    @MainActor
    func testMultiSegment_RedoAfterUndo_ReappliesClearedIntroRanges() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 8000, endMs: 9000)], .intro: [SegmentDraft(startMs: 1000, endMs: 2000), SegmentDraft(startMs: 3000, endMs: 3500)]])
        model.clearDraft(.intro)
        model.undoSegmentChange()
        model.redoSegmentChange()
        assertDraftExists(in: model.drafts(for: .credits), start: 8000, end: 9000)
        XCTAssertTrue(model.drafts(for: .intro).isEmpty)
        XCTAssertEqual(model.canRedoSegmentChange, false)
    }

    @MainActor
    func testChainedRecapThenPreviewEnd_CreatesNonOverlappingPreviewEndOnly() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 30000)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftStart(.recap)
        model.timeline.currentTimeMs = 40000
        model.setDraftEnd(.recap)
        model.timeline.currentTimeMs = 35000
        model.setDraftEnd(.preview)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 30000)
        assertDraftExists(in: model.drafts(for: .recap), start: 30000, end: 40000)
        assertDraftExists(in: model.drafts(for: .preview), start: nil, end: 10000)
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
    }

    @MainActor
    func testSetDraftStart_PreviewWithPendingEndAndOpenCredits_KeepsExistingDrafts() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 60000, endMs: nil)], .preview: [SegmentDraft(startMs: nil, endMs: 30000)]])
        model.timeline.currentTimeMs = 70000
        model.setDraftStart(.preview)
        assertDraftExists(in: model.drafts(for: .preview), start: nil, end: 30000)
        assertDraftExists(in: model.drafts(for: .credits), start: 60000, end: nil)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
    }

    @MainActor
    func testSetDraftStart_IntroBetweenPendingPreviewEndAndOpenCredits_CreatesBoundedRange() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 60000, endMs: nil)], .preview: [SegmentDraft(startMs: nil, endMs: 30000)]])
        model.timeline.currentTimeMs = 50000
        model.setDraftStart(.intro)
        assertDraftExists(in: model.drafts(for: .preview), start: nil, end: 30000)
        assertDraftExists(in: model.drafts(for: .intro), start: 50000, end: 60000)
        assertDraftExists(in: model.drafts(for: .credits), start: 60000, end: nil)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
    }

    @MainActor
    func testSetDraftStart_IntroThenPreview_CreatesNonOverlappingRanges() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: nil)]])
        model.timeline.currentTimeMs = 30000
        model.setDraftStart(.intro)
        model.timeline.currentTimeMs = 50000
        model.setDraftStart(.preview)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 30000)
        assertDraftExists(in: model.drafts(for: .intro), start: 30000, end: 50000)
        assertDraftExists(in: model.drafts(for: .preview), start: 50000, end: nil)
        XCTAssertEqual(model.drafts(for: .intro).count, 2)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
    }

    @MainActor
    func testMergeDrafts() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 30000, endMs: 40000)]])
        model.timeline.currentTimeMs = 15000
        model.setDraftStart(.recap)
        model.setDraftEnd(.recap)
        assertDraftExists(in: model.drafts(for: .intro), start: 30000, end: 40000)
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 30000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
    }

    @MainActor
    func testNonMergeDrafts() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 30000, endMs: 40000)]])
        model.timeline.currentTimeMs = 15000
        model.setDraftStart(.recap)
        model.setDraftEnd(.credits)
        assertDraftExists(in: model.drafts(for: .intro), start: 30000, end: 40000)
        assertDraftExists(in: model.drafts(for: .recap), start: 15000, end: 30000)
        assertDraftExists(in: model.drafts(for: .credits), start: nil, end: 15000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
    }

    @MainActor
    func testOpenNewDraft() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 50000, endMs: 70000)], .intro: [SegmentDraft(startMs: 30000, endMs: 40000)], .preview: [SegmentDraft(startMs: nil, endMs: 30000)]])
        model.timeline.currentTimeMs = 35000
        model.setDraftStart(.preview)
        assertDraftExists(in: model.drafts(for: .preview), start: nil, end: 30000)
        assertDraftExists(in: model.drafts(for: .intro), start: 30000, end: 40000)
        assertDraftExists(in: model.drafts(for: .preview), start: 40000, end: 50000)
        assertDraftExists(in: model.drafts(for: .credits), start: 50000, end: 70000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.drafts(for: .preview).count, 2)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
    }

    @MainActor
    func testSetDraftEnd_WithPendingStartAndEarlierPlayhead_NormalizesRange() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: nil)]])
        model.timeline.currentTimeMs = 5000
        model.setDraftEnd(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: nil, end: 5000)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: nil)
        XCTAssertEqual(model.drafts(for: .intro).count, 2)
    }

    @MainActor
    func testSetDraftStart_WithPendingEndAndLaterPlayhead_KeepsEndOnlyDraft() {
        let model = makeModel(drafts: [.recap: [SegmentDraft(startMs: nil, endMs: 30000)]])
        model.timeline.currentTimeMs = 35000
        model.setDraftStart(.recap)
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 30000)
        assertDraftExists(in: model.drafts(for: .recap), start: 35000, end: nil)
        XCTAssertEqual(model.drafts(for: .recap).count, 2)
    }

    @MainActor
    func testSetDraftRange_AdjacentToExistingAcrossTypes_AllowsTouchingBoundary() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.setDraftRange(.recap, startMs: 20000, endMs: 25000)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .recap), start: 20000, end: 25000)
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
    }

    @MainActor
    func testSetDraftEnd_AtExistingStart_CreatesEndOnlyToBoundary() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 10000
        model.setDraftEnd(.credits)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .credits), start: nil, end: 10000)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
    }

    @MainActor
    func testSetDraftStart_AtExistingEnd_CreatesOpenDraftFromBoundary() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftStart(.preview)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .preview), start: 20000, end: nil)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
    }

    @MainActor
    func testHistory_NewActionAfterUndo_ClearsRedoStack() {
        let model = makeModel(drafts: [:])
        model.timeline.currentTimeMs = 1000
        model.setDraftStart(.intro)
        model.undoSegmentChange()
        model.timeline.currentTimeMs = 2000
        model.setDraftStart(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 2000, end: nil)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.canUndoSegmentChange, true)
        XCTAssertEqual(model.canRedoSegmentChange, false)
    }

    @MainActor
    func testHistory_RejectedChange_DoesNotCreateUndoEntry() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.setDraftRange(.recap, startMs: 15000, endMs: 18000)
        XCTAssertTrue(model.drafts(for: .recap).isEmpty)
        XCTAssertFalse(model.errorMessage.isEmpty)
        XCTAssertEqual(model.canUndoSegmentChange, false)
    }

    @MainActor
    func testEndDraftEdge() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: nil)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftEnd(.intro)
        model.setDraftEnd(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
    }

    @MainActor
    func testEndDraftEdgeToRecap() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: nil)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftEnd(.intro)
        model.setDraftEnd(.recap)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 10000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
    }

    @MainActor
    func testEndDraftEdgeToPreview() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: nil)]])
        model.timeline.currentTimeMs = 20000
        model.setDraftEnd(.intro)
        model.setDraftEnd(.recap)
        model.setDraftEnd(.preview)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 10000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
        XCTAssertTrue(model.drafts(for: .preview).isEmpty)
    }

    @MainActor
    func testMultiOpenNewDraft() {
        let model = makeModel(drafts: [:])
        model.timeline.currentTimeMs = 35000
        model.setDraftStart(.intro)
        model.setDraftStart(.preview)
        assertDraftExists(in: model.drafts(for: .intro), start: 35000, end: nil)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertTrue(model.drafts(for: .preview).isEmpty)
    }

    @MainActor
    func testOpenCloseNewDraft() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 70000, endMs: nil)], .intro: [SegmentDraft(startMs: 20000, endMs: 40000)], .recap: [SegmentDraft(startMs: nil, endMs: 10000)]])
        model.timeline.currentTimeMs = 80000
        model.setDraftStart(.preview)
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 10000)
        assertDraftExists(in: model.drafts(for: .intro), start: 20000, end: 40000)
        assertDraftExists(in: model.drafts(for: .credits), start: 70000, end: 80000)
        assertDraftExists(in: model.drafts(for: .preview), start: 80000, end: nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeModel(drafts: [SegmentType: [SegmentDraft]]) -> AppModel {
        let model = AppModel()
        for (segment, segmentDrafts) in drafts {
            model.localDrafts[segment] = segmentDrafts
        }
        return model
    }

    private func assertDraftExists(in drafts: [SegmentDraft], start: Int?, end: Int?) {
        XCTAssertTrue(drafts.contains(where: { $0.startMs == start && $0.endMs == end }))
    }
}