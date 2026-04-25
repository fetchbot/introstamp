import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    private typealias SegmentDraftSnapshot = [SegmentType: [SegmentDraft]]

    enum SegmentService: String {
        case theIntroDB = "TheIntroDB"
        case introDB = "IntroDB"
    }

    var theIntroDBAPIKey: String = ""
    var introDBAPIKey: String = ""
    var tmdbAPIKey: String = ""

    var selectedVideoURL: URL?
    var videoTitle: String = "No video selected"

    var tmdbIdText: String = ""
    var imdbIdText: String = ""
    var selectedMediaType: MediaType = .movie
    var seasonText: String = ""
    var episodeText: String = ""

    var autoLookupMessage: String = ""
    var infoMessage: String = ""
    var errorMessage: String = ""
    var usageMessage: String = ""
    var matchedPosterURL: URL?
    var autoLookupCandidates: [AutoLookupResult] = []
    var selectedAutoLookupTMDBID: Int?

    var isFetchingMedia = false
    var uploadingSegment: SegmentType?
    var isUploadingAll = false
    var zoomLevel: Double = 1.0
    var tmdbSearchText = ""
    var isTMDBSearching = false
    var tmdbSearchResults: [AutoLookupResult] = []
    var minimumZoomLevel: Double = 1.0
    var playerFocusRequestID: Int = 0
    var videoLoadID: Int = 0
    var frameStripFineModeToken: Int = 0

    var serverSegments: [SegmentType: [SegmentRange]] = AppModel.makeSegmentDictionary(defaultValue: []) {
        didSet { invalidateEffectiveDurationCache() }
    }
    var localDrafts: [SegmentType: [SegmentDraft]] = AppModel.makeSegmentDictionary(defaultValue: []) {
        didSet { invalidateEffectiveDurationCache() }
    }
    var submissionMessages: [SegmentType: String] = AppModel.makeSegmentDictionary(defaultValue: "")

    var audioWaveformTrack: TimelineDensityTrack {
        TimelineDensityTrack(
            label: "Audio",
            buckets: timeline.waveformBuckets,
            musicLikelihoodBuckets: timeline.musicLikelihoodBuckets
        )
    }

    let timeline: PlayerTimelineEngine

    private let keychain: KeychainStore
    private let shouldAccessKeychain: Bool
    private let theIntroDBClient: TheIntroDBClient
    private let introDBClient: IntroDBClient
    private let tmdbClient: TMDBClient
    private var shouldAutoFitZoomAfterLoad = true
    private var cachedEffectiveDurationMs: Int?
    private var cachedTimelineDurationMs: Int?
    private var segmentDurationTemplatesMs: [String: Int] = [:]
    private let fallbackUndoManager = UndoManager()
    private var segmentChangeCaptureDepth = 0
    private var batchedSegmentChangeDepth = 0
    private var batchedSegmentChangeSnapshot: SegmentDraftSnapshot?
    private var isApplyingHistoryChange = false
    private let durationTemplateDefaultsKey = "segment_duration_templates_ms_v1"
    private var pendingAutoDetectFetchTask: Task<Void, Never>?

    init(
        timeline: PlayerTimelineEngine = PlayerTimelineEngine(),
        keychain: KeychainStore = KeychainStore(),
        theIntroDBClient: TheIntroDBClient = TheIntroDBClient(),
        introDBClient: IntroDBClient = IntroDBClient(),
        tmdbClient: TMDBClient = TMDBClient(),
        shouldAccessKeychain: Bool = !ProcessInfo.processInfo.isRunningTests
    ) {
        self.timeline = timeline
        self.keychain = keychain
        self.shouldAccessKeychain = shouldAccessKeychain
        self.theIntroDBClient = theIntroDBClient
        self.introDBClient = introDBClient
        self.tmdbClient = tmdbClient

        if shouldAccessKeychain {
            tryLoadKeysFromKeychain(allowUserInteraction: false, announceOutcome: false)
        }
        segmentDurationTemplatesMs = loadDurationTemplatesFromDefaults()
    }

    var areAPIKeyFieldsEmpty: Bool {
        theIntroDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && introDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadKeysFromKeychain() {
        tryLoadKeysFromKeychain(allowUserInteraction: true, announceOutcome: true)
    }

    var effectiveDurationMs: Int {
        if let cached = cachedEffectiveDurationMs,
           cachedTimelineDurationMs == timeline.durationMs {
            return cached
        }

        let serverMax = serverSegments.values
            .flatMap { $0 }
            .compactMap { $0.endMs ?? $0.startMs }
            .max() ?? 0

        let draftMax = localDrafts.values
            .flatMap { $0 }
            .compactMap { $0.endMs ?? $0.startMs }
            .max() ?? 0

        let resolved = max(timeline.durationMs, serverMax, draftMax, 60_000)
        cachedEffectiveDurationMs = resolved
        cachedTimelineDurationMs = timeline.durationMs
        return resolved
    }

    func draft(for segment: SegmentType) -> SegmentDraft {
        localDrafts[segment]?.last ?? .empty
    }

    func drafts(for segment: SegmentType) -> [SegmentDraft] {
        localDrafts[segment] ?? []
    }

    func templateDurationMs(for segment: SegmentType) -> Int? {
        suggestedDurationTemplateMs(for: segment)
    }

    var canUndoSegmentChange: Bool {
        activeUndoManager.canUndo
    }

    var canRedoSegmentChange: Bool {
        activeUndoManager.canRedo
    }

    func undoSegmentChange() {
        guard activeUndoManager.canUndo else { return }
        activeUndoManager.undo()
        errorMessage = ""
    }

    func redoSegmentChange() {
        guard activeUndoManager.canRedo else { return }
        activeUndoManager.redo()
        errorMessage = ""
    }

    func beginSegmentDragChange() {
        if batchedSegmentChangeDepth == 0 {
            batchedSegmentChangeSnapshot = localDrafts
        }
        batchedSegmentChangeDepth += 1
    }

    func endSegmentDragChange() {
        guard batchedSegmentChangeDepth > 0 else { return }
        batchedSegmentChangeDepth -= 1

        guard batchedSegmentChangeDepth == 0 else { return }
        guard let snapshot = batchedSegmentChangeSnapshot else { return }
        batchedSegmentChangeSnapshot = nil

        guard !isApplyingHistoryChange else { return }
        guard localDrafts != snapshot else { return }

        registerUndo(from: snapshot, to: localDrafts)
    }

    func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            .avi
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            loadVideo(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.requestPlayerFocus()
            }
        }
    }

    func loadVideo(url: URL) {
        pendingAutoDetectFetchTask?.cancel()
        selectedVideoURL = url
        videoTitle = url.lastPathComponent
        matchedPosterURL = nil
        autoLookupCandidates = []
        selectedAutoLookupTMDBID = nil
        shouldAutoFitZoomAfterLoad = true
        zoomLevel = minimumZoomLevel
        timeline.loadVideo(url: url)
        videoLoadID &+= 1
        serverSegments = AppModel.makeSegmentDictionary(defaultValue: [])
        localDrafts = AppModel.makeSegmentDictionary(defaultValue: [])
        resetSegmentHistory()
        infoMessage = "Loaded \(url.lastPathComponent)"
        errorMessage = ""
        requestPlayerFocus()

        let parsed = FilenameMediaParser.parse(url: url)
        selectedMediaType = parsed.mediaTypeHint
        if let season = parsed.season { seasonText = String(season) }
        if let episode = parsed.episode { episodeText = String(episode) }

        let currentVideoLoadID = videoLoadID
        pendingAutoDetectFetchTask = Task { [weak self] in
            guard let self else { return }
            let matched = await self.autoDetectMediaID(for: url)
            guard !Task.isCancelled, self.videoLoadID == currentVideoLoadID else { return }
            if matched {
                await self.fetchMedia(prefillDrafts: true)
            }
        }
    }

    func searchTMDB() async {
        let query = tmdbSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard !tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "TMDB API key missing"
            return
        }
        isTMDBSearching = true
        tmdbSearchResults = []
        defer { isTMDBSearching = false }
        do {
            let results = try await tmdbClient.search(
                title: query,
                mediaType: selectedMediaType,
                apiKey: tmdbAPIKey,
                limit: 10)
            tmdbSearchResults = results
            if tmdbSearchResults.isEmpty {
                errorMessage = "No TMDB results for \"\(query)\""
            }
        } catch {
            errorMessage = "TMDB search failed: \(error.localizedDescription)"
        }
    }

    func selectTMDBSearchResult(_ result: AutoLookupResult) {
        applyAutoLookupCandidate(result)
        autoLookupMessage = "Selected: \(result.title) (TMDB \(result.tmdbId))"
        tmdbSearchResults = []
        tmdbSearchText = ""
    }

    func autoDetectMediaID(for url: URL) async -> Bool {
        autoLookupMessage = "Parsing filename…"
        autoLookupCandidates = []
        selectedAutoLookupTMDBID = nil
        let hint = FilenameMediaParser.parse(url: url)

        if hint.title.isEmpty {
            autoLookupMessage = "Could not extract title from filename"
            matchedPosterURL = nil
            return false
        }

        if tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            autoLookupMessage = "TMDB key missing; use manual TMDB/IMDB input"
            matchedPosterURL = nil
            return false
        }

        do {
            let results = try await tmdbClient.resolveHints(hint, apiKey: tmdbAPIKey, limit: 6)
            guard !results.isEmpty else {
                autoLookupMessage = "No TMDB match found for \(hint.title)"
                matchedPosterURL = nil
                return false
            }

            autoLookupCandidates = results
            let first = results[0]
            applyAutoLookupCandidate(first)

            if results.count == 1 {
                autoLookupMessage = "Matched: \(first.title) (TMDB \(first.tmdbId))"
                return true
            }

            autoLookupMessage = "Multiple TMDB matches found. Using first result: \(first.title) (TMDB \(first.tmdbId))."
            return true
        } catch {
            autoLookupMessage = "Auto lookup failed: \(error.localizedDescription)"
            matchedPosterURL = nil
            autoLookupCandidates = []
            selectedAutoLookupTMDBID = nil
            return false
        }
    }

    func selectAutoLookupCandidate(tmdbId: Int) {
        guard let candidate = autoLookupCandidates.first(where: { $0.tmdbId == tmdbId }) else { return }
        applyAutoLookupCandidate(candidate)
        autoLookupMessage = "Selected: \(candidate.title) (TMDB \(candidate.tmdbId))"
    }

    private func applyAutoLookupCandidate(_ candidate: AutoLookupResult) {
        selectedAutoLookupTMDBID = candidate.tmdbId
        tmdbIdText = String(candidate.tmdbId)
        if let imdbId = candidate.imdbId {
            imdbIdText = imdbId
        }
        selectedMediaType = candidate.mediaType
        seasonText = candidate.season.map(String.init) ?? seasonText
        episodeText = candidate.episode.map(String.init) ?? episodeText
        matchedPosterURL = candidate.posterURL
    }

    func saveKeysToKeychain() {
        guard shouldAccessKeychain else { return }
        let theIntroOk = keychain.set(theIntroDBAPIKey, for: .theIntroDBAPIKey)
        let introOk = keychain.set(introDBAPIKey, for: .introDBAPIKey)
        let tmdbOk = keychain.set(tmdbAPIKey, for: .tmdbAPIKey)

        if theIntroOk && introOk && tmdbOk {
            infoMessage = "API keys saved to Keychain"
            errorMessage = ""
        } else {
            errorMessage = "Could not save one or more API keys to Keychain"
        }
    }

    private func tryLoadKeysFromKeychain(allowUserInteraction: Bool, announceOutcome: Bool) {
        guard shouldAccessKeychain else { return }
        let theIntro = keychain.get(.theIntroDBAPIKey, allowUserInteraction: allowUserInteraction)
        let intro = keychain.get(.introDBAPIKey, allowUserInteraction: allowUserInteraction)
        let tmdb = keychain.get(.tmdbAPIKey, allowUserInteraction: allowUserInteraction)

        var loadedCount = 0
        if let theIntro {
            theIntroDBAPIKey = theIntro
            loadedCount += 1
        }
        if let intro {
            introDBAPIKey = intro
            loadedCount += 1
        }
        if let tmdb {
            tmdbAPIKey = tmdb
            loadedCount += 1
        }

        guard announceOutcome else { return }
        if loadedCount > 0 {
            infoMessage = "Loaded \(loadedCount) API key(s) from Keychain"
            errorMessage = ""
        } else {
            infoMessage = ""
            errorMessage = "No API keys found in Keychain"
        }
    }

    func fetchMedia(prefillDrafts: Bool = false) async {
        errorMessage = ""
        infoMessage = ""
        usageMessage = ""
        isFetchingMedia = true
        defer { isFetchingMedia = false }

        let query = makeMediaQuery()

        guard query.tmdbId != nil || query.imdbId != nil else {
            errorMessage = "Please provide TMDB ID or IMDB ID"
            return
        }

        let theIntroKey = optional(theIntroDBAPIKey)
        let introKey = optional(introDBAPIKey)
        let canUseTheIntro = query.tmdbId != nil || query.imdbId != nil
        let canUseIntroDB = canUseIntroDB(query: query)

        if !canUseTheIntro && !canUseIntroDB {
            errorMessage = "Provided identifiers are not compatible with available APIs"
            return
        }

        var successByService: [SegmentService: (segments: [SegmentType: [SegmentRange]], normalizedTMDBID: Int?, usage: UsageHeaders?)] = [:]
        var errorsByService: [SegmentService: Error] = [:]

        await withTaskGroup(of: (SegmentService, Result<(segments: [SegmentType: [SegmentRange]], normalizedTMDBID: Int?, usage: UsageHeaders?), Error>).self) { group in
            if canUseTheIntro {
                group.addTask {
                    do {
                        let response = try await self.theIntroDBClient.fetchMedia(query: query, apiKey: theIntroKey)
                        let payload = response.payload
                        return (
                            .theIntroDB,
                            .success((
                                segments: payload.groupedSegments(),
                                normalizedTMDBID: payload.tmdbId,
                                usage: response.usage
                            ))
                        )
                    } catch {
                        return (.theIntroDB, .failure(error))
                    }
                }
            }

            if canUseIntroDB {
                group.addTask {
                    do {
                        guard let imdbId = query.imdbId,
                              let season = query.season,
                              let episode = query.episode
                        else {
                            throw SegmentValidationError.message("IMDB ID, season, and episode are required for IntroDB fetch")
                        }

                        let response = try await self.introDBClient.fetchSegments(
                            imdbId: imdbId,
                            season: season,
                            episode: episode,
                            apiKey: introKey
                        )

                        return (
                            .introDB,
                            .success((
                                segments: response.payload.groupedSegments(),
                                normalizedTMDBID: nil,
                                usage: response.usage
                            ))
                        )
                    } catch {
                        return (.introDB, .failure(error))
                    }
                }
            }

            for await (service, result) in group {
                switch result {
                case .success(let payload):
                    successByService[service] = payload
                case .failure(let error):
                    errorsByService[service] = error
                }
            }
        }

        let emptySegments: [SegmentType: [SegmentRange]] = AppModel.makeSegmentDictionary(defaultValue: [])
        let theIntroSegments = successByService[.theIntroDB]?.segments ?? emptySegments
        let introSegments = successByService[.introDB]?.segments ?? emptySegments
        var mergedSegments: [SegmentType: [SegmentRange]] = emptySegments

        for segment in SegmentType.allCases {
            let primary = theIntroSegments[segment] ?? []
            let fallback = introSegments[segment] ?? []
            mergedSegments[segment] = primary.isEmpty ? fallback : primary
        }

        if successByService.isEmpty {
            let allErrorsAre404 = !errorsByService.isEmpty && errorsByService.values.allSatisfy {
                ($0 as? APIClientError)?.statusCode == 404
            }
            if allErrorsAre404 {
                serverSegments = AppModel.makeSegmentDictionary(defaultValue: [])
                infoMessage = "No data found yet. You can create new segments and submit."
                return
            }

            if let firstError = errorsByService[.theIntroDB] ?? errorsByService[.introDB] {
                if let apiError = firstError as? APIClientError {
                    usageMessage = apiError.usage?.shortDescription ?? ""
                    errorMessage = "Fetch failed (\(apiError.statusCode ?? 0)): \(apiError.message)"
                } else {
                    errorMessage = "Fetch failed: \(firstError.localizedDescription)"
                }
                return
            }

            serverSegments = AppModel.makeSegmentDictionary(defaultValue: [])
            errorMessage = "Fetch failed: no compatible API endpoint could be called"
            return
        }

        if let normalizedTMDBID = successByService[.theIntroDB]?.normalizedTMDBID {
            tmdbIdText = String(normalizedTMDBID)
        }
        if selectedMediaType == .tv {
            seasonText = query.season.map(String.init) ?? seasonText
            episodeText = query.episode.map(String.init) ?? episodeText
        }

        serverSegments = mergedSegments
        if prefillDrafts {
            prefillDraftsFromServerSegments()
        }

        var usageChunks: [String] = []
        if let usage = successByService[.theIntroDB]?.usage?.shortDescription, !usage.isEmpty {
            usageChunks.append("TheIntroDB: \(usage)")
        }
        if let usage = successByService[.introDB]?.usage?.shortDescription, !usage.isEmpty {
            usageChunks.append("IntroDB: \(usage)")
        }
        usageMessage = usageChunks.joined(separator: " | ")

        if successByService[.theIntroDB] != nil && successByService[.introDB] != nil {
            infoMessage = "Loaded segments from TheIntroDB with IntroDB fallback"
        } else if successByService[.theIntroDB] != nil {
            infoMessage = "Loaded segments from TheIntroDB"
        } else {
            infoMessage = "Loaded segments from IntroDB"
        }
    }

    func setDraftStart(_ segment: SegmentType) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }
        let playheadMs = max(0, min(timeline.currentTimeMs, SegmentValidator.maxTimestampMs))

        if !hasPendingEndOnlyDraft(in: segment), let pending = latestPendingStartOnlyDraft(excluding: segment) {
            var pendingDrafts = drafts(for: pending.segment)
            if let startMs = pendingDrafts[pending.index].startMs {
                if playheadMs == startMs {
                    // Keep a single open start-only draft when no forward movement happened.
                    errorMessage = ""
                    return
                }

                if playheadMs > startMs {
                    let normalized = normalizeRange(startMs: startMs, endMs: playheadMs)
                    if let adjusted = adjustedNonOverlappingRange(
                        candidate: normalized,
                        excluding: (pending.segment, pending.index)
                    ) {
                        pendingDrafts[pending.index] = SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs)
                        localDrafts[pending.segment] = normalizeAndSortDraftsByStart(pendingDrafts)
                    }
                }
            }
        }

        var drafts = drafts(for: segment)

        if let pendingIndex = drafts.lastIndex(where: { $0.startMs == nil && $0.endMs != nil }),
           let endMs = drafts[pendingIndex].endMs
        {
            if playheadMs < endMs {
                let normalized = normalizeRange(startMs: playheadMs, endMs: endMs)
                if let adjusted = adjustedNonOverlappingRange(
                    candidate: normalized,
                    excluding: (segment, pendingIndex)
                ) {
                    drafts[pendingIndex] = SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs)
                    localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                    errorMessage = ""
                } else {
                    drafts.remove(at: pendingIndex)
                    localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                    errorMessage = "\(segment.displayName) segment could not be placed without overlapping an existing segment"
                }
                return
            }

            if hasPendingStartOnlyDraft(excluding: segment) {
                // Preserve existing pending drafts when another segment already has an open start marker.
                errorMessage = ""
                return
            }

            // Keep end-only as-is and continue with regular creation rules.
            errorMessage = ""
        }

        if let pendingIndex = drafts.lastIndex(where: { $0.startMs != nil && $0.endMs == nil }),
           let startMs = drafts[pendingIndex].startMs
        {
            let normalized = normalizeRange(startMs: startMs, endMs: playheadMs)
            if let adjusted = adjustedNonOverlappingRange(
                candidate: normalized,
                excluding: (segment, pendingIndex)
            ) {
                drafts[pendingIndex] = SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs)
                let nextStartMs = nonOverlappingStartMs(adjusted.endMs)
                drafts.append(SegmentDraft(startMs: nextStartMs, endMs: nil))
                localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                errorMessage = ""
            } else {
                errorMessage = "\(segment.displayName) segment could not be placed without overlapping an existing segment"
            }
            return
        }

        if let containingIndex = drafts.lastIndex(where: {
            guard let startMs = $0.startMs, let endMs = $0.endMs else { return false }
            return playheadMs > startMs && playheadMs < endMs
        }) {
            drafts[containingIndex].startMs = playheadMs
            localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
            errorMessage = ""
            return
        }

        if let containingInterval = containingClosedInterval(at: playheadMs) {
            let boundaryStart = containingInterval.endMs
            if let nextStart = nearestClosedStart(atOrAfter: boundaryStart), boundaryStart < nextStart {
                let candidate = normalizeRange(startMs: boundaryStart, endMs: nextStart)
                if let adjusted = adjustedNonOverlappingRange(candidate: candidate, excluding: nil) {
                    drafts.append(SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs))
                    localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                    errorMessage = ""
                    return
                }
            }

            let startMs = nonOverlappingStartMs(boundaryStart)
            drafts.append(SegmentDraft(startMs: startMs, endMs: nil))
            localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
            errorMessage = ""
            return
        }

        if !isInsideClosedInterval(playheadMs),
           let nextStart = nearestClosedStart(atOrAfter: playheadMs),
           playheadMs < nextStart
        {
            let candidate = normalizeRange(startMs: playheadMs, endMs: nextStart)
            if let adjusted = adjustedNonOverlappingRange(candidate: candidate, excluding: nil) {
                drafts.append(SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs))
                localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                errorMessage = ""
                return
            }
        }

        if let nextStartMarker = nearestDraftStartMarker(atOrAfter: playheadMs),
           playheadMs < nextStartMarker
        {
            let candidate = normalizeRange(startMs: playheadMs, endMs: nextStartMarker)
            if let adjusted = adjustedNonOverlappingRange(candidate: candidate, excluding: nil) {
                drafts.append(SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs))
                localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                errorMessage = ""
                return
            }
        }

        let startMs = nonOverlappingStartMs(timeline.currentTimeMs)

        drafts.append(SegmentDraft(startMs: startMs, endMs: nil))
        localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
        errorMessage = ""

        if let durationMs = suggestedDurationTemplateMs(for: segment) {
            let targetMs = min(startMs + durationMs, SegmentValidator.maxTimestampMs)
            frameStripFineModeToken &+= 1
            seekTimeline(to: targetMs)
        }
    }

    func setDraftEnd(_ segment: SegmentType) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        var drafts = drafts(for: segment)

        if let pendingIndex = drafts.lastIndex(where: { $0.startMs != nil && $0.endMs == nil }),
           let startMs = drafts[pendingIndex].startMs
        {
            // Completing a pending start-draft: use raw playhead time;
            // adjustedNonOverlappingRange handles the complete pair.
            let endMs = timeline.currentTimeMs
            if endMs <= startMs {
                // Keep start-only as-is and continue with regular end creation.
                errorMessage = ""
            } else {
            let normalized = normalizeRange(startMs: startMs, endMs: endMs)
            if let adjusted = adjustedNonOverlappingRange(
                candidate: normalized,
                excluding: (segment, pendingIndex)
            ) {
                drafts[pendingIndex] = SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs)
                localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                errorMessage = ""
            } else {
                drafts.remove(at: pendingIndex)
                localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                errorMessage = "\(segment.displayName) segment could not be placed without overlapping an existing segment"
            }
            return
            }
        }

        let playheadMs = max(0, min(timeline.currentTimeMs, SegmentValidator.maxTimestampMs))
        if let draftAtPlayheadIndex = drafts.lastIndex(where: {
            guard let startMs = $0.startMs, let _ = $0.endMs else { return false }
            return startMs == playheadMs
        }),
           let draftEnd = drafts[draftAtPlayheadIndex].endMs
        {
            drafts.remove(at: draftAtPlayheadIndex)
            let endMs = nonOverlappingEndMs(draftEnd, excluding: (segment, draftAtPlayheadIndex))
            drafts.append(SegmentDraft(startMs: nil, endMs: endMs))
            localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
            errorMessage = ""
            return
        }

        if let containingIndex = drafts.lastIndex(where: {
            guard let startMs = $0.startMs, let endMs = $0.endMs else { return false }
            return playheadMs > startMs && playheadMs < endMs
        }) {
            drafts[containingIndex].endMs = playheadMs
            localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
            errorMessage = ""
            return
        }

        if drafts.contains(where: {
            guard let _ = $0.startMs, let endMs = $0.endMs else { return false }
            return endMs == playheadMs
        }) {
            errorMessage = ""
            return
        }

        if !isInsideClosedInterval(playheadMs),
           let previousEnd = nearestClosedEnd(atOrBefore: playheadMs),
           previousEnd < playheadMs
        {
            let candidate = normalizeRange(startMs: previousEnd, endMs: playheadMs)
            if let adjusted = adjustedNonOverlappingRange(candidate: candidate, excluding: nil) {
                drafts.append(SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs))
                localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                errorMessage = ""
                return
            }
        }

        // End-only draft: [0, endMs] must not logically contain any closed segment.
        let endMs = nonOverlappingEndMs(timeline.currentTimeMs)

        if hasPendingEndOnlyDraft(atEndMs: endMs, excluding: segment)
            || drafts.contains(where: { $0.startMs == nil && $0.endMs == endMs }) {
            errorMessage = ""
            return
        }

        drafts.append(SegmentDraft(startMs: nil, endMs: endMs))
        localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
        errorMessage = ""

        if let durationMs = suggestedDurationTemplateMs(for: segment) {
            let targetMs = max(0, endMs - durationMs)
            frameStripFineModeToken &+= 1
            seekTimeline(to: targetMs)
        }
    }

    func setDraftRange(_ segment: SegmentType, startMs: Int, endMs: Int) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        appendDraftRange(segment, startMs: startMs, endMs: endMs)
    }

    func moveNearestSegmentEndToPlayhead() {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        let playheadMs = timeline.currentTimeMs
        
        // Collect all boundaries (starts and ends) with their distances
        var boundaries: [(segment: SegmentType, draftIndex: Int, boundaryMs: Int, isEnd: Bool, distance: Int)] = []
        
        for segmentType in SegmentType.allCases {
            let drafts = self.drafts(for: segmentType)
            for (index, draft) in drafts.enumerated() {
                if let startMs = draft.startMs {
                    let distance = abs(startMs - playheadMs)
                    boundaries.append((segment: segmentType, draftIndex: index, boundaryMs: startMs, isEnd: false, distance: distance))
                }
                if let endMs = draft.endMs {
                    let distance = abs(endMs - playheadMs)
                    boundaries.append((segment: segmentType, draftIndex: index, boundaryMs: endMs, isEnd: true, distance: distance))
                }
            }
        }
        
        // Find closest boundary
        guard let closest = boundaries.min(by: { $0.distance < $1.distance }) else {
            errorMessage = "No segment boundary found"
            return
        }
        
        // Check if this boundary is connected to another segment
        // E.g., if this is a draft end, check if another segment starts at the same point
        var adjacentBoundary: (segment: SegmentType, draftIndex: Int, boundaryMs: Int, isEnd: Bool)? = nil
        
        for boundary in boundaries {
            if boundary.segment != closest.segment || boundary.draftIndex != closest.draftIndex {
                if closest.isEnd && !boundary.isEnd && boundary.boundaryMs == closest.boundaryMs {
                    // closest is an end, boundary is a start at same position - they're connected
                    adjacentBoundary = (segment: boundary.segment, draftIndex: boundary.draftIndex, boundaryMs: boundary.boundaryMs, isEnd: boundary.isEnd)
                    break
                } else if !closest.isEnd && boundary.isEnd && boundary.boundaryMs == closest.boundaryMs {
                    // closest is a start, boundary is an end at same position - they're connected
                    adjacentBoundary = (segment: boundary.segment, draftIndex: boundary.draftIndex, boundaryMs: boundary.boundaryMs, isEnd: boundary.isEnd)
                    break
                }
            }
        }
        
        // Update the closest boundary directly
        var closestDrafts = drafts(for: closest.segment)
        if closest.isEnd {
            closestDrafts[closest.draftIndex].endMs = min(playheadMs, SegmentValidator.maxTimestampMs)
        } else {
            closestDrafts[closest.draftIndex].startMs = max(0, playheadMs)
        }
        localDrafts[closest.segment] = normalizeAndSortDraftsByStart(closestDrafts)
        
        // If there's an adjacent boundary, update it too to maintain connection
        if let adjacent = adjacentBoundary {
            var adjacentDrafts = drafts(for: adjacent.segment)
            if adjacent.isEnd {
                adjacentDrafts[adjacent.draftIndex].endMs = min(playheadMs, SegmentValidator.maxTimestampMs)
            } else {
                adjacentDrafts[adjacent.draftIndex].startMs = max(0, playheadMs)
            }
            localDrafts[adjacent.segment] = normalizeAndSortDraftsByStart(adjacentDrafts)
        }
        
        infoMessage = "Moved nearest segment boundary to playhead"
    }

    func moveDraft(_ sourceSegment: SegmentType, index: Int, to targetSegment: SegmentType, startMs: Int, endMs: Int) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        var sourceDrafts = drafts(for: sourceSegment)
        guard sourceDrafts.indices.contains(index) else { return }

        let normalized = normalizeRange(startMs: startMs, endMs: endMs)
        guard normalized.endMs > normalized.startMs else {
            errorMessage = "\(targetSegment.displayName) segment could not be placed without overlapping an existing segment"
            return
        }

        guard let adjusted = adjustedNonOverlappingRange(
            candidate: normalized,
            excluding: (sourceSegment, index)
        ) else {
            errorMessage = "\(targetSegment.displayName) segment could not be placed without overlapping an existing segment"
            return
        }

        sourceDrafts.remove(at: index)

        if sourceSegment == targetSegment {
            sourceDrafts.append(SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs))
            localDrafts[sourceSegment] = normalizeAndSortDraftsByStart(sourceDrafts)
        } else {
            localDrafts[sourceSegment] = normalizeAndSortDraftsByStart(sourceDrafts)

            var targetDrafts = drafts(for: targetSegment)
            targetDrafts.append(SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs))
            localDrafts[targetSegment] = normalizeAndSortDraftsByStart(targetDrafts)
        }

        errorMessage = ""
    }

    func setDraftStartMs(_ segment: SegmentType, index: Int, ms: Int) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        updateDraft(segment, index: index) { draft in
            draft.startMs = max(0, ms)
        }
    }

    func setDraftEndMs(_ segment: SegmentType, index: Int, ms: Int) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        updateDraft(segment, index: index) { draft in
            draft.endMs = min(ms, SegmentValidator.maxTimestampMs)
        }
    }

    func updateDraftStartText(_ segment: SegmentType, index: Int, text: String) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        updateDraftTimestampText(segment, index: index, text: text, edge: .start)
    }

    func updateDraftEndText(_ segment: SegmentType, index: Int, text: String) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        updateDraftTimestampText(segment, index: index, text: text, edge: .end)
    }

    func clearDraft(_ segment: SegmentType) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        localDrafts[segment] = []
        submissionMessages[segment] = ""
    }

    func removeDraft(_ segment: SegmentType, index: Int) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        var drafts = drafts(for: segment)
        guard drafts.indices.contains(index) else { return }
        drafts.remove(at: index)
        localDrafts[segment] = drafts
    }

    func uploadSegment(_ segment: SegmentType) async {
        errorMessage = ""
        infoMessage = ""
        usageMessage = ""

        guard let context = makeUploadContext() else { return }
        let targetServices = uploadTargets(for: segment, context: context)
        guard !targetServices.isEmpty else {
            errorMessage = "No compatible API/key for \(segment.displayName). Provide TheIntroDB key with TMDB ID and/or IntroDB key with IMDB+season+episode."
            return
        }
        let segmentDrafts = drafts(for: segment)
            .filter { $0.startMs != nil || $0.endMs != nil }

        guard !segmentDrafts.isEmpty else {
            errorMessage = "No draft segments to upload for \(segment.displayName)"
            return
        }

        let allDrafts: [SubmissionDraft] = segmentDrafts.map { draft in
            makeSubmissionDraft(segment: segment, draft: draft, context: context)
        }

        uploadingSegment = segment
        defer { uploadingSegment = nil }

        var uploadCount = 0
        var uploadAttemptCount = 0
        var lastUsage: UsageHeaders?
        var uploadErrors: [String] = []

            await withTaskGroup(of: (Int, SegmentService, Result<UsageHeaders?, Error>).self) { group in
                for (index, submissionDraft) in allDrafts.enumerated() {
                    for service in targetServices {
                        uploadAttemptCount += 1
                        group.addTask {
                            do {
                                let usage = try await self.uploadSingleDraft(submissionDraft, service: service, context: context)
                                return (index, service, .success(usage))
                            } catch {
                                return (index, service, .failure(error))
                            }
                        }
                    }
                }

                for await (completedIndex, service, result) in group {
                    switch result {
                    case .success(let usage):
                        uploadCount += 1
                        if let usage = usage {
                            lastUsage = usage
                        }
                        let sourceDraft = segmentDrafts[completedIndex]
                        rememberDurationTemplate(for: segment, draft: sourceDraft)
                    case .failure(let error):
                        uploadErrors.append("\(service.rawValue) draft \(completedIndex + 1): \(error.localizedDescription)")
                    }
                }
            }

            if !uploadErrors.isEmpty {
                submissionMessages[segment] = "Uploaded \(uploadCount)/\(uploadAttemptCount) requests with errors"
                errorMessage = uploadErrors.joined(separator: "; ")
            } else {
                submissionMessages[segment] = "Uploaded \(uploadCount) request(s) to \(serviceListLabel(targetServices))"
                infoMessage = "Segment \(segment.displayName): \(uploadCount) upload(s) to \(serviceListLabel(targetServices)) completed"
            }

        usageMessage = lastUsage?.shortDescription ?? ""
        localDrafts[segment] = []
        resetSegmentHistory()

        await fetchMedia()
    }

    func uploadAllSegments() async {
        errorMessage = ""
        infoMessage = ""
        usageMessage = ""

        guard let context = makeUploadContext() else { return }

        isUploadingAll = true
        defer { isUploadingAll = false }

        var totalUploads = 0
        var totalAttemptedUploads = 0
        var lastUsage: UsageHeaders?
        var globalErrors: [String] = []

            await withTaskGroup(of: (SegmentType, Int, SegmentService, Result<UsageHeaders?, Error>).self) { group in
                for segmentType in SegmentType.allCases {
                    let segmentDrafts = drafts(for: segmentType)
                        .filter { $0.startMs != nil || $0.endMs != nil }

                    guard !segmentDrafts.isEmpty else { continue }
                    let targetServices = uploadTargets(for: segmentType, context: context)
                    guard !targetServices.isEmpty else {
                        globalErrors.append("\(segmentType.displayName): no compatible API/key")
                        continue
                    }

                    for (draftIndex, draft) in segmentDrafts.enumerated() {
                        let submissionDraft = makeSubmissionDraft(segment: segmentType, draft: draft, context: context)

                        for service in targetServices {
                            totalAttemptedUploads += 1
                            group.addTask {
                                do {
                                    let usage = try await self.uploadSingleDraft(submissionDraft, service: service, context: context)
                                    return (segmentType, draftIndex, service, .success(usage))
                                } catch {
                                    return (segmentType, draftIndex, service, .failure(error))
                                }
                            }
                        }
                    }
                }

                for await (segmentType, draftIndex, service, result) in group {
                    switch result {
                    case .success(let usage):
                        totalUploads += 1
                        if let usage = usage {
                            lastUsage = usage
                        }
                        let segmentDrafts = drafts(for: segmentType)
                            .filter { $0.startMs != nil || $0.endMs != nil }
                        if draftIndex < segmentDrafts.count {
                            let sourceDraft = segmentDrafts[draftIndex]
                            rememberDurationTemplate(for: segmentType, draft: sourceDraft)
                        }
                    case .failure(let error):
                        globalErrors.append("\(service.rawValue) \(segmentType.displayName) #\(draftIndex + 1): \(error.localizedDescription)")
                    }
                }
            }

            if !globalErrors.isEmpty {
                infoMessage = "Uploaded \(totalUploads)/\(totalAttemptedUploads) requests with errors"
                errorMessage = globalErrors.prefix(3).joined(separator: "; ") + (globalErrors.count > 3 ? "..." : "")
            } else if totalUploads > 0 {
                infoMessage = "Uploaded \(totalUploads) request(s)"
            } else {
                infoMessage = "No segments to upload"
            }

        usageMessage = lastUsage?.shortDescription ?? ""

        for segmentType in SegmentType.allCases {
            localDrafts[segmentType] = []
        }
        resetSegmentHistory()

        await fetchMedia()
    }

    func seekTimeline(to milliseconds: Int) {
        timeline.seek(ms: milliseconds)
    }

    func updateMinimumZoom(_ minimum: Double) {
        let clamped = min(max(minimum, 0.05), 1.0)
        minimumZoomLevel = clamped

        // Ignore placeholder-fit callbacks until the newly loaded video has
        // reported a real duration. Otherwise auto-fit can be consumed too
        // early and miss the actual file's fit zoom.
        if shouldAutoFitZoomAfterLoad, timeline.durationMs <= 0 {
            return
        }

        if shouldAutoFitZoomAfterLoad {
            zoomLevel = clamped
            shouldAutoFitZoomAfterLoad = false
            return
        }

        if zoomLevel < clamped {
            zoomLevel = clamped
        }
    }

    func requestPlayerFocus() {
        playerFocusRequestID &+= 1
    }

    private struct UploadContext {
        var theIntroDBAPIKey: String?
        var introDBAPIKey: String?
        var tmdbId: Int?
        var imdbId: String?
        var season: Int?
        var episode: Int?
    }

    private func makeUploadContext() -> UploadContext? {
        let theIntroKey = optional(theIntroDBAPIKey)
        let introKey = optional(introDBAPIKey)

        guard theIntroKey != nil || introKey != nil else {
            errorMessage = "At least one API key (TheIntroDB or IntroDB) is required for upload"
            return nil
        }

        return UploadContext(
            theIntroDBAPIKey: theIntroKey,
            introDBAPIKey: introKey,
            tmdbId: intOrNil(tmdbIdText),
            imdbId: optional(imdbIdText),
            season: intOrNil(seasonText),
            episode: intOrNil(episodeText)
        )
    }

    private func makeSubmissionDraft(segment: SegmentType, draft: SegmentDraft, context: UploadContext) -> SubmissionDraft {
        SubmissionDraft(
            tmdbId: context.tmdbId ?? 0,
            imdbId: context.imdbId,
            mediaType: selectedMediaType,
            segment: segment,
            season: selectedMediaType == .tv ? context.season : nil,
            episode: selectedMediaType == .tv ? context.episode : nil,
            startMs: draft.startMs,
            endMs: draft.endMs
        )
    }

    private func uploadTargets(for segment: SegmentType, context: UploadContext) -> [SegmentService] {
        var targets: [SegmentService] = []

        if context.theIntroDBAPIKey != nil,
           let tmdbId = context.tmdbId,
           tmdbId > 0
        {
            targets.append(.theIntroDB)
        }

        if context.introDBAPIKey != nil,
           selectedMediaType == .tv,
           context.imdbId != nil,
           context.season != nil,
           context.episode != nil
        {
            switch segment {
            case .intro, .recap, .credits:
                targets.append(.introDB)
            case .preview:
                break
            }
        }

        return targets
    }

    private func uploadSingleDraft(_ draft: SubmissionDraft, service: SegmentService, context: UploadContext) async throws -> UsageHeaders? {
        switch service {
        case .theIntroDB:
            guard let apiKey = context.theIntroDBAPIKey else {
                throw SegmentValidationError.message("TheIntroDB API key is missing")
            }
            guard draft.tmdbId > 0 else {
                throw SegmentValidationError.message("Valid TMDB ID is required for TheIntroDB uploads")
            }
            let request = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft)
            let response = try await theIntroDBClient.submit(request, apiKey: apiKey)
            return response.usage
        case .introDB:
            guard let apiKey = context.introDBAPIKey else {
                throw SegmentValidationError.message("IntroDB API key is missing")
            }
            let request = try SegmentValidator.makeIntroDBSubmissionRequest(from: draft)
            let response = try await introDBClient.submit(request, apiKey: apiKey)
            return response.usage
        }
    }

    private func canUseIntroDB(query: MediaQuery) -> Bool {
        selectedMediaType == .tv
            && query.imdbId != nil
            && query.season != nil
            && query.episode != nil
    }

    private func serviceListLabel(_ services: [SegmentService]) -> String {
        services.map(\.rawValue).joined(separator: ", ")
    }

    private func invalidateEffectiveDurationCache() {
        cachedEffectiveDurationMs = nil
        cachedTimelineDurationMs = nil
    }

    private func makeMediaQuery() -> MediaQuery {
        let tmdb = intOrNil(tmdbIdText)
        let imdb = optional(imdbIdText)

        if selectedMediaType == .tv {
            return MediaQuery(
                tmdbId: tmdb,
                imdbId: imdb,
                season: intOrNil(seasonText),
                episode: intOrNil(episodeText)
            )
        }

        return MediaQuery(
            tmdbId: tmdb,
            imdbId: imdb,
            season: nil,
            episode: nil
        )
    }

    private static func makeSegmentDictionary<T>(defaultValue: T) -> [SegmentType: T] {
        var result: [SegmentType: T] = [:]
        for type in SegmentType.allCases {
            result[type] = defaultValue
        }
        return result
    }

    private func intOrNil(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    private func optional(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func prefillDraftsFromServerSegments() {
        for type in SegmentType.allCases {
            let ranges = serverSegments[type] ?? []
            let drafts = ranges.map { SegmentDraft(startMs: $0.startMs, endMs: $0.endMs) }
            localDrafts[type] = normalizeAndSortDraftsByStart(drafts)
            for draft in drafts {
                rememberDurationTemplate(for: type, draft: draft)
            }
        }
        resetSegmentHistory()
    }

    private func beginSegmentChangeCapture() -> SegmentDraftSnapshot {
        segmentChangeCaptureDepth += 1
        return localDrafts
    }

    private func endSegmentChangeCapture(before snapshot: SegmentDraftSnapshot) {
        guard segmentChangeCaptureDepth > 0 else { return }
        segmentChangeCaptureDepth -= 1

        guard segmentChangeCaptureDepth == 0 else { return }
        guard batchedSegmentChangeDepth == 0 else { return }
        guard !isApplyingHistoryChange else { return }
        guard localDrafts != snapshot else { return }

        registerUndo(from: snapshot, to: localDrafts)
    }

    private func resetSegmentHistory() {
        activeUndoManager.removeAllActions()
        fallbackUndoManager.removeAllActions()
        segmentChangeCaptureDepth = 0
        batchedSegmentChangeDepth = 0
        batchedSegmentChangeSnapshot = nil
    }

    private func registerUndo(from previous: SegmentDraftSnapshot, to current: SegmentDraftSnapshot) {
        activeUndoManager.registerUndo(withTarget: self) { target in
            target.registerUndo(from: current, to: previous)
            target.isApplyingHistoryChange = true
            target.localDrafts = previous
            target.isApplyingHistoryChange = false
            target.errorMessage = ""
        }
    }

    private var activeUndoManager: UndoManager {
        NSApp.keyWindow?.undoManager
        ?? NSApp.mainWindow?.undoManager
        ?? fallbackUndoManager
    }

    private func appendDraftRange(_ segment: SegmentType, startMs: Int, endMs: Int) {
        let normalized = normalizeRange(startMs: startMs, endMs: endMs)
        guard let adjusted = adjustedNonOverlappingRange(candidate: normalized, excluding: nil) else {
            errorMessage = "\(segment.displayName) segment could not be placed without overlapping an existing segment"
            return
        }

        var drafts = drafts(for: segment)
        drafts.append(SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs))
        localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
        errorMessage = ""
    }

    private func updateDraft(_ segment: SegmentType, index: Int, mutation: (inout SegmentDraft) -> Void) {
        var drafts = drafts(for: segment)
        guard drafts.indices.contains(index) else { return }

        var draft = drafts[index]
        mutation(&draft)
        guard let startMs = draft.startMs, let endMs = draft.endMs else {
            // Single-timestamp draft: clamp its point out of any occupied interval.
            // Use closed-only intervals: an open-ended draft [s, ∞) overlaps any
            // closed interval [a, b] where s < b, so push s to b. Symmetrically
            // an open-start draft [0, e] overlaps any [a, b] where e > a, pull e to a.
            let occupied = allDraftIntervals(excluding: (segment, index), includeOpen: false)
            if var adjusted = draft.startMs {
                for interval in occupied {
                    if adjusted < interval.endMs { adjusted = interval.endMs }
                }
                draft.startMs = min(max(adjusted, 0), SegmentValidator.maxTimestampMs)
            } else if var adjusted = draft.endMs {
                for interval in occupied.reversed() {
                    if adjusted > interval.startMs { adjusted = interval.startMs }
                }
                draft.endMs = max(min(adjusted, SegmentValidator.maxTimestampMs), 0)
            }
            drafts[index] = draft
            localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
            errorMessage = ""
            return
        }

        let normalized = normalizeRange(startMs: startMs, endMs: endMs)
        guard let adjusted = adjustedNonOverlappingRange(
            candidate: normalized,
            excluding: (segment, index)
        ) else {
            errorMessage = "\(segment.displayName) segment could not be placed without overlapping an existing segment"
            return
        }

        drafts[index] = SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs)
        localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
        errorMessage = ""
    }

    private func updateDraftTimestampText(_ segment: SegmentType, index: Int, text: String, edge: DraftTextEdge) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed == "--" {
            updateDraft(segment, index: index) { draft in
                switch edge {
                case .start:
                    draft.startMs = nil
                case .end:
                    draft.endMs = nil
                }
            }
            return
        }

        guard let milliseconds = TimeFormatting.parse(text: trimmed) else {
            errorMessage = "Invalid time format. Use ms, mm:ss(.mmm), or hh:mm:ss(.mmm)"
            return
        }

        switch edge {
        case .start:
            setDraftStartMs(segment, index: index, ms: milliseconds)
        case .end:
            setDraftEndMs(segment, index: index, ms: milliseconds)
        }
    }

    private func normalizeRange(startMs: Int, endMs: Int) -> (startMs: Int, endMs: Int) {
        let s = max(0, min(startMs, endMs))
        let e = min(max(startMs, endMs), SegmentValidator.maxTimestampMs)
        return (s, e)
    }

    private func normalizeAndSortDraftsByStart(_ drafts: [SegmentDraft]) -> [SegmentDraft] {
        drafts.sorted { lhs, rhs in
            (lhs.startMs ?? Int.min) < (rhs.startMs ?? Int.min)
        }
    }

    private func adjustedNonOverlappingRange(
        candidate: (startMs: Int, endMs: Int),
        excluding: (segment: SegmentType, index: Int)?
    ) -> (startMs: Int, endMs: Int)? {
        var start = candidate.startMs
        var end = candidate.endMs
        guard end > start else { return nil }

        let occupied = allDraftIntervals(excluding: excluding)
        for interval in occupied {
            guard intervalsOverlap(start1: start, end1: end, start2: interval.startMs, end2: interval.endMs) else {
                continue
            }

            if start < interval.startMs && end > interval.startMs {
                end = interval.startMs
            } else if end > interval.endMs && start < interval.endMs {
                start = interval.endMs
            } else {
                let moveToLeft = abs(end - interval.startMs)
                let moveToRight = abs(interval.endMs - start)
                if moveToLeft <= moveToRight {
                    end = interval.startMs
                } else {
                    start = interval.endMs
                }
            }

            if end <= start {
                return nil
            }
        }

        return (start, end)
    }

    private func allDraftIntervals(
        excluding: (segment: SegmentType, index: Int)?,
        includeOpen: Bool = true
    ) -> [(startMs: Int, endMs: Int)] {
        var intervals: [(startMs: Int, endMs: Int)] = []

        for segType in SegmentType.allCases {
            let drafts = self.drafts(for: segType)
            for (idx, draft) in drafts.enumerated() {
                if let excluding, excluding.segment == segType, excluding.index == idx {
                    continue
                }
                if let start = draft.startMs, let end = draft.endMs {
                    let normalized = normalizeRange(startMs: start, endMs: end)
                    if normalized.endMs > normalized.startMs {
                        intervals.append(normalized)
                    }
                } else if includeOpen, let point = draft.startMs ?? draft.endMs {
                    // Open draft: represent as a 1 ms point so complete segments
                    // cannot be dragged directly onto the marker.
                    let clamped = max(0, min(point, SegmentValidator.maxTimestampMs - 1))
                    intervals.append((startMs: clamped, endMs: clamped + 1))
                }
            }
        }

        return intervals.sorted { $0.startMs < $1.startMs }
    }

    private func isInsideClosedInterval(_ ms: Int) -> Bool {
        let closed = allDraftIntervals(excluding: nil, includeOpen: false)
        return closed.contains(where: { ms > $0.startMs && ms < $0.endMs })
    }

    private func containingClosedInterval(at ms: Int) -> (startMs: Int, endMs: Int)? {
        allDraftIntervals(excluding: nil, includeOpen: false)
            .first(where: { ms > $0.startMs && ms < $0.endMs })
    }

    private func nearestClosedStart(atOrAfter ms: Int) -> Int? {
        allDraftIntervals(excluding: nil, includeOpen: false)
            .filter { $0.startMs >= ms }
            .map { $0.startMs }
            .min()
    }

    private func nearestClosedEnd(atOrBefore ms: Int) -> Int? {
        allDraftIntervals(excluding: nil, includeOpen: false)
            .filter { $0.endMs <= ms }
            .map { $0.endMs }
            .max()
    }

    private func nearestDraftStartMarker(atOrAfter ms: Int) -> Int? {
        SegmentType.allCases
            .flatMap { drafts(for: $0).compactMap(\ .startMs) }
            .filter { $0 >= ms }
            .min()
    }

    private func latestPendingStartOnlyDraft(excluding segment: SegmentType) -> (segment: SegmentType, index: Int)? {
        var best: (segment: SegmentType, index: Int, startMs: Int)?

        for segType in SegmentType.allCases where segType != segment {
            let segmentDrafts = drafts(for: segType)
            for (idx, draft) in segmentDrafts.enumerated() {
                guard let startMs = draft.startMs, draft.endMs == nil else { continue }
                if let current = best {
                    if startMs > current.startMs {
                        best = (segType, idx, startMs)
                    }
                } else {
                    best = (segType, idx, startMs)
                }
            }
        }

        guard let best else { return nil }
        return (best.segment, best.index)
    }

    private func hasPendingEndOnlyDraft(in segment: SegmentType) -> Bool {
        drafts(for: segment).contains(where: { $0.startMs == nil && $0.endMs != nil })
    }

    private func hasPendingStartOnlyDraft(excluding segment: SegmentType) -> Bool {
        SegmentType.allCases.contains { segType in
            guard segType != segment else { return false }
            return drafts(for: segType).contains(where: { $0.startMs != nil && $0.endMs == nil })
        }
    }

    private func hasPendingEndOnlyDraft(atEndMs endMs: Int, excluding segment: SegmentType) -> Bool {
        SegmentType.allCases.contains { segType in
            guard segType != segment else { return false }
            return drafts(for: segType).contains(where: { $0.startMs == nil && $0.endMs == endMs })
        }
    }

    /// Pushes `ms` forward so that the open-ended segment [ms, ∞) does not overlap
    /// any closed interval [a, b]. Overlap occurs when ms < b, so push to b.
    private func nonOverlappingStartMs(_ ms: Int) -> Int {
        var adjusted = max(0, ms)
        for interval in allDraftIntervals(excluding: nil, includeOpen: false) {
            if adjusted < interval.endMs { adjusted = interval.endMs }
        }
        return min(adjusted, SegmentValidator.maxTimestampMs)
    }

    /// Pulls `ms` backward so that the open-start segment [0, ms] does not overlap
    /// any closed interval [a, b]. Overlap occurs when ms > a, so pull to a.
    private func nonOverlappingEndMs(_ ms: Int, excluding: (segment: SegmentType, index: Int)? = nil) -> Int {
        var adjusted = min(max(0, ms), SegmentValidator.maxTimestampMs)
        for interval in allDraftIntervals(excluding: excluding, includeOpen: false).reversed() {
            if adjusted > interval.startMs { adjusted = interval.startMs }
        }
        return adjusted
    }

    private func intervalsOverlap(start1: Int, end1: Int, start2: Int, end2: Int) -> Bool {
        max(start1, start2) < min(end1, end2)
    }

    private enum DraftTextEdge {
        case start
        case end
    }

    private func currentTemplateMediaKey() -> String? {
        guard let tmdbId = intOrNil(tmdbIdText), tmdbId > 0 else { return nil }
        return "\(selectedMediaType.rawValue):\(tmdbId)"
    }

    private func templateKey(for segment: SegmentType) -> String? {
        guard let mediaKey = currentTemplateMediaKey() else { return nil }
        return "\(mediaKey):\(segment.rawValue)"
    }

    private func suggestedDurationTemplateMs(for segment: SegmentType) -> Int? {
        guard let key = templateKey(for: segment) else { return nil }
        return segmentDurationTemplatesMs[key]
    }

    private func rememberDurationTemplate(for segment: SegmentType, draft: SegmentDraft) {
        guard let start = draft.startMs, let end = draft.endMs, end >= start else { return }
        let duration = end - start
        guard duration >= SegmentValidator.minDurationMs else { return }
        guard let key = templateKey(for: segment) else { return }
        segmentDurationTemplatesMs[key] = duration
        saveDurationTemplatesToDefaults()
    }

    private func loadDurationTemplatesFromDefaults() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: durationTemplateDefaultsKey) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveDurationTemplatesToDefaults() {
        guard let data = try? JSONEncoder().encode(segmentDurationTemplatesMs) else { return }
        UserDefaults.standard.set(data, forKey: durationTemplateDefaultsKey)
    }
}

private extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}
