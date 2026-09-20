import XCTest
@testable import IntroStamp

// Generated from Tests/segment_scenarios.csv via scripts/generate_segment_tests.swift
final class GeneratedSegmentScenarioTests: XCTestCase {
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
    func testSetDraftStart_AutoDurationMovesPlayhead_WhenSnappedToNextSegmentBoundary() {
        let model = makeModel(drafts: [.preview: [SegmentDraft(startMs: 100000, endMs: 120000)]])
        model.tmdbIdText = "1"
        model.setTemplateDurationMs(90000, for: .intro)
        model.timeline.currentTimeMs = 10000
        model.setDraftStart(.intro)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 100000)
        assertDraftExists(in: model.drafts(for: .preview), start: 100000, end: 120000)
        XCTAssertEqual(model.timeline.currentTimeMs, 100000)
    }

    @MainActor
    func testSetDraftEnd_AutoDurationMovesPlayhead_BackwardToStartFromEndMarker() {
        let model = makeModel(drafts: [.recap: [SegmentDraft(startMs: nil, endMs: 10000)]])
        model.tmdbIdText = "1"
        model.setTemplateDurationMs(90000, for: .intro)
        model.timeline.currentTimeMs = 100000
        model.setDraftEnd(.intro)
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 10000)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 100000)
        XCTAssertEqual(model.timeline.currentTimeMs, 10000)
    }

    @MainActor
    func testSetDraftEnd_AutoDurationMovesPlayhead_BackwardToStartFromEndMarker_NotBack() {
        let model = makeModel(drafts: [.recap: [SegmentDraft(startMs: nil, endMs: 10000)]])
        model.tmdbIdText = "1"
        model.setTemplateDurationMs(90000, for: .intro)
        model.timeline.currentTimeMs = 200000
        model.setDraftEnd(.intro)
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 10000)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 200000)
        XCTAssertEqual(model.timeline.currentTimeMs, 110000)
    }

    @MainActor
    func testSetDraftEnd_AutoDurationMovesPlayhead_BackwardToStartFromEndMarker_NoBackJump() {
        let model = makeModel(drafts: [.recap: [SegmentDraft(startMs: nil, endMs: 10000)]])
        model.tmdbIdText = "1"
        model.setTemplateDurationMs(90000, for: .intro)
        model.timeline.currentTimeMs = 200000
        model.setDraftEnd(.intro)
        model.timeline.currentTimeMs = 110000
        model.setDraftStart(.intro)
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 10000)
        assertDraftExists(in: model.drafts(for: .intro), start: 110000, end: 200000)
        XCTAssertEqual(model.timeline.currentTimeMs, 110000)
    }

    @MainActor
    func testSetDraftEnd_DoesNotMovePlayhead_WhenCompletingStartOpenDraft() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 100000, endMs: nil)], .intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.tmdbIdText = "1"
        model.setTemplateDurationMs(90000, for: .credits)
        model.timeline.currentTimeMs = 190000
        model.setDraftEnd(.credits)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .credits), start: 100000, end: 190000)
        XCTAssertEqual(model.timeline.currentTimeMs, 190000)
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

    @MainActor
    func testMoveNearestSegmentEndToPlayhead_WithAdjacentSegments() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 70000, endMs: 80000)], .preview: [SegmentDraft(startMs: 80000, endMs: 90000)]])
        model.timeline.currentTimeMs = 79000
        model.moveNearestSegmentEndToPlayhead()
        assertDraftExists(in: model.drafts(for: .credits), start: 70000, end: 79000)
        assertDraftExists(in: model.drafts(for: .preview), start: 79000, end: 90000)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
    }

    @MainActor
    func testMoveNearestSegmentStart_WithAdjacentSegments() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 70000, endMs: 80000)], .preview: [SegmentDraft(startMs: 80000, endMs: 90000)]])
        model.timeline.currentTimeMs = 81000
        model.moveNearestSegmentEndToPlayhead()
        assertDraftExists(in: model.drafts(for: .credits), start: 70000, end: 81000)
        assertDraftExists(in: model.drafts(for: .preview), start: 81000, end: 90000)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
    }

    @MainActor
    func testUploadableDrafts_RecapExcludesAutoRecapDrafts() {
        let model = makeModel(drafts: [.recap: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 30000, endMs: 40000)]])
        model.autoRecapDraftKeys = ["10000-20000"]
        assertDraftExists(in: model.drafts(for: .recap), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .recap), start: 30000, end: 40000)
        assertDraftExists(in: model.uploadableDrafts(for: .recap), start: 30000, end: 40000)
        XCTAssertFalse(model.uploadableDrafts(for: .recap).contains(where: { $0.startMs == 10000 && $0.endMs == 20000 }))
        XCTAssertEqual(model.uploadableDrafts(for: .recap).count, 1)
    }

    @MainActor
    func testUploadableDrafts_RecapIncludesManuallyAdjustedFormerAutoDraft() {
        let model = makeModel(drafts: [.recap: [SegmentDraft(startMs: 10500, endMs: 20500)]])
        model.autoRecapDraftKeys = ["10000-20000"]
        assertDraftExists(in: model.drafts(for: .recap), start: 10500, end: 20500)
        assertDraftExists(in: model.uploadableDrafts(for: .recap), start: 10500, end: 20500)
        XCTAssertEqual(model.uploadableDrafts(for: .recap).count, 1)
    }

    @MainActor
    func testUploadableDrafts_NonRecapDoesNotFilterByAutoRecapStatus() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 12000, endMs: 22000)]])
        model.autoRecapDraftKeys = ["12000-22000"]
        assertDraftExists(in: model.drafts(for: .intro), start: 12000, end: 22000)
        assertDraftExists(in: model.uploadableDrafts(for: .intro), start: 12000, end: 22000)
        XCTAssertEqual(model.uploadableDrafts(for: .intro).count, 1)
    }

    @MainActor
    func testAutoRecapDrafts_DropsRangesShorterThanFiveSeconds() {
        let model = makeModel(drafts: [:])
        model.localDrafts[.recap] = model.autoRecapDrafts(from: [(startMs: 0, endMs: 4999), (startMs: 20000, endMs: 27500)])
        assertDraftExists(in: model.drafts(for: .recap), start: 20000, end: 27500)
        XCTAssertFalse(model.drafts(for: .recap).contains(where: { $0.startMs == 0 && $0.endMs == 4999 }))
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
    }

    @MainActor
    func testAutoRecapDrafts_CombineConsecutiveRanges() {
        let model = makeModel(drafts: [:])
        model.localDrafts[.recap] = model.autoRecapDrafts(from: [(startMs: 0, endMs: 4000), (startMs: 5000, endMs: 10001), (startMs: 20000, endMs: 27500), (startMs: 37500, endMs: 37499)])
        assertDraftExists(in: model.drafts(for: .recap), start: nil, end: 27500)
        XCTAssertFalse(model.drafts(for: .recap).contains(where: { $0.startMs == 37500 && $0.endMs == 37499 }))
        XCTAssertEqual(model.drafts(for: .recap).count, 1)
    }

    @MainActor
    func testUploadableDrafts_RecapIntroAutoRecapDrafts() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 30000, endMs: 40000)], .recap: [SegmentDraft(startMs: 10000, endMs: 30000)]])
        model.autoRecapDraftKeys = ["10000-35000"]
        assertDraftExists(in: model.drafts(for: .recap), start: 10000, end: 30000)
        assertDraftExists(in: model.drafts(for: .intro), start: 30000, end: 40000)
        assertDraftExists(in: model.uploadableDrafts(for: .intro), start: 30000, end: 40000)
        XCTAssertFalse(model.uploadableDrafts(for: .recap).contains(where: { $0.startMs == 10000 && $0.endMs == 35000 }))
        XCTAssertEqual(model.uploadableDrafts(for: .intro).count, 1)
    }

    @MainActor
    func testJumpToNextStart_OpenStart_JumpsToZero() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: nil, endMs: 50000)]])
        model.timeline.currentTimeMs = 10000
        model.jumpToNextStart(.credits)
        XCTAssertEqual(model.timeline.currentTimeMs, 0)
    }

    @MainActor
    func testJumpToNextStart_SingleDraft_SeeksToStart() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 20000, endMs: 40000)]])
        model.timeline.currentTimeMs = 0
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 20000)
    }

    @MainActor
    func testJumpToNextStart_NoDrafts_DoesNotSeek() {
        let model = makeModel(drafts: [:])
        model.timeline.currentTimeMs = 5000
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 5000)
    }

    @MainActor
    func testJumpToNextStart_NearestFirst_PicksCloserLeft() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000), SegmentDraft(startMs: 80000, endMs: 100000)]])
        model.timeline.currentTimeMs = 15000
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 10000)
    }

    @MainActor
    func testJumpToNextStart_NearestFirst_PicksCloserRight() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000)]])
        model.timeline.currentTimeMs = 35000
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 40000)
    }

    @MainActor
    func testJumpToNextStart_Equidistant_PrefersForward() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000)]])
        model.timeline.currentTimeMs = 25000
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 40000)
    }

    @MainActor
    func testJumpToNextStart_NearestLeft_ThenBackwardRotation() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000), SegmentDraft(startMs: 80000, endMs: 100000)]])
        model.timeline.currentTimeMs = 15000
        model.jumpToNextStart(.intro)
        model.jumpToNextStart(.intro)
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 40000)
    }

    @MainActor
    func testJumpToNextStart_NearestRight_ThenForwardRotation() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000)]])
        model.timeline.currentTimeMs = 35000
        model.jumpToNextStart(.intro)
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 10000)
    }

    @MainActor
    func testJumpToNextStart_BeyondLastDraft_GoesNearest() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000)]])
        model.timeline.currentTimeMs = 50000
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 40000)
    }

    @MainActor
    func testJumpToNextStart_BeyondLastDraft_ThenBackwardRotation() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000)]])
        model.timeline.currentTimeMs = 50000
        model.jumpToNextStart(.intro)
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 10000)
    }

    @MainActor
    func testJumpToNextStart_FrameSnappedCycle_Forward() {
        let model = makeModel(drafts: [.recap: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000), SegmentDraft(startMs: 80000, endMs: 100000)]])
        model.timeline.currentTimeMs = 10017
        model.jumpToNextStart(.recap)
        model.timeline.currentTimeMs = 40017
        model.jumpToNextStart(.recap)
        model.timeline.currentTimeMs = 80017
        model.jumpToNextStart(.recap)
        XCTAssertEqual(model.timeline.currentTimeMs, 10000)
    }

    @MainActor
    func testJumpToNextStart_MultipleDrafts_ContinuesCyclesForward_MultiSegments_1() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000), SegmentDraft(startMs: 80000, endMs: 100000)], .recap: [SegmentDraft(startMs: 20000, endMs: 40000), SegmentDraft(startMs: 60000, endMs: 80000)]])
        model.timeline.currentTimeMs = 10017
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 40000)
    }

    @MainActor
    func testJumpToNextStart_MultipleDrafts_ContinuesCyclesForward_MultiSegments_2() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000), SegmentDraft(startMs: 80000, endMs: 100000)], .recap: [SegmentDraft(startMs: 20000, endMs: 40000), SegmentDraft(startMs: 60000, endMs: 80000)]])
        model.timeline.currentTimeMs = 10017
        model.jumpToNextStart(.intro)
        model.timeline.currentTimeMs = 40017
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 80000)
    }

    @MainActor
    func testJumpToNextStart_MultipleDrafts_ContinuesCyclesForward_MultiSegments_3() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000), SegmentDraft(startMs: 80000, endMs: 100000)], .recap: [SegmentDraft(startMs: 20000, endMs: 40000), SegmentDraft(startMs: 60000, endMs: 80000)]])
        model.timeline.currentTimeMs = 10017
        model.jumpToNextStart(.intro)
        model.timeline.currentTimeMs = 40017
        model.jumpToNextStart(.intro)
        model.timeline.currentTimeMs = 80017
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 10000)
    }

    @MainActor
    func testJumpToNextStart_MultipleDrafts_ContinuesCyclesForward_MultiSegments_4() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000), SegmentDraft(startMs: 80000, endMs: 100000)], .recap: [SegmentDraft(startMs: 20000, endMs: 40000), SegmentDraft(startMs: 60000, endMs: 80000)]])
        model.timeline.currentTimeMs = 10017
        model.jumpToNextStart(.intro)
        model.timeline.currentTimeMs = 40017
        model.jumpToNextStart(.intro)
        model.timeline.currentTimeMs = 80017
        model.jumpToNextStart(.intro)
        model.timeline.currentTimeMs = 10017
        model.jumpToNextStart(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 40000)
    }

    @MainActor
    func testJumpToNextEnd_SingleDraft_SeeksToEnd() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 20000, endMs: 40000)]])
        model.timeline.currentTimeMs = 0
        model.jumpToNextEnd(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 40000)
    }

    @MainActor
    func testJumpToNextEnd_OpenEnd_JumpsToEffectiveDuration() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 50000, endMs: nil)]])
        model.timeline.currentTimeMs = 0
        model.jumpToNextEnd(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 60000)
    }

    @MainActor
    func testJumpToNextEnd_NearestFirst_PicksCloserEnd() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000)]])
        model.timeline.currentTimeMs = 25000
        model.jumpToNextEnd(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 20000)
    }

    @MainActor
    func testJumpToNextEnd_OnMarker_RotatesForward() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 50000, endMs: 80000), SegmentDraft(startMs: 100000, endMs: 120000)]])
        model.timeline.currentTimeMs = 80000
        model.jumpToNextEnd(.credits)
        XCTAssertEqual(model.timeline.currentTimeMs, 120000)
    }

    @MainActor
    func testJumpToNextEnd_OnMarker_WrapsForwardToFirst() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 50000, endMs: 80000), SegmentDraft(startMs: 100000, endMs: 120000)]])
        model.timeline.currentTimeMs = 80000
        model.jumpToNextEnd(.credits)
        model.jumpToNextEnd(.credits)
        XCTAssertEqual(model.timeline.currentTimeMs, 80000)
    }

    @MainActor
    func testJumpToNextEnd_BeyondLastDraft_GoesNearest() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 50000, endMs: 80000), SegmentDraft(startMs: 100000, endMs: 120000)]])
        model.timeline.currentTimeMs = 120000
        model.jumpToNextEnd(.credits)
        XCTAssertEqual(model.timeline.currentTimeMs, 80000)
    }

    @MainActor
    func testJumpToNextEnd_FrameSnappedCycle_Forward() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000), SegmentDraft(startMs: 40000, endMs: 60000), SegmentDraft(startMs: 80000, endMs: 100000)]])
        model.timeline.currentTimeMs = 20017
        model.jumpToNextEnd(.intro)
        model.timeline.currentTimeMs = 60017
        model.jumpToNextEnd(.intro)
        model.timeline.currentTimeMs = 100017
        model.jumpToNextEnd(.intro)
        XCTAssertEqual(model.timeline.currentTimeMs, 20000)
    }

    @MainActor
    func testNudgeBoundary_ForwardByPositiveDelta_MovesNearestBoundary() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 10000
        model.nudgeNearestBoundary(by: 500)
        assertDraftExists(in: model.drafts(for: .intro), start: 10500, end: 20000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 10500)
    }

    @MainActor
    func testNudgeBoundary_BackwardByNegativeDelta_MovesNearestBoundary() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 20000
        model.nudgeNearestBoundary(by: -1000)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 19000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 19000)
    }

    @MainActor
    func testNudgeBoundary_NearEnd_MovesEndNotStart() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 19500
        model.nudgeNearestBoundary(by: 200)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20200)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 20200)
    }

    @MainActor
    func testNudgeBoundary_NearStart_MovesStartNotEnd() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 10200
        model.nudgeNearestBoundary(by: -300)
        assertDraftExists(in: model.drafts(for: .intro), start: 9700, end: 20000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 9700)
    }

    @MainActor
    func testNudgeBoundary_ClampedAtZero_DoesNotGoNegative() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 200, endMs: 20000)]])
        model.timeline.currentTimeMs = 200
        model.nudgeNearestBoundary(by: -500)
        assertDraftExists(in: model.drafts(for: .intro), start: nil, end: 20000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 0)
    }

    @MainActor
    func testNudgeBoundary_AcrossTypes_MovesNearestAcrossAllDrafts() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 30000, endMs: 50000)], .intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 29500
        model.nudgeNearestBoundary(by: 1000)
        assertDraftExists(in: model.drafts(for: .intro), start: 10000, end: 20000)
        assertDraftExists(in: model.drafts(for: .credits), start: 31000, end: 50000)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 31000)
    }

    @MainActor
    func testNudgeBoundary_SegmentsAside_MovesNearestAcrossAllDrafts() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 30000, endMs: 50000)], .recap: [SegmentDraft(startMs: 10000, endMs: 30000)]])
        model.timeline.currentTimeMs = 29500
        model.nudgeNearestBoundary(by: 1000)
        assertDraftExists(in: model.drafts(for: .recap), start: 10000, end: 31000)
        assertDraftExists(in: model.drafts(for: .intro), start: 31000, end: 50000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 31000)
    }

    @MainActor
    func testNudgeBoundary_SegmentsAside_MovesNearestAcrossAllDrafts_SHift() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 30000, endMs: 50000)], .recap: [SegmentDraft(startMs: 10000, endMs: 29000)]])
        model.timeline.currentTimeMs = 31000
        model.nudgeNearestBoundary(by: -2000)
        assertDraftExists(in: model.drafts(for: .recap), start: 10000, end: 28000)
        assertDraftExists(in: model.drafts(for: .intro), start: 28000, end: 50000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 28000)
    }

    @MainActor
    func testNudgeBoundary_SharedBoundary_ForwardClampedByAdjacentEnd() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 20000, endMs: 30000)], .preview: [SegmentDraft(startMs: 30000, endMs: 40000)]])
        model.timeline.currentTimeMs = 30000
        model.nudgeNearestBoundary(by: 20000)
        assertDraftExists(in: model.drafts(for: .credits), start: 20000, end: 50000)
        XCTAssertEqual(model.drafts(for: .credits).count, 1)
        XCTAssertEqual(model.drafts(for: .preview).count, 0)
        XCTAssertEqual(model.timeline.currentTimeMs, 50000)
    }

    @MainActor
    func testNudgeBoundary_SharedBoundary_BackwardClampedByAdjacentStart() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 20000, endMs: 30000)], .preview: [SegmentDraft(startMs: 30000, endMs: 40000)]])
        model.timeline.currentTimeMs = 30000
        model.nudgeNearestBoundary(by: -20000)
        assertDraftExists(in: model.drafts(for: .preview), start: 10000, end: 40000)
        XCTAssertEqual(model.drafts(for: .credits).count, 0)
        XCTAssertEqual(model.drafts(for: .preview).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 10000)
    }

    @MainActor
    func testNudgeBoundary_Cascade_ForwardClampedBySegmentEnd() {
        let model = makeModel(drafts: [.credits: [SegmentDraft(startMs: 20000, endMs: 30000)], .preview: [SegmentDraft(startMs: 33000, endMs: 40000)]])
        model.timeline.currentTimeMs = 30000
        model.nudgeNearestBoundary(by: 15000)
        assertDraftExists(in: model.drafts(for: .credits), start: 20000, end: 45000)
        XCTAssertEqual(model.drafts(for: .preview).count, 0)
        XCTAssertEqual(model.timeline.currentTimeMs, 45000)
    }

    @MainActor
    func testNudgeBoundary_EndCannotCrossStart_ClampsAtStart() {
        let model = makeModel(drafts: [.intro: [SegmentDraft(startMs: 10000, endMs: 20000)]])
        model.timeline.currentTimeMs = 20000
        model.nudgeNearestBoundary(by: -15000)
        assertDraftExists(in: model.drafts(for: .intro), start: 5000, end: 10000)
        XCTAssertEqual(model.drafts(for: .intro).count, 1)
        XCTAssertEqual(model.timeline.currentTimeMs, 5000)
    }

    @MainActor
    func testScenePresetInference_AnimationUsesAnimePreset() {
        let model = makeModel(drafts: [:])
        model.selectedMediaType = .movie
        model.tmdbGenreNames = ["Animation", "Adventure"]
        XCTAssertEqual(SceneDetector.Config.inferredPreset(from: model.tmdbGenreNames, mediaType: model.selectedMediaType), .anime)
    }

    @MainActor
    func testScenePresetInference_HorrorUsesDarkLiveActionPreset() {
        let model = makeModel(drafts: [:])
        model.selectedMediaType = .movie
        model.tmdbGenreNames = ["Horror", "Thriller", "Mystery"]
        XCTAssertEqual(SceneDetector.Config.inferredPreset(from: model.tmdbGenreNames, mediaType: model.selectedMediaType), .darkLiveAction)
    }

    @MainActor
    func testScenePresetInference_SportsUsesSportsPreset() {
        let model = makeModel(drafts: [:])
        model.selectedMediaType = .tv
        model.tmdbGenreNames = ["Sports", "Documentary"]
        XCTAssertEqual(SceneDetector.Config.inferredPreset(from: model.tmdbGenreNames, mediaType: model.selectedMediaType), .sports)
    }

    @MainActor
    func testSceneJump_ContinuesForwardAcrossAllTransitions() {
        let model = makeModel(drafts: [:])
        model.detectedScenes = [SceneChange(index: 1, timestampMs: 10000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 2, timestampMs: 20000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 3, timestampMs: 40000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 4, timestampMs: 80000, endTimestampMs: nil, score: 1.0, type: .hardCut)]
        model.timeline.currentTimeMs = 15000
        model.jumpToNextScene()
        model.jumpToNextScene()
        model.jumpToNextScene()
        model.jumpToNextScene()
        XCTAssertEqual(model.timeline.currentTimeMs, 10000)
        XCTAssertEqual(model.detectedScenes.count, 4)
    }

    @MainActor
    func testSceneJump_ContinuesBackwardAcrossAllTransitions() {
        let model = makeModel(drafts: [:])
        model.detectedScenes = [SceneChange(index: 1, timestampMs: 10000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 2, timestampMs: 20000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 3, timestampMs: 40000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 4, timestampMs: 80000, endTimestampMs: nil, score: 1.0, type: .hardCut)]
        model.timeline.currentTimeMs = 45000
        model.jumpToPreviousScene()
        model.jumpToPreviousScene()
        model.jumpToPreviousScene()
        model.jumpToPreviousScene()
        XCTAssertEqual(model.timeline.currentTimeMs, 80000)
        XCTAssertEqual(model.detectedScenes.count, 4)
    }

    @MainActor
    func testSceneJump_ChangesDirectionWhenShortcutChanges() {
        let model = makeModel(drafts: [:])
        model.detectedScenes = [SceneChange(index: 1, timestampMs: 10000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 2, timestampMs: 20000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 3, timestampMs: 40000, endTimestampMs: nil, score: 1.0, type: .hardCut), SceneChange(index: 4, timestampMs: 80000, endTimestampMs: nil, score: 1.0, type: .hardCut)]
        model.timeline.currentTimeMs = 45000
        model.jumpToPreviousScene()
        model.jumpToNextScene()
        XCTAssertEqual(model.timeline.currentTimeMs, 80000)
        XCTAssertEqual(model.detectedScenes.count, 4)
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