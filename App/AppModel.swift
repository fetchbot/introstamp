import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    private typealias SegmentDraftSnapshot = [SegmentType: [SegmentDraft]]

    private struct ImportedTMDBReviewBatch {
        var tmdbId: Int
        var items: [ListReviewItem]
    }

    private struct ModeEditingState {
        var selectedVideoURL: URL?
        var videoTitle: String
        var timelineTimeMs: Int
        var zoomLevel: Double

        var selectedMediaType: MediaType
        var tmdbIdText: String
        var imdbIdText: String
        var seasonText: String
        var episodeText: String
        var matchedPosterURL: URL?

        var tmdbSearchText: String
        var tmdbSearchResults: [AutoLookupResult]
        var autoLookupCandidates: [AutoLookupResult]
        var selectedAutoLookupTMDBID: Int?
        var tmdbTitleHintsByID: [Int: String]

        var serverSegments: [SegmentType: [SegmentRange]]
        var localDrafts: [SegmentType: [SegmentDraft]]
        var noSegmentFlags: [SegmentType: Bool]
        var submissionMessages: [SegmentType: String]

        var recapHintBuckets: [Double]
        var detectedScenes: [SceneChange]
        var currentSceneIndex: Int?
        var sceneDetectionMessage: String
        var tmdbGenreNames: [String]
    }

    private struct APIKeysBundle: Codable {
        let theIntroDBAPIKey: String
        let introDBAPIKey: String
        let tmdbAPIKey: String
        let openSubtitlesAPIKey: String
    }

    private struct SubtitleCacheKey: Hashable {
        var imdbId: String
        var season: Int
        var episode: Int
        var language: String
    }

    private struct LocalSubtitleEpisodeKey: Hashable {
        var rootPath: String
        var season: Int
        var episode: Int
    }

    enum SegmentService: String {
        case theIntroDB = "TheIntroDB"
        case introDB = "IntroDB"
    }

    var theIntroDBAPIKey: String = ""
    var introDBAPIKey: String = ""
    var tmdbAPIKey: String = ""
    var openSubtitlesAPIKey: String = "" {
        didSet {
            applyAutoRecapDefaultIfNeeded()
        }
    }
    var localOpenSubtitlesDirectoryPath: String = "" {
        didSet {
            UserDefaults.standard.set(localOpenSubtitlesDirectoryPath, forKey: localOpenSubtitlesDirectoryDefaultsKey)
            cancelLocalSubtitleLoadTasks()
            applyAutoRecapDefaultIfNeeded()
        }
    }

    // Clerk sessions (temporary, only for backup duration)
    var theIntroDBClerkCurl: String = ""
    var introDBClerkCurl: String = ""
    private var theIntroDBClerkSession: ClerkSession?
    private var introDBClerkSession: ClerkSession?

    // Backup UI state
    var backupServicePending: String? = nil

    var selectedVideoURL: URL?
    var videoTitle: String = "No video selected"

    var tmdbIdText: String = ""
    var imdbIdText: String = ""
    var selectedMediaType: MediaType = .tv
    var seasonText: String = ""
    var episodeText: String = ""

    var autoLookupMessage: String = ""
    var infoMessage: String = ""
    var errorMessage: String = ""
    var recapDetectionMessage: String = ""
    var isDetectingRecap: Bool = false
    var isAutoRecapDetectionEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isAutoRecapDetectionEnabled, forKey: autoRecapPreferenceDefaultsKey)
        }
    }
    var recapHintBuckets: [Double] = []
    var usageMessage: String = ""
    var matchedPosterURL: URL?
    var autoLookupCandidates: [AutoLookupResult] = []
    var selectedAutoLookupTMDBID: Int?

    var isFetchingMedia = false
    var uploadingSegment: SegmentType? {
        activeSegmentUploadsByVideo[videoLoadID]?.first
    }
    var isUploadingAll: Bool {
        activeUploadAllByVideo.contains(videoLoadID)
    }
    var zoomLevel: Double = 1.0
    var tmdbSearchText = ""
    var isTMDBSearching = false
    var tmdbSearchResults: [AutoLookupResult] = []
    var tmdbTitleHintsByID: [Int: String] = [:]
    var appMode: AppMode = .singleVideo {
        didSet {
            UserDefaults.standard.set(appMode.rawValue, forKey: appModeDefaultsKey)
            guard appMode != oldValue else { return }
            captureEditingState(for: oldValue)
            restoreEditingState(for: appMode)
        }
    }
    var reviewListItems: [ListReviewItem] = []
    var selectedReviewListItemID: String?
    var reviewListInfoMessage: String = ""
    var reviewListErrorMessage: String = ""
    var isLoadingReviewList: Bool = false
    var importQueuedTMDBProgressText: String = ""
    var hasNextQueuedImportedTMDB: Bool {
        guard !queuedImportedTMDBBatches.isEmpty else { return false }
        return queuedImportedTMDBIndex + 1 < queuedImportedTMDBBatches.count
    }
    var minimumZoomLevel: Double = 1.0
    var playerFocusRequestID: Int = 0
    var videoLoadID: Int = 0
    var frameStripFineModeToken: Int = 0

    var serverSegments: [SegmentType: [SegmentRange]] = AppModel.makeSegmentDictionary(defaultValue: []) {
        didSet { invalidateEffectiveDurationCache() }
    }
    var localDrafts: [SegmentType: [SegmentDraft]] = AppModel.makeSegmentDictionary(defaultValue: []) {
        didSet {
            invalidateEffectiveDurationCache()
            syncSelectedReviewItemFromEditorIfNeeded()
        }
    }
    var submissionMessages: [SegmentType: String] = AppModel.makeSegmentDictionary(defaultValue: "")
    var noSegmentFlags: [SegmentType: Bool] = AppModel.makeSegmentDictionary(defaultValue: false)

    var audioWaveformTrack: TimelineDensityTrack {
        TimelineDensityTrack(
            label: "Audio",
            buckets: timeline.waveformBuckets,
            musicLikelihoodBuckets: isMusicLikelihoodEnabled ? timeline.musicLikelihoodBuckets : nil,
            recapHintBuckets: recapHintBuckets.isEmpty ? nil : recapHintBuckets
        )
    }

    var detectedScenes: [SceneChange] = []
    var isDetectingScenes: Bool = false
    var isSceneDetectionEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isSceneDetectionEnabled, forKey: sceneDetectionEnabledDefaultsKey)
        }
    }
    var isMusicLikelihoodEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isMusicLikelihoodEnabled, forKey: musicLikelihoodEnabledDefaultsKey)
        }
    }
    var isSubmissionLoggingEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isSubmissionLoggingEnabled, forKey: submissionLoggingEnabledDefaultsKey)
        }
    }
    var currentSceneIndex: Int? = nil
    var sceneDetectionMessage: String = ""
    var tmdbGenreNames: [String] = []

    let timeline: PlayerTimelineEngine

    private let keychain: KeychainStore
    private let shouldAccessKeychain: Bool
    private let theIntroDBClient: TheIntroDBClient
    private let introDBClient: IntroDBClient
    private let tmdbClient: TMDBClient
    private let openSubtitlesClient: OpenSubtitlesClient
    private let sceneDetector = SceneDetector()
    private var pendingSceneDetectionTask: Task<Void, Never>?
    private var sceneDetectionActiveGenres: [String]? = nil
    private var shouldAutoFitZoomAfterLoad = true
    private var cachedEffectiveDurationMs: Int?
    private var cachedTimelineDurationMs: Int?
    private var segmentDurationTemplatesMs: [String: Int] = [:]
    private let fallbackUndoManager = UndoManager()
    private var segmentChangeCaptureDepth = 0
    private var batchedSegmentChangeDepth = 0
    private var batchedSegmentChangeSnapshot: SegmentDraftSnapshot?
    private var isApplyingHistoryChange = false
    private var isSynchronizingReviewSelection = false
    private let durationTemplateDefaultsKey = "segment_duration_templates_ms_v1"
    private let appModeDefaultsKey = "app_mode_preference_v1"
    private let autoRecapPreferenceDefaultsKey = "auto_recap_detection_enabled_v1"
    private let localOpenSubtitlesDirectoryDefaultsKey = "local_opensubtitles_directory_path_v1"
    private let sceneDetectionEnabledDefaultsKey = "scene_detection_enabled_v1"
    private let musicLikelihoodEnabledDefaultsKey = "music_likelihood_enabled_v1"
    private let submissionLoggingEnabledDefaultsKey = "submission_logging_enabled_v1"
    private var pendingAutoDetectFetchTask: Task<Void, Never>?
    private var pendingDeferredRecapTask: Task<Void, Never>?
    private var activeSegmentUploadsByVideo: [Int: Set<SegmentType>] = [:]
    private var activeUploadAllByVideo: Set<Int> = []
    private var subtitleTextCache: [SubtitleCacheKey: String] = [:]
    private var localSubtitleLoadTasks: [LocalSubtitleEpisodeKey: Task<(text: String, fileExtension: String, language: String), Error>] = [:]
    private var preferredSubtitleLanguageBySeries: [String: String] = [:]
    private var jumpDirectionByStartSegment: [SegmentType: Int] = [:]
    private var jumpDirectionByEndSegment: [SegmentType: Int] = [:]
    private var sceneJumpDirection: Int?
    private var modeEditingStateByMode: [AppMode: ModeEditingState] = [:]
    private var queuedImportedTMDBBatches: [ImportedTMDBReviewBatch] = []
    private var queuedImportedTMDBIndex: Int = -1
    var autoRecapDraftKeys: Set<String> = []
    let autoRecapMinimumDurationMs: Int = 5_000

    init(
        timeline: PlayerTimelineEngine = PlayerTimelineEngine(),
        keychain: KeychainStore = KeychainStore(),
        theIntroDBClient: TheIntroDBClient = TheIntroDBClient(),
        introDBClient: IntroDBClient = IntroDBClient(),
        tmdbClient: TMDBClient = TMDBClient(),
        openSubtitlesClient: OpenSubtitlesClient = OpenSubtitlesClient(),
        shouldAccessKeychain: Bool = !ProcessInfo.processInfo.isRunningTests
    ) {
        self.timeline = timeline
        self.keychain = keychain
        self.shouldAccessKeychain = shouldAccessKeychain
        self.theIntroDBClient = theIntroDBClient
        self.introDBClient = introDBClient
        self.tmdbClient = tmdbClient
        self.openSubtitlesClient = openSubtitlesClient

        if let stored = UserDefaults.standard.object(forKey: autoRecapPreferenceDefaultsKey) as? Bool {
            isAutoRecapDetectionEnabled = stored
        }
        if let storedMode = UserDefaults.standard.string(forKey: appModeDefaultsKey),
           let parsedMode = AppMode(rawValue: storedMode) {
            appMode = parsedMode
        }
        if let stored = UserDefaults.standard.object(forKey: sceneDetectionEnabledDefaultsKey) as? Bool {
            isSceneDetectionEnabled = stored
        }
        if let stored = UserDefaults.standard.object(forKey: musicLikelihoodEnabledDefaultsKey) as? Bool {
            isMusicLikelihoodEnabled = stored
        }
        if let stored = UserDefaults.standard.object(forKey: submissionLoggingEnabledDefaultsKey) as? Bool {
            isSubmissionLoggingEnabled = stored
        }
        if UserDefaults.standard.object(forKey: localOpenSubtitlesDirectoryDefaultsKey) != nil {
            UserDefaults.standard.removeObject(forKey: localOpenSubtitlesDirectoryDefaultsKey)
        }

        if shouldAccessKeychain {
            tryLoadKeysFromKeychain(allowUserInteraction: false, announceOutcome: false)
        }

        applyAutoRecapDefaultIfNeeded()
        segmentDurationTemplatesMs = loadDurationTemplatesFromDefaults()
    }

    private func applyAutoRecapDefaultIfNeeded() {
        guard UserDefaults.standard.object(forKey: autoRecapPreferenceDefaultsKey) == nil else { return }
        guard hasRecapSubtitleSourceConfigured else { return }
        isAutoRecapDetectionEnabled = true
    }

    var hasRecapSubtitleSourceConfigured: Bool {
        !openSubtitlesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !localOpenSubtitlesDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var areAPIKeyFieldsEmpty: Bool {
        theIntroDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && introDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && openSubtitlesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

        let reviewDuration = selectedReviewItem?.videoDurationMs ?? 0

        let resolved = max(timeline.durationMs, reviewDuration, serverMax, draftMax, 60_000)
        cachedEffectiveDurationMs = resolved
        cachedTimelineDurationMs = timeline.durationMs
        return resolved
    }

    var selectedReviewItem: ListReviewItem? {
        guard let selectedReviewListItemID else { return nil }
        return reviewListItems.first(where: { $0.id == selectedReviewListItemID })
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

    func setTemplateDurationMs(_ durationMs: Int?, for segment: SegmentType) {
        guard let key = templateKey(for: segment) else { return }
        if let durationMs, durationMs > 0 {
            segmentDurationTemplatesMs[key] = durationMs
        } else {
            segmentDurationTemplatesMs.removeValue(forKey: key)
        }
        saveDurationTemplatesToDefaults()
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

    func chooseLocalOpenSubtitlesDirectory() {
        let panel = NSOpenPanel()
        panel.prompt = "Select"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            localOpenSubtitlesDirectoryPath = url.path
        }
    }

    func loadVideo(url: URL) {
        pendingAutoDetectFetchTask?.cancel()
        pendingDeferredRecapTask?.cancel()
        pendingSceneDetectionTask?.cancel()
        cancelLocalSubtitleLoadTasks()
        selectedVideoURL = url
        videoTitle = url.lastPathComponent
        matchedPosterURL = nil
        autoLookupCandidates = []
        selectedAutoLookupTMDBID = nil
        tmdbIdText = ""
        imdbIdText = ""
        detectedScenes = []
        currentSceneIndex = nil
        sceneDetectionMessage = ""
        tmdbGenreNames = []
        sceneJumpDirection = nil
        shouldAutoFitZoomAfterLoad = true
        zoomLevel = minimumZoomLevel
        recapHintBuckets = []
        recapDetectionMessage = ""

        let parsed = FilenameMediaParser.parse(url: url)
        selectedMediaType = parsed.mediaTypeHint
        if let season = parsed.season { seasonText = String(season) }
        if let episode = parsed.episode { episodeText = String(episode) }

        videoLoadID &+= 1
        let currentVideoLoadID = videoLoadID

        let remoteCopyGate = makeRemoteVideoCopyGateTask(videoLoadID: currentVideoLoadID)
        timeline.setRemoteCopyStartGate(remoteCopyGate)
        timeline.onAnalysisAssetReady = { [weak self] readyURL in
            guard let self else { return }
            guard self.videoLoadID == currentVideoLoadID else { return }
            self.scheduleSceneDetection(videoLoadID: currentVideoLoadID, preferredVideoURL: readyURL)
        }

        timeline.loadVideo(url: url)
        serverSegments = AppModel.makeSegmentDictionary(defaultValue: [])
        localDrafts = AppModel.makeSegmentDictionary(defaultValue: [])
        noSegmentFlags = AppModel.makeSegmentDictionary(defaultValue: false)
        resetSegmentHistory()
        infoMessage = "Loaded \(url.lastPathComponent)"
        errorMessage = ""
        requestPlayerFocus()
        
        pendingAutoDetectFetchTask = Task { [weak self] in
            guard let self else { return }
            let matched = await self.autoDetectMediaID(for: url)
            guard !Task.isCancelled, self.videoLoadID == currentVideoLoadID else { return }
            if matched {
                self.scheduleLocalSubtitleLoadIfNeeded(videoLoadID: self.videoLoadID)
                await self.fetchMedia(prefillDrafts: true)
            }
        }
    }

    private func makeRemoteVideoCopyGateTask(videoLoadID: Int) -> Task<Void, Never>? {
        guard self.videoLoadID == videoLoadID else { return nil }
        guard selectedMediaType == .tv else { return nil }
        guard let season = intOrNil(seasonText), season >= 0 else { return nil }
        guard let episode = intOrNil(episodeText), episode >= 2 else { return nil }
        let imdbId = imdbIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imdbId.isEmpty else { return nil }

        let rootPath = localOpenSubtitlesDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return nil }

        let currentTask = localSubtitleLoadTask(rootPath: rootPath, imdbId: imdbId, season: season, episode: episode)
        let previousTask = localSubtitleLoadTask(rootPath: rootPath, imdbId: imdbId, season: season, episode: episode - 1)

        return Task.detached(priority: .userInitiated) {
            async let waitCurrent: Void = {
                _ = try? await currentTask.value
            }()
            async let waitPrevious: Void = {
                _ = try? await previousTask.value
            }()
            _ = await (waitCurrent, waitPrevious)
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
            if results.count == 1, let first = results.first {
                errorMessage = ""
                selectTMDBSearchResult(first)
                return
            }
            tmdbSearchResults = results
            for result in results {
                tmdbTitleHintsByID[result.tmdbId] = result.title
            }
            if tmdbSearchResults.isEmpty {
                errorMessage = "No TMDB results for \"\(query)\""
            } else {
                errorMessage = ""
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

        Task {
            if appMode == .singleVideo {
                await fetchMedia(prefillDrafts: true)
            } else {
                await loadReviewListFromCurrentSelection()
            }
        }
    }

    func chooseReviewImportFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .plainText]

        guard panel.runModal() == .OK else { return }

        Task {
            await importReviewFiles(urls: panel.urls)
        }
    }

    func importReviewFiles(urls: [URL]) async {
        guard !urls.isEmpty else { return }

        reviewListErrorMessage = ""
        reviewListInfoMessage = ""
        reviewListItems = []
        selectedReviewListItemID = nil
        isLoadingReviewList = true
        defer { isLoadingReviewList = false }

        var importedItems: [ListReviewItem] = []
        var issues: [String] = []

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let parsed = try ReviewListImportParser.parse(data: data, sourceLabel: url.lastPathComponent)
                importedItems.append(contentsOf: parsed)
            } catch {
                issues.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !importedItems.isEmpty {
            await applyImportedReviewItems(importedItems)
        }
        if !issues.isEmpty {
            reviewListErrorMessage = issues.prefix(3).joined(separator: "; ")
        }
    }

    func loadNextImportedTMDBGroup() async {
        guard hasNextQueuedImportedTMDB else { return }
        guard !queuedImportedTMDBBatches.isEmpty else { return }

        let nextIndex = queuedImportedTMDBIndex + 1
        guard queuedImportedTMDBBatches.indices.contains(nextIndex) else { return }

        isLoadingReviewList = true
        defer { isLoadingReviewList = false }

        queuedImportedTMDBIndex = nextIndex
        let batch = queuedImportedTMDBBatches[nextIndex]

        reviewListItems = []
        selectedReviewListItemID = nil
        mergeReviewListItems(batch.items, importWins: true)
        await enrichImportedReviewItems(progressPrefix: "Loaded \(importQueuedTMDBProgressText).")
        updateQueuedTMDBProgressInfo(importedTotalCount: nil)
    }

    func loadReviewListFromCurrentSelection() async {
        reviewListErrorMessage = ""
        reviewListInfoMessage = ""
        clearQueuedImportedTMDBState()

        let tmdbKey = tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let introKey = optional(theIntroDBAPIKey)

        guard !tmdbKey.isEmpty else {
            reviewListErrorMessage = "TMDB API key missing"
            return
        }

        guard let tmdbId = intOrNil(tmdbIdText), tmdbId > 0 else {
            reviewListErrorMessage = "TMDB ID is required"
            return
        }

        // TMDB-driven list review should always reflect only the current selection.
        reviewListItems = []
        selectedReviewListItemID = nil

        isLoadingReviewList = true
        defer { isLoadingReviewList = false }

        do {
            if selectedMediaType == .movie {
                let movieRuntimeMinutes = (try? await tmdbClient.fetchMovieRuntimeMinutes(tmdbId: tmdbId, apiKey: tmdbKey)) ?? nil
                let tmdbDurationMs = movieRuntimeMinutes.map { max(0, $0) * 60_000 }
                let query = MediaQuery(
                    tmdbId: tmdbId,
                    imdbId: optional(imdbIdText),
                    season: nil,
                    episode: nil
                )
                let preferredDurationMs = await preferredPublicVersionDurationMs(for: query)
                var publicQuery = query
                publicQuery.durationMs = preferredDurationMs
                let publicResponse = try await theIntroDBClient.fetchMedia(query: publicQuery, apiKey: nil)
                var ownResponse: ServiceResponse<TheIntroDBMediaResponse>?
                if let introKey {
                    ownResponse = try? await theIntroDBClient.fetchMedia(query: publicQuery, apiKey: introKey)
                }
                let resolvedDurationMs = AppModel.resolvePreferredDurationMs(
                    publicPayloadDurationMs: publicResponse.payload.durationMs,
                    publicVersionDurationMs: preferredDurationMs,
                    tmdbDurationMs: tmdbDurationMs,
                    fallbackDurationMs: ownResponse?.payload.durationMs
                )
                let item = AppModel.makeReviewItem(
                    title: selectedTitleFallback(tmdbId: tmdbId),
                    mediaType: .movie,
                    tmdbId: tmdbId,
                    imdbId: optional(imdbIdText),
                    season: nil,
                    episode: nil,
                    posterURL: matchedPosterURL,
                    videoDurationMs: resolvedDurationMs,
                    sourceLabel: "TMDB + TheIntroDB",
                    groupedSegments: publicResponse.payload.groupedSegments(),
                    draftGroupedSegments: ownResponse?.payload.groupedSegments()
                )
                mergeReviewListItems([item], importWins: false)
                selectReviewListItem(item.id)
                reviewListInfoMessage = "Loaded list review for movie TMDB \(tmdbId)"
                return
            }

            let metadata = try await tmdbClient.fetchTVEpisodeReferences(tmdbId: tmdbId, apiKey: tmdbKey)
            let title = metadata.seriesTitle
            let posterURL = metadata.posterURL ?? matchedPosterURL
            let tmdbEpisodeDurationMs = metadata.episodeRuntimeMinutes.map { max(0, $0) * 60_000 }

            let episodes = metadata.episodes
            var loadedCount = 0

            func loadEpisode(_ ref: TMDBTVEpisodeReference) async -> ListReviewItem {
                func placeholderItem(sourceLabel: String) -> ListReviewItem {
                    AppModel.makeReviewItem(
                        title: title,
                        mediaType: .tv,
                        tmdbId: tmdbId,
                        imdbId: nil,
                        season: ref.season,
                        episode: ref.episode,
                        posterURL: posterURL,
                        videoDurationMs: tmdbEpisodeDurationMs,
                        sourceLabel: sourceLabel,
                        groupedSegments: [:],
                        draftGroupedSegments: nil
                    )
                }

                do {
                    let query = MediaQuery(
                        tmdbId: tmdbId,
                        imdbId: nil,
                        season: ref.season,
                        episode: ref.episode
                    )
                    let preferredDurationMs = await preferredPublicVersionDurationMs(for: query)
                    var publicQuery = query
                    publicQuery.durationMs = preferredDurationMs

                    let publicResponse = try await theIntroDBClient.fetchMedia(query: publicQuery, apiKey: nil)
                    var ownResponse: ServiceResponse<TheIntroDBMediaResponse>?
                    if let introKey {
                        ownResponse = try? await self.theIntroDBClient.fetchMedia(query: publicQuery, apiKey: introKey)
                    }

                    let resolvedDurationMs = AppModel.resolvePreferredDurationMs(
                        publicPayloadDurationMs: publicResponse.payload.durationMs,
                        publicVersionDurationMs: preferredDurationMs,
                        tmdbDurationMs: tmdbEpisodeDurationMs,
                        fallbackDurationMs: ownResponse?.payload.durationMs
                    )
                    let maxPublicSegmentPointMs = publicResponse.payload.groupedSegments()
                        .values
                        .flatMap { $0 }
                        .compactMap { $0.endMs ?? $0.startMs }
                        .max() ?? 0

                    let needsEpisodeRuntimeFallback = (resolvedDurationMs ?? 0) <= 0
                        || ((resolvedDurationMs ?? 0) > 0 && maxPublicSegmentPointMs > (resolvedDurationMs ?? 0))

                    let episodeRuntimeFallbackMs: Int?
                    if needsEpisodeRuntimeFallback {
                        let episodeRuntimeMinutes = try? await self.tmdbClient.fetchTVEpisodeRuntimeMinutes(
                            tmdbId: tmdbId,
                            season: ref.season,
                            episode: ref.episode,
                            apiKey: tmdbKey
                        )
                        episodeRuntimeFallbackMs = episodeRuntimeMinutes.map { max(0, $0) * 60_000 }
                    } else {
                        episodeRuntimeFallbackMs = nil
                    }

                    let effectiveDurationMs = if needsEpisodeRuntimeFallback,
                                                 let episodeRuntimeFallbackMs,
                                                 episodeRuntimeFallbackMs > maxPublicSegmentPointMs {
                        episodeRuntimeFallbackMs
                    } else {
                        resolvedDurationMs
                    }

                    return AppModel.makeReviewItem(
                        title: title,
                        mediaType: .tv,
                        tmdbId: tmdbId,
                        imdbId: nil,
                        season: ref.season,
                        episode: ref.episode,
                        posterURL: posterURL,
                        videoDurationMs: effectiveDurationMs,
                        sourceLabel: "TMDB + TheIntroDB",
                        groupedSegments: publicResponse.payload.groupedSegments(),
                        draftGroupedSegments: ownResponse?.payload.groupedSegments()
                    )
                } catch {
                    return placeholderItem(sourceLabel: "TMDB")
                }
            }

            for ref in episodes {
                let item = await loadEpisode(ref)
                mergeReviewListItems([item], importWins: false)
                loadedCount += 1

                if selectedReviewListItemID == nil, let firstID = reviewListItems.first?.id {
                    selectReviewListItem(firstID)
                }

                reviewListInfoMessage = "Loaded \(loadedCount)/\(episodes.count) episode item(s) for \(title)"
            }

            if reviewListItems.isEmpty {
                reviewListErrorMessage = "No episode segments found for series TMDB \(tmdbId)"
                return
            }
            reviewListInfoMessage = "Loaded \(reviewListItems.count) episode item(s) for \(title)"
        } catch {
            reviewListErrorMessage = "List load failed: \(error.localizedDescription)"
        }
    }

    func selectReviewListItem(_ itemID: String) {
        guard let item = reviewListItems.first(where: { $0.id == itemID }) else { return }
        selectedReviewListItemID = itemID
        applyReviewItemToEditor(item)
        zoomLevel = minimumZoomLevel
    }

    func submitReviewListItem(_ itemID: String) async {
        guard let index = reviewListItems.firstIndex(where: { $0.id == itemID }) else { return }
        var item = reviewListItems[index]

        let apiKey = theIntroDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            reviewListErrorMessage = "TheIntroDB API key missing"
            return
        }
        guard let tmdbId = item.tmdbId, tmdbId > 0 else {
            reviewListErrorMessage = "TMDB ID missing for submit"
            return
        }

        item.isSubmitting = true
        item.submitMessage = nil
        reviewListItems[index] = item

        var failedSegments: [String] = []
        var successfulNoSegmentSubmissions: Set<SegmentType> = []

        let groupedSegmentsSource = item.draftSegmentGroups.isEmpty
            ? item.segmentGroups
            : item.draftSegmentGroups
        let itemNoSegmentFlags = AppModel.normalizedNoSegmentFlags(from: item.noSegmentFlags)

        for segmentType in SegmentType.allCases {
            if itemNoSegmentFlags[segmentType] == true {
                let noSegmentDraft = SubmissionDraft(
                    tmdbId: tmdbId,
                    imdbId: item.imdbId,
                    mediaType: item.mediaType,
                    segment: segmentType,
                    season: item.mediaType == .tv ? item.season : nil,
                    episode: item.mediaType == .tv ? item.episode : nil,
                    startMs: nil,
                    endMs: nil,
                    isNoSegment: true
                )

                do {
                    let request = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: noSegmentDraft, videoDurationMs: item.videoDurationMs)
                    _ = try await theIntroDBClient.submit(request, apiKey: apiKey)
                    successfulNoSegmentSubmissions.insert(segmentType)
                } catch {
                    failedSegments.append("No \(segmentType.displayName): \(error.localizedDescription)")
                }
                continue
            }

            let groupedRanges = groupedSegmentsSource[segmentType] ?? []
            let rangesToUpload: [SegmentRange]
            if groupedRanges.isEmpty, let fallback = item.draftSegments[segmentType] ?? item.segments[segmentType] {
                rangesToUpload = [fallback]
            } else {
                rangesToUpload = groupedRanges
            }

            for (rangeIndex, segment) in rangesToUpload.enumerated() {
                guard let startMs = segment.startMs else { continue }

                let draft = SubmissionDraft(
                    tmdbId: tmdbId,
                    imdbId: item.imdbId,
                    mediaType: item.mediaType,
                    segment: segmentType,
                    season: item.mediaType == .tv ? item.season : nil,
                    episode: item.mediaType == .tv ? item.episode : nil,
                    startMs: startMs,
                    endMs: segment.endMs,
                    isNoSegment: false
                )

                do {
                    let request = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft, videoDurationMs: item.videoDurationMs)
                    _ = try await theIntroDBClient.submit(request, apiKey: apiKey)
                } catch {
                    failedSegments.append("\(segmentType.displayName) #\(rangeIndex + 1): \(error.localizedDescription)")
                }
            }
        }

        guard let updatedIndex = reviewListItems.firstIndex(where: { $0.id == itemID }) else { return }
        reviewListItems[updatedIndex].isSubmitting = false
        for segmentType in successfulNoSegmentSubmissions {
            reviewListItems[updatedIndex].noSegmentFlags[segmentType] = false
        }

        if failedSegments.isEmpty {
            reviewListItems[updatedIndex].submitMessage = "Submitted"
            reviewListInfoMessage = "Submitted \(reviewListItems[updatedIndex].rowLabel)"
        } else {
            reviewListItems[updatedIndex].submitMessage = failedSegments.first
            reviewListErrorMessage = failedSegments.joined(separator: "; ")
        }

        if selectedReviewListItemID == itemID {
            noSegmentFlags = AppModel.normalizedNoSegmentFlags(from: reviewListItems[updatedIndex].noSegmentFlags)
        }
    }

    func submitReviewGroup(_ groupKey: String) async {
        let itemIDs = reviewListItems
            .filter { $0.groupKey == groupKey }
            .map(\.id)

        for itemID in itemIDs {
            await submitReviewListItem(itemID)
        }
    }

    func removeReviewGroup(_ groupKey: String) {
        guard !groupKey.isEmpty else { return }

        let selectedID = selectedReviewListItemID
        reviewListItems.removeAll { $0.groupKey == groupKey }

        if let selectedID,
           reviewListItems.contains(where: { $0.id == selectedID }) {
            return
        }

        if let first = reviewListItems.first {
            selectedReviewListItemID = first.id
            if appMode == .listReview {
                applyReviewItemToEditor(first)
            }
        } else {
            selectedReviewListItemID = nil
            serverSegments = AppModel.makeSegmentDictionary(defaultValue: [])
            localDrafts = AppModel.makeSegmentDictionary(defaultValue: [])
            noSegmentFlags = AppModel.makeSegmentDictionary(defaultValue: false)
            reviewListInfoMessage = ""
        }
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
        tmdbTitleHintsByID[candidate.tmdbId] = candidate.title
        tmdbIdText = String(candidate.tmdbId)
        if let imdbId = candidate.imdbId {
            imdbIdText = imdbId
        }
        selectedMediaType = candidate.mediaType
        seasonText = candidate.season.map(String.init) ?? seasonText
        episodeText = candidate.episode.map(String.init) ?? episodeText
        matchedPosterURL = candidate.posterURL
        tmdbGenreNames = []
    }

    func saveKeysToKeychain() {
        guard shouldAccessKeychain else { return }

        let bundle = APIKeysBundle(
            theIntroDBAPIKey: theIntroDBAPIKey,
            introDBAPIKey: introDBAPIKey,
            tmdbAPIKey: tmdbAPIKey,
            openSubtitlesAPIKey: openSubtitlesAPIKey
        )

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(bundle),
              let payload = String(data: data, encoding: .utf8)
        else {
            errorMessage = "Could not encode API keys for Keychain"
            return
        }

        if keychain.set(payload, for: .apiKeysBundle) {
            infoMessage = "API keys saved to Keychain"
            errorMessage = ""
        } else {
            errorMessage = "Could not save API keys to Keychain"
        }
    }

    private func tryLoadKeysFromKeychain(allowUserInteraction: Bool, announceOutcome: Bool) {
        guard shouldAccessKeychain else { return }

        // Prefer a single bundled secret to minimize Keychain prompts.
        if let payload = keychain.get(.apiKeysBundle, allowUserInteraction: allowUserInteraction),
           let data = payload.data(using: .utf8),
           let bundle = try? JSONDecoder().decode(APIKeysBundle.self, from: data) {
            var loadedCount = 0
            if !bundle.theIntroDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedCount += 1
            }
            if !bundle.introDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedCount += 1
            }
            if !bundle.tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedCount += 1
            }
            if !bundle.openSubtitlesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedCount += 1
            }

            theIntroDBAPIKey = bundle.theIntroDBAPIKey
            introDBAPIKey = bundle.introDBAPIKey
            tmdbAPIKey = bundle.tmdbAPIKey
            openSubtitlesAPIKey = bundle.openSubtitlesAPIKey

            guard announceOutcome else { return }
            if loadedCount > 0 {
                infoMessage = "Loaded \(loadedCount) API key(s) from Keychain"
                errorMessage = ""
            } else {
                infoMessage = ""
                errorMessage = "No API keys found in Keychain"
            }
            return
        }

        // Fallback for existing users with legacy per-key entries.
        let theIntro = keychain.get(.theIntroDBAPIKey, allowUserInteraction: allowUserInteraction)
        let intro = keychain.get(.introDBAPIKey, allowUserInteraction: allowUserInteraction)
        let tmdb = keychain.get(.tmdbAPIKey, allowUserInteraction: allowUserInteraction)
        let openSubs = keychain.get(.openSubtitlesAPIKey, allowUserInteraction: allowUserInteraction)

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
        if let openSubs {
            openSubtitlesAPIKey = openSubs
            loadedCount += 1
        }

        if loadedCount > 0 {
            saveKeysToKeychain()
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

    func fetchMedia(
        prefillDrafts: Bool = false,
        skipAutoRecapDetection: Bool = false,
        refreshSceneDetection: Bool = true
    ) async {
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

        if refreshSceneDetection {
            scheduleSceneDetection(videoLoadID: videoLoadID)
        }

        if !skipAutoRecapDetection && isAutoRecapDetectionEnabled && !isDetectingRecap {
            scheduleLocalSubtitleLoadIfNeeded(videoLoadID: videoLoadID)
            scheduleAutoRecapDetection()
        }
    }

    private func cancelLocalSubtitleLoadTasks() {
        for task in localSubtitleLoadTasks.values {
            task.cancel()
        }
        localSubtitleLoadTasks.removeAll()
    }

    private func scheduleLocalSubtitleLoadIfNeeded(videoLoadID: Int) {
        guard self.videoLoadID == videoLoadID else { return }
        guard selectedMediaType == .tv else { return }
        guard let season = intOrNil(seasonText), season >= 0 else { return }
        guard let episode = intOrNil(episodeText), episode >= 2 else { return }
        let imdbId = imdbIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imdbId.isEmpty else { return }

        let rootPath = localOpenSubtitlesDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return }

        _ = localSubtitleLoadTask(rootPath: rootPath, imdbId: imdbId, season: season, episode: episode)
        _ = localSubtitleLoadTask(rootPath: rootPath, imdbId: imdbId, season: season, episode: episode - 1)
    }

    private func localSubtitleLoadTask(
        rootPath: String,
        imdbId: String,
        season: Int,
        episode: Int
    ) -> Task<(text: String, fileExtension: String, language: String), Error> {
        let key = LocalSubtitleEpisodeKey(rootPath: rootPath, season: season, episode: episode)
        if let task = localSubtitleLoadTasks[key] {
            return task
        }

        let task = Task.detached(priority: .userInitiated) {
            return try Self.localSubtitleTextForEpisode(
                rootPath: rootPath,
                imdbId: imdbId,
                season: season,
                episode: episode
            )
        }
        localSubtitleLoadTasks[key] = task
        return task
    }

    private func loadLocalSubtitleText(
        rootPath: String,
        imdbId: String,
        season: Int,
        episode: Int
    ) async throws -> (text: String, fileExtension: String, language: String) {
        let task = localSubtitleLoadTask(rootPath: rootPath, imdbId: imdbId, season: season, episode: episode)
        do {
            return try await task.value
        } catch {
            localSubtitleLoadTasks.removeValue(
                forKey: LocalSubtitleEpisodeKey(rootPath: rootPath, season: season, episode: episode)
            )
            throw error
        }
    }

    private func scheduleAutoRecapDetection() {
        pendingDeferredRecapTask?.cancel()
        let scheduledForLoadID = videoLoadID

        pendingDeferredRecapTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            await MainActor.run {
                guard self.videoLoadID == scheduledForLoadID else { return }
                guard self.isAutoRecapDetectionEnabled, !self.isDetectingRecap else { return }
                Task { await self.detectRecap() }
            }
        }
    }

    func setDraftStart(_ segment: SegmentType) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }
        noSegmentFlags[segment] = false
        let playheadMs = max(0, min(timeline.currentTimeMs, SegmentValidator.maxTimestampMs))

        func applyAutoDurationSeek(startMs: Int, endMs: Int?) {
            guard let durationMs = suggestedDurationTemplateMs(for: segment) else { return }
            var targetMs = min(startMs + durationMs, SegmentValidator.maxTimestampMs)
            if let endMs {
                targetMs = min(targetMs, endMs)
            }
            frameStripFineModeToken &+= 1
            seekTimeline(to: targetMs)
        }

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
                    applyAutoDurationSeek(startMs: adjusted.startMs, endMs: adjusted.endMs)
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
                    applyAutoDurationSeek(startMs: adjusted.startMs, endMs: adjusted.endMs)
                    return
                }
            }

            let startMs = nonOverlappingStartMs(boundaryStart)
            drafts.append(SegmentDraft(startMs: startMs, endMs: nil))
            localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
            errorMessage = ""
            applyAutoDurationSeek(startMs: startMs, endMs: nil)
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
                applyAutoDurationSeek(startMs: adjusted.startMs, endMs: adjusted.endMs)
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
                applyAutoDurationSeek(startMs: adjusted.startMs, endMs: adjusted.endMs)
                return
            }
        }

        let startMs = nonOverlappingStartMs(timeline.currentTimeMs)

        drafts.append(SegmentDraft(startMs: startMs, endMs: nil))
        localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
        errorMessage = ""
        applyAutoDurationSeek(startMs: startMs, endMs: nil)
    }

    func setDraftEnd(_ segment: SegmentType) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }
        noSegmentFlags[segment] = false

        func applyAutoDurationSeek(endMs: Int, shouldSeek: Bool) {
            guard shouldSeek else { return }
            guard let durationMs = suggestedDurationTemplateMs(for: segment) else { return }
            let targetMs = max(0, endMs - durationMs)
            frameStripFineModeToken &+= 1
            seekTimeline(to: targetMs)
        }

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
                applyAutoDurationSeek(endMs: adjusted.endMs, shouldSeek: false)
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
            applyAutoDurationSeek(endMs: endMs, shouldSeek: true)
            return
        }

        if let containingIndex = drafts.lastIndex(where: {
            guard let startMs = $0.startMs, let endMs = $0.endMs else { return false }
            return playheadMs > startMs && playheadMs < endMs
        }) {
            drafts[containingIndex].endMs = playheadMs
            localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
            errorMessage = ""
            applyAutoDurationSeek(endMs: playheadMs, shouldSeek: false)
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
           let previousEndMarker = nearestDraftEnding(atOrBefore: playheadMs),
           previousEndMarker.endMs < playheadMs
        {
            let previousEnd = previousEndMarker.endMs
            let candidate = normalizeRange(startMs: previousEnd, endMs: playheadMs)
            if let adjusted = adjustedNonOverlappingRange(
                candidate: candidate,
                excluding: (previousEndMarker.segment, previousEndMarker.index)
            ) {
                drafts.append(SegmentDraft(startMs: adjusted.startMs, endMs: adjusted.endMs))
                localDrafts[segment] = normalizeAndSortDraftsByStart(drafts)
                errorMessage = ""
                applyAutoDurationSeek(endMs: adjusted.endMs, shouldSeek: true)
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
        applyAutoDurationSeek(endMs: endMs, shouldSeek: true)
    }

    func setDraftRange(_ segment: SegmentType, startMs: Int, endMs: Int) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }
        noSegmentFlags[segment] = false
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

    // MARK: - Jump to segment boundary

    /// First jump selects the nearest start timestamp from current playhead position,
    /// then repeated jumps rotate in that chosen direction.
    func jumpToNextStart(_ segment: SegmentType) {
        let timestamps: [Int] = Array(
            Set(
                drafts(for: segment).compactMap { draft in
                    draft.startMs ?? 0
                }
            )
        ).sorted()
        guard !timestamps.isEmpty else { return }
        let result = jumpTimestampFromPlayheadAndRotate(
            from: timeline.currentTimeMs,
            in: timestamps,
            toleranceMs: frameDurationMs,
            previousDirection: jumpDirectionByStartSegment[segment]
        )
        jumpDirectionByStartSegment[segment] = result.direction
        frameStripFineModeToken &+= 1
        seekTimeline(to: result.timestamp)
    }

    /// Same behavior as `jumpToNextStart`, applied to end timestamps.
    func jumpToNextEnd(_ segment: SegmentType) {
        let timestamps: [Int] = Array(
            Set(
                drafts(for: segment).compactMap { draft in
                    draft.endMs ?? effectiveDurationMs
                }
            )
        ).sorted()
        guard !timestamps.isEmpty else { return }
        let result = jumpTimestampFromPlayheadAndRotate(
            from: timeline.currentTimeMs,
            in: timestamps,
            toleranceMs: frameDurationMs,
            previousDirection: jumpDirectionByEndSegment[segment]
        )
        jumpDirectionByEndSegment[segment] = result.direction
        frameStripFineModeToken &+= 1
        seekTimeline(to: result.timestamp)
    }

    // MARK: - Nudge nearest boundary

    /// Moves the nearest draft boundary by `deltaMs`. Positive = forward, negative = backward.
    func nudgeNearestBoundary(by deltaMs: Int) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }

        let playheadMs = timeline.currentTimeMs

        var best: (segment: SegmentType, index: Int, boundaryMs: Int, isEnd: Bool, distance: Int)?

        // When two boundaries are equidistant, prefer the one that moves naturally:
        // moving forward → prefer end; moving backward → prefer start.
        let preferEnd = deltaMs >= 0
        for segmentType in SegmentType.allCases {
            for (index, draft) in drafts(for: segmentType).enumerated() {
                if let startMs = draft.startMs {
                    let d = abs(startMs - playheadMs)
                    let beats = best == nil || d < best!.distance || (d == best!.distance && !preferEnd && best!.isEnd)
                    if beats { best = (segmentType, index, startMs, false, d) }
                }
                if let endMs = draft.endMs {
                    let d = abs(endMs - playheadMs)
                    let beats = best == nil || d < best!.distance || (d == best!.distance && preferEnd && !best!.isEnd)
                    if beats { best = (segmentType, index, endMs, true, d) }
                }
            }
        }

        guard let hit = best else { return }

      let newMs = max(0, min(hit.boundaryMs + deltaMs, SegmentValidator.maxTimestampMs))

        let currentHitDrafts = drafts(for: hit.segment)
        guard currentHitDrafts.indices.contains(hit.index) else { return }

        var updates: [(segment: SegmentType, index: Int, isEnd: Bool)] = [(hit.segment, hit.index, hit.isEnd)]

        // Collect adjacent shared-boundary segments (no clamping of newMs here — invalid ones get deleted below).
        for segmentType in SegmentType.allCases {
            let segmentDrafts = drafts(for: segmentType)
            for (index, draft) in segmentDrafts.enumerated() {
                guard !(segmentType == hit.segment && index == hit.index) else { continue }

                if hit.isEnd,
                   let start = draft.startMs,
                   start == hit.boundaryMs {
                    updates.append((segmentType, index, false))
                } else if !hit.isEnd,
                          let end = draft.endMs,
                          end == hit.boundaryMs {
                    updates.append((segmentType, index, true))
                }
            }
        }

        var touchedSegments = Set<SegmentType>()
        for update in updates {
            var segDrafts = drafts(for: update.segment)
            guard segDrafts.indices.contains(update.index) else { continue }
            let currentDraft = segDrafts[update.index]

            if update.segment == hit.segment && update.index == hit.index {
                // Hit segment: if the boundary crosses the opposite boundary, flip (normalize) the segment.
                if update.isEnd, let start = currentDraft.startMs, newMs < start {
                    // End crossed below start → flip: new range is newMs...start.
                    segDrafts[update.index].endMs = start
                    if (update.segment == .intro || update.segment == .recap), newMs == 0 {
                        segDrafts[update.index].startMs = nil
                    } else {
                        segDrafts[update.index].startMs = newMs
                    }
                } else if !update.isEnd, let end = currentDraft.endMs, newMs > end {
                    // Start crossed above end → flip: new range is end...newMs.
                    segDrafts[update.index].startMs = end
                    segDrafts[update.index].endMs = newMs
                } else {
                    // No crossing: apply normally.
                    if update.isEnd {
                        segDrafts[update.index].endMs = newMs
                    } else {
                        if (update.segment == .intro || update.segment == .recap), newMs == 0 {
                            segDrafts[update.index].startMs = nil
                        } else {
                            segDrafts[update.index].startMs = newMs
                        }
                    }
                }
            } else {
                // Adjacent shared boundary: if applying newMs would make this segment invalid, delete it.
                let wouldBeInvalid: Bool
                if update.isEnd, let start = currentDraft.startMs {
                    wouldBeInvalid = newMs < start
                } else if !update.isEnd, let end = currentDraft.endMs {
                    wouldBeInvalid = newMs > end
                } else {
                    wouldBeInvalid = false
                }
                if wouldBeInvalid {
                    segDrafts.remove(at: update.index)
                } else if update.isEnd {
                    segDrafts[update.index].endMs = newMs
                } else {
                    if (update.segment == .intro || update.segment == .recap), newMs == 0 {
                        segDrafts[update.index].startMs = nil
                    } else {
                        segDrafts[update.index].startMs = newMs
                    }
                }
            }
            localDrafts[update.segment] = normalizeAndSortDraftsByStart(segDrafts)
            touchedSegments.insert(update.segment)
        }

        // Cascade-push: boundaries of OTHER drafts that fall in the swept range get moved to newMs.
        // E.g. moving intro.start 30000→28000 should also pull recap.end=29000→28000.
        let oldMs = hit.boundaryMs
        let sweptLo = min(newMs, oldMs)
        let sweptHi = max(newMs, oldMs)
        for segmentType in SegmentType.allCases {
            var segDrafts = drafts(for: segmentType)
            var changed = false
            for index in stride(from: segDrafts.count - 1, through: 0, by: -1) {
                let draft = segDrafts[index]
                // Skip the boundaries already handled above.
                if updates.contains(where: { $0.segment == segmentType && $0.index == index }) { continue }
                if !hit.isEnd, let endMs = draft.endMs, endMs > sweptLo, endMs < sweptHi {
                    // Start moved backward: pull this end to newMs; delete if that would cross its own start.
                    if newMs < (draft.startMs ?? 0) {
                        segDrafts.remove(at: index)
                    } else {
                        segDrafts[index].endMs = newMs
                    }
                    changed = true
                } else if hit.isEnd, let startMs = draft.startMs, startMs > sweptLo, startMs < sweptHi {
                    // End moved forward: push this start to newMs; delete if that would cross its own end.
                    if newMs > (draft.endMs ?? SegmentValidator.maxTimestampMs) {
                        segDrafts.remove(at: index)
                    } else {
                        segDrafts[index].startMs = newMs
                    }
                    changed = true
                }
            }
            if changed {
                localDrafts[segmentType] = normalizeAndSortDraftsByStart(segDrafts)
                touchedSegments.insert(segmentType)
            }
        }

        if !touchedSegments.isEmpty {
            errorMessage = ""
            seekTimeline(to: newMs)
        }
    }

    /// Returns the frame duration in ms for use in nudge operations (falls back to 1000/30).
    var frameDurationMs: Int {
        let sec = timeline.frameDurationSeconds
        guard sec > 0 else { return Int((1000.0 / 30.0).rounded()) }
        return max(1, Int((sec * 1000).rounded()))
    }

    // MARK: - Open next episode

    /// URL of the next episode video file in the same directory, or nil if none found.
    var nextEpisodeURL: URL? {
        guard let currentURL = selectedVideoURL else { return nil }
        let dir = currentURL.deletingLastPathComponent()
        let currentName = currentURL.lastPathComponent

        let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "avi", "m4v", "ts", "wmv"]

        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let videoFiles = siblings
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard let currentIndex = videoFiles.firstIndex(where: { $0.lastPathComponent == currentName }),
              currentIndex + 1 < videoFiles.count
        else { return nil }

        return videoFiles[currentIndex + 1]
    }

    func openNextEpisode() {
        guard let url = nextEpisodeURL else { return }
        loadVideo(url: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.requestPlayerFocus()
        }
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
        noSegmentFlags[segment] = false
        updateDraft(segment, index: index) { draft in
            draft.startMs = max(0, ms)
        }
    }

    func setDraftEndMs(_ segment: SegmentType, index: Int, ms: Int) {
        let before = beginSegmentChangeCapture()
        defer { endSegmentChangeCapture(before: before) }
        noSegmentFlags[segment] = false
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

    func setNoSegment(_ segment: SegmentType, enabled: Bool) {
        noSegmentFlags[segment] = enabled
        if enabled {
            localDrafts[segment] = []
            submissionMessages[segment] = ""
        }
        syncSelectedReviewItemFromEditorIfNeeded()
    }

    func toggleNoSegment(_ segment: SegmentType) {
        setNoSegment(segment, enabled: !(noSegmentFlags[segment] ?? false))
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
        let uploadVideoLoadID = videoLoadID
        errorMessage = ""
        infoMessage = ""
        usageMessage = ""

        guard let context = makeUploadContext() else { return }

        // No-segment upload path (TheIntroDB only)
        if noSegmentFlags[segment] == true {
            guard let theIntroKey = context.theIntroDBAPIKey,
                  let tmdbId = context.tmdbId, tmdbId > 0 else {
                errorMessage = "TheIntroDB API key and TMDB ID are required to submit 'no \(segment.displayName)'"
                return
            }
            _ = theIntroKey
            let noSegmentDraft = SubmissionDraft(
                tmdbId: tmdbId,
                imdbId: context.imdbId,
                mediaType: selectedMediaType,
                segment: segment,
                season: selectedMediaType == .tv ? context.season : nil,
                episode: selectedMediaType == .tv ? context.episode : nil,
                startMs: nil,
                endMs: nil,
                isNoSegment: true
            )
            beginSegmentUploadTracking(videoLoadID: uploadVideoLoadID, segment: segment)
            defer { endSegmentUploadTracking(videoLoadID: uploadVideoLoadID, segment: segment) }
            infoMessage = "Submitting no-\(segment.displayName) to TheIntroDB\u{2026}"
            do {
                let usage = try await uploadSingleDraft(noSegmentDraft, service: .theIntroDB, context: context)
                guard videoLoadID == uploadVideoLoadID else { return }
                noSegmentFlags[segment] = false
                submissionMessages[segment] = "No \(segment.displayName) submitted to TheIntroDB"
                infoMessage = "No \(segment.displayName) submission accepted"
                usageMessage = usage?.shortDescription ?? ""
                await fetchMedia(skipAutoRecapDetection: true, refreshSceneDetection: false)
            } catch {
                guard videoLoadID == uploadVideoLoadID else { return }
                errorMessage = "No-segment upload failed: \(error.localizedDescription)"
                submissionMessages[segment] = "Upload failed"
            }
            return
        }

        let targetServices = uploadTargets(for: segment, context: context)
        guard !targetServices.isEmpty else {
            errorMessage = "No compatible API/key for \(segment.displayName). Provide TheIntroDB key with TMDB ID and/or IntroDB key with IMDB+season+episode."
            return
        }
        let segmentDrafts = uploadableDrafts(for: segment)
        let excludedAutoRecapDrafts = drafts(for: segment).filter(isAutoRecapDraft)

        guard !segmentDrafts.isEmpty else {
            errorMessage = "No draft segments to upload for \(segment.displayName)"
            return
        }

        let allDrafts: [SubmissionDraft] = segmentDrafts.map { draft in
            makeSubmissionDraft(segment: segment, draft: draft, context: context)
        }

        // IntroDB only accepts one segment per type — pick the longest
        let introDBDraftIndex: Int? = targetServices.contains(.introDB) ? allDrafts.enumerated().max(by: { a, b in
            let durA = (a.element.endMs ?? effectiveDurationMs) - (a.element.startMs ?? 0)
            let durB = (b.element.endMs ?? effectiveDurationMs) - (b.element.startMs ?? 0)
            return durA < durB
        })?.offset : nil

        beginSegmentUploadTracking(videoLoadID: uploadVideoLoadID, segment: segment)
        defer { endSegmentUploadTracking(videoLoadID: uploadVideoLoadID, segment: segment) }

        infoMessage = "Uploading \(segment.displayName) to \(serviceListLabel(uploadTargets(for: segment, context: context)))..."

        var uploadCount = 0
        var uploadAttemptCount = 0
        var lastUsage: UsageHeaders?
        var uploadErrors: [String] = []

            await withTaskGroup(of: (Int, SegmentService, Result<UsageHeaders?, Error>).self) { group in
                for (index, submissionDraft) in allDrafts.enumerated() {
                    for service in targetServices {
                        if service == .introDB, let longest = introDBDraftIndex, index != longest { continue }
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

        guard videoLoadID == uploadVideoLoadID else {
            return
        }

        if !uploadErrors.isEmpty {
            submissionMessages[segment] = "Uploaded \(uploadCount)/\(uploadAttemptCount) requests with errors"
            errorMessage = uploadErrors.joined(separator: "; ")
        } else {
            submissionMessages[segment] = "Uploaded \(uploadCount) request(s) to \(serviceListLabel(targetServices))"
            infoMessage = "Segment \(segment.displayName): \(uploadCount) upload(s) to \(serviceListLabel(targetServices)) completed"
        }

        usageMessage = lastUsage?.shortDescription ?? ""
        localDrafts[segment] = normalizeAndSortDraftsByStart(excludedAutoRecapDrafts)
        resetSegmentHistory()

        await fetchMedia(skipAutoRecapDetection: true, refreshSceneDetection: false)
    }

    func uploadAllSegments() async {
        let uploadVideoLoadID = videoLoadID
        errorMessage = ""
        infoMessage = ""
        usageMessage = ""

        guard let context = makeUploadContext() else { return }

        beginUploadAllTracking(videoLoadID: uploadVideoLoadID)
        defer { endUploadAllTracking(videoLoadID: uploadVideoLoadID) }

        infoMessage = "Uploading all segments..."

        var totalUploads = 0
        var totalAttemptedUploads = 0
        var lastUsage: UsageHeaders?
        var globalErrors: [String] = []
        var successfulNoSegmentSubmissions: Set<SegmentType> = []

            await withTaskGroup(of: (SegmentType, Int, SegmentService, Result<UsageHeaders?, Error>).self) { group in
                var uploadableDraftsBySegment: [SegmentType: [SegmentDraft]] = [:]
                for segmentType in SegmentType.allCases {
                    if noSegmentFlags[segmentType] == true {
                        guard context.theIntroDBAPIKey != nil,
                              let tmdbId = context.tmdbId,
                              tmdbId > 0
                        else {
                            globalErrors.append("\(segmentType.displayName): no compatible API/key for no-segment")
                            continue
                        }

                        let noSegmentDraft = SubmissionDraft(
                            tmdbId: tmdbId,
                            imdbId: context.imdbId,
                            mediaType: selectedMediaType,
                            segment: segmentType,
                            season: selectedMediaType == .tv ? context.season : nil,
                            episode: selectedMediaType == .tv ? context.episode : nil,
                            startMs: nil,
                            endMs: nil,
                            isNoSegment: true
                        )

                        totalAttemptedUploads += 1
                        group.addTask {
                            do {
                                let usage = try await self.uploadSingleDraft(noSegmentDraft, service: .theIntroDB, context: context)
                                return (segmentType, -1, .theIntroDB, .success(usage))
                            } catch {
                                return (segmentType, -1, .theIntroDB, .failure(error))
                            }
                        }
                        continue
                    }

                    let segmentDrafts = uploadableDrafts(for: segmentType)

                    guard !segmentDrafts.isEmpty else { continue }
                    uploadableDraftsBySegment[segmentType] = segmentDrafts
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
                        if draftIndex == -1 {
                            successfulNoSegmentSubmissions.insert(segmentType)
                            continue
                        }

                        let segmentDrafts = uploadableDraftsBySegment[segmentType] ?? []
                        if draftIndex < segmentDrafts.count {
                            let sourceDraft = segmentDrafts[draftIndex]
                            rememberDurationTemplate(for: segmentType, draft: sourceDraft)
                        }
                    case .failure(let error):
                        if draftIndex == -1 {
                            globalErrors.append("\(service.rawValue) No \(segmentType.displayName): \(error.localizedDescription)")
                        } else {
                            globalErrors.append("\(service.rawValue) \(segmentType.displayName) #\(draftIndex + 1): \(error.localizedDescription)")
                        }
                    }
                }
            }

        guard videoLoadID == uploadVideoLoadID else {
            return
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

        for segmentType in successfulNoSegmentSubmissions {
            noSegmentFlags[segmentType] = false
        }

        let preservedAutoRecapDrafts = normalizeAndSortDraftsByStart(
            drafts(for: .recap).filter(isAutoRecapDraft)
        )
        for segmentType in SegmentType.allCases {
            localDrafts[segmentType] = []
        }
        localDrafts[.recap] = preservedAutoRecapDrafts
        resetSegmentHistory()

        await fetchMedia(skipAutoRecapDetection: true, refreshSceneDetection: false)
    }

    func seekTimeline(to milliseconds: Int) {
        timeline.seek(ms: milliseconds)
    }

    // MARK: - Recap detection

    func detectRecap() async {
        guard selectedMediaType == .tv else {
            recapDetectionMessage = "Recap detection requires a TV episode."
            return
        }
        guard let season = intOrNil(seasonText), season >= 0 else {
            recapDetectionMessage = "Season number required."
            return
        }
        guard let episode = intOrNil(episodeText), episode >= 2 else {
            recapDetectionMessage = "Episode must be ≥ 2 (no previous episode to compare)."
            return
        }
        let imdbId = imdbIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imdbId.isEmpty else {
            recapDetectionMessage = "IMDB ID required for subtitle lookup."
            return
        }
        let apiKey = openSubtitlesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let localSubtitleRootPath = localOpenSubtitlesDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty || !localSubtitleRootPath.isEmpty else {
            recapDetectionMessage = "OpenSubtitles API key or local subtitle folder required."
            return
        }

        isDetectingRecap = true
        recapDetectionMessage = "Searching subtitles…"
        recapHintBuckets = []

        defer { isDetectingRecap = false }

        do {
            let currentSubtitleText: String
            let previousSubtitleText: String
            let currentSubtitleExtension: String
            let previousSubtitleExtension: String
            let subtitleSourceLanguage: String

            if !apiKey.isEmpty {
                // Fetch subtitle file IDs for current and previous episode in parallel.
                async let currentFiles = openSubtitlesClient.searchSubtitles(
                    imdbId: imdbId, season: season, episode: episode,
                    language: nil, apiKey: apiKey
                )
                async let previousFiles = openSubtitlesClient.searchSubtitles(
                    imdbId: imdbId, season: season, episode: episode - 1,
                    language: nil, apiKey: apiKey
                )

                let (currFiles, prevFiles) = try await (currentFiles, previousFiles)

                let preferredLanguage = preferredSubtitleLanguageBySeries[imdbId]
                guard let (chosenLanguage, currFile, prevFile) = chooseSubtitlePair(
                    currentFiles: currFiles,
                    previousFiles: prevFiles,
                    preferredLanguage: preferredLanguage
                ) else {
                    recapDetectionMessage = "No subtitles found for S\(season)E\(episode)."
                    return
                }
                preferredSubtitleLanguageBySeries[imdbId] = chosenLanguage

                recapDetectionMessage = "Downloading subtitles…"

                currentSubtitleText = try await subtitleText(
                    imdbId: imdbId,
                    season: season,
                    episode: episode,
                    language: chosenLanguage,
                    file: currFile,
                    apiKey: apiKey
                )
                previousSubtitleText = try await subtitleText(
                    imdbId: imdbId,
                    season: season,
                    episode: episode - 1,
                    language: chosenLanguage,
                    file: prevFile,
                    apiKey: apiKey
                )
                currentSubtitleExtension = "srt"
                previousSubtitleExtension = "srt"
                subtitleSourceLanguage = chosenLanguage
            } else {
                recapDetectionMessage = "Loading local subtitles…"
                let rootPath = localSubtitleRootPath
                async let currentLocal = loadLocalSubtitleText(
                    rootPath: rootPath,
                    imdbId: imdbId,
                    season: season,
                    episode: episode
                )
                async let previousLocal = loadLocalSubtitleText(
                    rootPath: rootPath,
                    imdbId: imdbId,
                    season: season,
                    episode: episode - 1
                )
                let (resolvedCurrentLocal, resolvedPreviousLocal) = try await (currentLocal, previousLocal)
                currentSubtitleText = resolvedCurrentLocal.text
                previousSubtitleText = resolvedPreviousLocal.text
                currentSubtitleExtension = resolvedCurrentLocal.fileExtension
                previousSubtitleExtension = resolvedPreviousLocal.fileExtension
                subtitleSourceLanguage = resolvedCurrentLocal.language
            }

            recapDetectionMessage = "Analysing…"

            // Offload CPU-heavy parsing + detection to avoid blocking the main thread.
            let (currentEntries, previousEntries, ranges) = await Task.detached(priority: .userInitiated) {
                let curr = currentSubtitleExtension == "ass"
                    ? ASSParser.parse(currentSubtitleText)
                    : SRTParser.parse(currentSubtitleText)
                let prev = previousSubtitleExtension == "ass"
                    ? ASSParser.parse(previousSubtitleText)
                    : SRTParser.parse(previousSubtitleText)
                let r = RecapDetector.detect(current: curr, previous: prev)
                return (curr, prev, r)
            }.value

            let tightenedRanges = tightenRecapRanges(
                ranges: ranges,
                currentEntries: currentEntries,
                previousEntries: previousEntries
            )
            let occupied = occupiedIntervalsForAutoRecap()
            let visibleRanges = subtractOccupiedRanges(tightenedRanges, occupied: occupied)

            if visibleRanges.isEmpty {
                recapDetectionMessage = "No recap found."
                autoRecapDraftKeys = []
                return
            }

            // Mirror detected recap windows into real recap drafts for direct visibility
            // and manual adjustment in the Segment Drafts section.
            let detectedRecapDrafts = autoRecapDrafts(from: visibleRanges)
            localDrafts[.recap] = detectedRecapDrafts
            autoRecapDraftKeys = Set(
                detectedRecapDrafts.compactMap { draftKey(startMs: $0.startMs, endMs: $0.endMs) }
            )

            let duration = effectiveDurationMs
            guard duration > 0 else {
                recapDetectionMessage = "Found \(detectedRecapDrafts.count) recap region(s) — recap drafts were created."
                return
            }

            let bucketCount = timeline.waveformBuckets.count

            recapHintBuckets = RecapDetector.toBuckets(
                ranges: visibleRanges,
                durationMs: duration,
                bucketCount: bucketCount
            )
            let totalMs = detectedRecapDrafts.reduce(0) { total, draft in
                guard let start = draft.startMs, let end = draft.endMs else { return total }
                return total + max(0, end - start)
            }
            let seconds = totalMs / 1000
            recapDetectionMessage = "Found \(detectedRecapDrafts.count) recap region(s) (~\(seconds)s total, lang: \(subtitleSourceLanguage))."

        } catch {
            recapDetectionMessage = "Detection failed: \(error.localizedDescription)"
        }
    }

    func clearRecapHint() {
        recapHintBuckets = []
        recapDetectionMessage = ""
    }

    private func draftKey(startMs: Int?, endMs: Int?) -> String? {
        guard let startMs, let endMs else { return nil }
        return "\(startMs)-\(endMs)"
    }

    func isAutoRecapDraft(_ draft: SegmentDraft) -> Bool {
        guard let key = draftKey(startMs: draft.startMs, endMs: draft.endMs) else { return false }
        return autoRecapDraftKeys.contains(key)
    }

    func uploadableDrafts(for segment: SegmentType) -> [SegmentDraft] {
        let presentDrafts = drafts(for: segment)
            .filter { $0.startMs != nil || $0.endMs != nil }
        if segment == .recap {
            return presentDrafts.filter { !isAutoRecapDraft($0) }
        }
        return presentDrafts
    }

    func autoRecapDrafts(from ranges: [(startMs: Int, endMs: Int)]) -> [SegmentDraft] {
        let minDuration = autoRecapMinimumDurationMs
        let mergeGapMs = 10_000
        let durationMs = effectiveDurationMs

        // 1. Drop invalid ranges (end ≤ start).
        let valid = ranges.filter { $0.endMs > $0.startMs }
        // 2. Merge ranges whose gap is ≤ 10 s so nearby windows form one segment.
        let merged = mergeIntervalsWithGap(valid, gapMs: mergeGapMs)
        // 3. Drop segments that are still shorter than the minimum after merging.
        let filtered = merged.filter { $0.endMs - $0.startMs >= minDuration }
        // 4. Map to drafts with open start / open end where appropriate.
        return normalizeAndSortDraftsByStart(
            filtered.map { range in
                let start: Int? = range.startMs == 0 ? nil : range.startMs
                let end: Int? = (durationMs > 0 && range.endMs >= durationMs) ? nil : range.endMs
                return SegmentDraft(startMs: start, endMs: end)
            }
        )
    }

    private func tightenRecapRanges(
        ranges: [(startMs: Int, endMs: Int)],
        currentEntries: [SubtitleEntry],
        previousEntries: [SubtitleEntry]
    ) -> [(startMs: Int, endMs: Int)] {
        RecapDetector.tighten(ranges: ranges, current: currentEntries, previous: previousEntries)
    }

    private func occupiedIntervalsForAutoRecap() -> [(startMs: Int, endMs: Int)] {
        var occupied: [(startMs: Int, endMs: Int)] = []

        for segmentType in SegmentType.allCases {
            for range in serverSegments[segmentType] ?? [] {
                guard let start = range.startMs, let end = range.endMs, end > start else { continue }
                occupied.append((start, end))
            }
        }

        for segmentType in SegmentType.allCases where segmentType != .recap {
            for draft in drafts(for: segmentType) {
                guard let start = draft.startMs, let end = draft.endMs, end > start else { continue }
                occupied.append((start, end))
            }
        }

        return mergeIntervals(occupied)
    }

    private func subtractOccupiedRanges(
        _ ranges: [(startMs: Int, endMs: Int)],
        occupied: [(startMs: Int, endMs: Int)]
    ) -> [(startMs: Int, endMs: Int)] {
        guard !ranges.isEmpty else { return [] }
        guard !occupied.isEmpty else { return mergeIntervals(ranges) }

        var result: [(startMs: Int, endMs: Int)] = []

        for range in mergeIntervals(ranges) {
            var fragments: [(startMs: Int, endMs: Int)] = [range]

            for block in occupied {
                var next: [(startMs: Int, endMs: Int)] = []
                for fragment in fragments {
                    if block.endMs <= fragment.startMs || block.startMs >= fragment.endMs {
                        next.append(fragment)
                        continue
                    }
                    if block.startMs > fragment.startMs {
                        next.append((fragment.startMs, block.startMs))
                    }
                    if block.endMs < fragment.endMs {
                        next.append((block.endMs, fragment.endMs))
                    }
                }
                fragments = next.filter { $0.endMs > $0.startMs }
                if fragments.isEmpty { break }
            }

            result.append(contentsOf: fragments)
        }

        return mergeIntervals(result)
    }

    private func mergeIntervals(
        _ ranges: [(startMs: Int, endMs: Int)]
    ) -> [(startMs: Int, endMs: Int)] {
        mergeIntervalsWithGap(ranges, gapMs: 0)
    }

    private func mergeIntervalsWithGap(
        _ ranges: [(startMs: Int, endMs: Int)],
        gapMs: Int
    ) -> [(startMs: Int, endMs: Int)] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.startMs < $1.startMs }
        var merged: [(startMs: Int, endMs: Int)] = [sorted[0]]

        for range in sorted.dropFirst() {
            if range.startMs <= merged[merged.count - 1].endMs + gapMs {
                merged[merged.count - 1].endMs = max(merged[merged.count - 1].endMs, range.endMs)
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private func subtitleText(
        imdbId: String,
        season: Int,
        episode: Int,
        language: String,
        file: OSSubtitleFile,
        apiKey: String
    ) async throws -> String {
        let cacheKey = SubtitleCacheKey(
            imdbId: imdbId,
            season: season,
            episode: episode,
            language: normalizeLanguage(language)
        )

        if let cached = subtitleTextCache[cacheKey] {
            return cached
        }

        let lang = normalizeLanguage(language)
        if let cached = SubtitleDiskCache.shared.get(
            imdbId: imdbId, season: season, episode: episode, language: lang
        ) {
            subtitleTextCache[cacheKey] = cached
            return cached
        }

        let text = try await openSubtitlesClient.downloadSubtitle(fileId: file.fileId, apiKey: apiKey)
        subtitleTextCache[cacheKey] = text
        SubtitleDiskCache.shared.set(text, imdbId: imdbId, season: season, episode: episode, language: lang)
        return text
    }

    private func chooseSubtitlePair(
        currentFiles: [OSSubtitleFile],
        previousFiles: [OSSubtitleFile],
        preferredLanguage: String?
    ) -> (language: String, current: OSSubtitleFile, previous: OSSubtitleFile)? {
        guard !currentFiles.isEmpty, !previousFiles.isEmpty else { return nil }

        let currentByLanguage = Dictionary(grouping: currentFiles, by: { normalizeLanguage($0.language) })
        let previousByLanguage = Dictionary(grouping: previousFiles, by: { normalizeLanguage($0.language) })
        let commonLanguages = Set(currentByLanguage.keys).intersection(previousByLanguage.keys)
        guard !commonLanguages.isEmpty else { return nil }

        func best(in files: [OSSubtitleFile]) -> OSSubtitleFile? {
            files.max(by: { $0.downloadCount < $1.downloadCount })
        }

        func pick(_ lang: String) -> (language: String, current: OSSubtitleFile, previous: OSSubtitleFile)? {
            guard commonLanguages.contains(lang),
                  let current = best(in: currentByLanguage[lang] ?? []),
                  let previous = best(in: previousByLanguage[lang] ?? [])
            else { return nil }
            return (lang, current, previous)
        }

        if let preferredLanguage {
            if let result = pick(normalizeLanguage(preferredLanguage)) { return result }
        }

        // Prefer English when available.
        if let result = pick("en") { return result }

        // Fallback: pick the common language whose current episode has the most downloads.
        let best = commonLanguages
            .compactMap { lang -> (language: String, downloads: Int)? in
                guard let top = best(in: currentByLanguage[lang] ?? []) else { return nil }
                return (lang, top.downloadCount)
            }
            .max(by: { $0.downloads < $1.downloads })

        guard let winner = best, let result = pick(winner.language) else { return nil }
        return result
    }

    private func normalizeLanguage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let separatorIndex = trimmed.firstIndex(of: "-") {
            return String(trimmed[..<separatorIndex])
        }
        if let separatorIndex = trimmed.firstIndex(of: "_") {
            return String(trimmed[..<separatorIndex])
        }
        return trimmed
    }

    private nonisolated static func localSubtitleTextForEpisode(
        rootPath: String,
        imdbId: String,
        season: Int,
        episode: Int
    ) throws -> (text: String, fileExtension: String, language: String) {
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRootPath.isEmpty else {
            throw OpenSubtitlesError(message: "Local subtitle folder is not configured")
        }

        let rootURL = URL(fileURLWithPath: trimmedRootPath)
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            throw OpenSubtitlesError(message: "Local subtitle folder does not exist")
        }

        let targetEpisodeFolderName = "episode \(episode)"
        let seasonTag2 = String(format: "s%02de%02d", season, episode)
        let seasonTag1 = "s\(season)e\(episode)"

        var bestURL: URL?
        var bestScore = Int.min

        // Fast path: when subtitles are organized by "episode N" folders,
        // avoid a recursive walk over the full network tree.
        let directEpisodeFolder = rootURL.appendingPathComponent(targetEpisodeFolderName, isDirectory: true)
        if let directCandidates = try? FileManager.default.contentsOfDirectory(
            at: directEpisodeFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in directCandidates {
                let score = scoreLocalSubtitleCandidate(
                    item,
                    targetEpisodeFolderName: targetEpisodeFolderName,
                    seasonTag2: seasonTag2,
                    seasonTag1: seasonTag1
                )
                if score > bestScore {
                    bestScore = score
                    bestURL = item
                }
            }
        }

        if bestURL == nil || bestScore <= 0 {
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            while let item = enumerator?.nextObject() as? URL {
                let score = scoreLocalSubtitleCandidate(
                    item,
                    targetEpisodeFolderName: targetEpisodeFolderName,
                    seasonTag2: seasonTag2,
                    seasonTag1: seasonTag1
                )
                if score > bestScore {
                    bestScore = score
                    bestURL = item
                }
            }
        }

        guard let selectedURL = bestURL, bestScore > 0 else {
            throw OpenSubtitlesError(message: "No local subtitle file found for S\(season)E\(episode)")
        }

        let normalizedLanguage = localSubtitleLanguage(for: selectedURL)
        let selectedExtension = selectedURL.pathExtension.lowercased()
        if let cached = SubtitleDiskCache.shared.get(
            imdbId: imdbId,
            season: season,
            episode: episode,
            language: normalizedLanguage,
            fileExtension: selectedExtension
        ) {
            return (text: cached, fileExtension: selectedURL.pathExtension.lowercased(), language: normalizedLanguage)
        }

        let readableURL = try makeLocalSubtitleCopyIfNeeded(selectedURL)

        let data = try Data(contentsOf: readableURL)
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw OpenSubtitlesError(message: "Could not decode local subtitle file: \(selectedURL.lastPathComponent)")
        }

        SubtitleDiskCache.shared.set(
            text,
            imdbId: imdbId,
            season: season,
            episode: episode,
            language: normalizedLanguage,
            fileExtension: selectedExtension
        )

        return (text: text, fileExtension: selectedURL.pathExtension.lowercased(), language: normalizedLanguage)
    }

    private nonisolated static func scoreLocalSubtitleCandidate(
        _ item: URL,
        targetEpisodeFolderName: String,
        seasonTag2: String,
        seasonTag1: String
    ) -> Int {
        let ext = item.pathExtension.lowercased()
        guard ext == "srt" || ext == "ass" else { return Int.min }

        let fileName = item.lastPathComponent.lowercased()
        let parentFolder = item.deletingLastPathComponent().lastPathComponent.lowercased()

        var score = 0
        if parentFolder == targetEpisodeFolderName {
            score += 200
        }
        if fileName.contains(seasonTag2) || fileName.contains(seasonTag1) {
            score += 150
        }
        if fileName.contains(".en.") || fileName.contains("_en") || fileName.contains("eng") {
            score += 40
        }
        if fileName.contains("sign") || fileName.contains("commentary") {
            score -= 40
        }
        score += ext == "srt" ? 20 : 10
        return score
    }

    private nonisolated static func localSubtitleLanguage(for url: URL) -> String {
        let loweredName = url.lastPathComponent.lowercased()
        return (loweredName.contains("eng") || loweredName.contains("_en") || loweredName.contains(".en."))
            ? "en"
            : "local"
    }

    private nonisolated static func makeLocalSubtitleCopyIfNeeded(_ sourceURL: URL) throws -> URL {
        guard isRemoteFileURL(sourceURL) else {
            return sourceURL
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntroStamp", isDirectory: true)
            .appendingPathComponent("Subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileName = "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let localURL = tempDir.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: localURL)
        return localURL
    }

    private nonisolated static func isRemoteFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return true }

        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal {
            return !isLocal
        }

        return url.path.hasPrefix("/Volumes/")
    }

    func updateMinimumZoom(_ minimum: Double) {
        let clamped = min(max(minimum, 0.05), 1.0)
        minimumZoomLevel = clamped

        if appMode == .listReview {
            zoomLevel = clamped
            return
        }

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
        clearInputFocus()
        playerFocusRequestID &+= 1
    }

    func clearInputFocus() {
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
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
            let request = try SegmentValidator.makeTheIntroDBSubmissionRequest(from: draft, videoDurationMs: effectiveDurationMs)
            let response = try await theIntroDBClient.submit(request, apiKey: apiKey)
            return response.usage
        case .introDB:
            guard let apiKey = context.introDBAPIKey else {
                throw SegmentValidationError.message("IntroDB API key is missing")
            }
            let request = try SegmentValidator.makeIntroDBSubmissionRequest(from: draft, mediaDurationMs: effectiveDurationMs)
            let response = try await introDBClient.submit(request, apiKey: apiKey)
            return response.usage
        }
    }

    private func selectedTitleFallback(tmdbId: Int) -> String {
        if let titleHint = tmdbTitleHintsByID[tmdbId], !titleHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return titleHint
        }
        if let selected = tmdbSearchResults.first(where: { $0.tmdbId == tmdbId }) {
            return selected.title
        }
        if let selected = autoLookupCandidates.first(where: { $0.tmdbId == tmdbId }) {
            return selected.title
        }
        return "TMDB \(tmdbId)"
    }

    nonisolated private static func makeReviewItem(
        title: String,
        mediaType: MediaType,
        tmdbId: Int?,
        imdbId: String?,
        season: Int?,
        episode: Int?,
        posterURL: URL?,
        videoDurationMs: Int?,
        sourceLabel: String,
        groupedSegments: [SegmentType: [SegmentRange]],
        draftGroupedSegments: [SegmentType: [SegmentRange]]? = nil
    ) -> ListReviewItem {
        var cleanGroupedSegments = groupedSegments
        var cleanDraftGroupedSegments = draftGroupedSegments ?? [:]
        var noSegmentFlags: [SegmentType: Bool] = [:]

        for segmentType in SegmentType.allCases {
            if let publicRanges = cleanGroupedSegments[segmentType] {
                let zeroRanges = publicRanges.filter { $0.startMs == 0 && ($0.endMs == 0 || $0.endMs == nil) }
                if !zeroRanges.isEmpty {
                    noSegmentFlags[segmentType] = true
                    cleanGroupedSegments[segmentType] = publicRanges.filter { !($0.startMs == 0 && ($0.endMs == 0 || $0.endMs == nil)) }
                }
            }
            if let draftRanges = cleanDraftGroupedSegments[segmentType] {
                let zeroRanges = draftRanges.filter { $0.startMs == 0 && ($0.endMs == 0 || $0.endMs == nil) }
                if !zeroRanges.isEmpty {
                    noSegmentFlags[segmentType] = true
                    cleanDraftGroupedSegments[segmentType] = draftRanges.filter { !($0.startMs == 0 && ($0.endMs == 0 || $0.endMs == nil)) }
                }
            }
        }

        let reducedSegments = primarySegments(from: cleanGroupedSegments)
        let normalizedPublicSegmentGroups = normalizedSegmentGroups(from: cleanGroupedSegments)
        let normalizedDraftSegmentGroups = normalizedSegmentGroups(from: cleanDraftGroupedSegments)
        let reducedDraftSegments = primarySegments(from: normalizedDraftSegmentGroups)
        return ListReviewItem(
            identityKey: AppModel.reviewIdentityKey(mediaType: mediaType, tmdbId: tmdbId, imdbId: imdbId, season: season, episode: episode),
            title: title,
            mediaType: mediaType,
            tmdbId: tmdbId,
            imdbId: imdbId,
            season: season,
            episode: episode,
            posterURL: posterURL,
            videoDurationMs: videoDurationMs,
            sourceLabel: sourceLabel,
            segments: reducedSegments,
            segmentGroups: normalizedPublicSegmentGroups,
            draftSegments: reducedDraftSegments,
            draftSegmentGroups: normalizedDraftSegmentGroups,
            noSegmentFlags: AppModel.normalizedNoSegmentFlags(from: noSegmentFlags),
            submitMessage: nil
        )
    }

    nonisolated private static func primarySegments(from groupedSegments: [SegmentType: [SegmentRange]]) -> [SegmentType: SegmentRange] {
        groupedSegments.reduce(into: [SegmentType: SegmentRange]()) { partial, entry in
            if let first = entry.value.first {
                partial[entry.key] = first
            }
        }
    }

    nonisolated private static func normalizedSegmentGroups(from groupedSegments: [SegmentType: [SegmentRange]]) -> [SegmentType: [SegmentRange]] {
        var normalized: [SegmentType: [SegmentRange]] = [:]
        for segmentType in SegmentType.allCases {
            normalized[segmentType] = groupedSegments[segmentType] ?? []
        }
        return normalized
    }

    nonisolated private static func normalizedNoSegmentFlags(from flags: [SegmentType: Bool]) -> [SegmentType: Bool] {
        var normalized: [SegmentType: Bool] = [:]
        for segmentType in SegmentType.allCases {
            normalized[segmentType] = flags[segmentType] ?? false
        }
        return normalized
    }

    private func preferredPublicVersionDurationMs(for query: MediaQuery) async -> Int? {
        guard let response = try? await theIntroDBClient.fetchMediaVersions(query: query, apiKey: nil) else {
            return nil
        }

        return response.payload.versions
            .filter { $0.durationMs > 0 }
            .max {
                if $0.submissionCount == $1.submissionCount {
                    return ($0.averageDurationMs ?? $0.durationMs) < ($1.averageDurationMs ?? $1.durationMs)
                }
                return $0.submissionCount < $1.submissionCount
            }?
            .durationMs
    }

    nonisolated private static func normalizedPositiveDurationMs(_ durationMs: Int?) -> Int? {
        guard let durationMs, durationMs > 0 else { return nil }
        return durationMs
    }

    nonisolated private static func resolvePreferredDurationMs(
        publicPayloadDurationMs: Int?,
        publicVersionDurationMs: Int?,
        tmdbDurationMs: Int?,
        fallbackDurationMs: Int?
    ) -> Int? {
        normalizedPositiveDurationMs(publicPayloadDurationMs)
        ?? normalizedPositiveDurationMs(publicVersionDurationMs)
        ?? normalizedPositiveDurationMs(tmdbDurationMs)
        ?? normalizedPositiveDurationMs(fallbackDurationMs)
    }

    private func mergeReviewListItems(_ incoming: [ListReviewItem], importWins: Bool) {
        for item in incoming {
            if let index = reviewListItems.firstIndex(where: { $0.identityKey == item.identityKey }) {
                var merged = reviewListItems[index]

                if importWins || merged.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    merged.title = item.title
                }
                if importWins || merged.posterURL == nil {
                    merged.posterURL = item.posterURL
                }
                if importWins || merged.videoDurationMs == nil {
                    merged.videoDurationMs = item.videoDurationMs
                }
                if importWins || merged.tmdbId == nil {
                    merged.tmdbId = item.tmdbId
                }
                if importWins || merged.imdbId == nil {
                    merged.imdbId = item.imdbId
                }

                for (segmentType, range) in item.segments {
                    if importWins || merged.segments[segmentType] == nil {
                        merged.segments[segmentType] = range
                    }
                }

                if importWins {
                    merged.noSegmentFlags = AppModel.normalizedNoSegmentFlags(from: item.noSegmentFlags)
                } else {
                    for (segmentType, flag) in item.noSegmentFlags where flag {
                        merged.noSegmentFlags[segmentType] = true
                    }
                }

                for segmentType in SegmentType.allCases {
                    let incomingPublic = item.segmentGroups[segmentType] ?? []
                    let incomingDraft = item.draftSegmentGroups[segmentType] ?? []

                    if importWins {
                        if !incomingPublic.isEmpty {
                            merged.segmentGroups[segmentType] = incomingPublic
                        }
                        if !incomingDraft.isEmpty {
                            merged.draftSegmentGroups[segmentType] = incomingDraft
                        }
                        continue
                    }

                    let existingPublic = merged.segmentGroups[segmentType] ?? []
                    if existingPublic.isEmpty && !incomingPublic.isEmpty {
                        merged.segmentGroups[segmentType] = incomingPublic
                    }

                    let existingDraft = merged.draftSegmentGroups[segmentType] ?? []
                    if existingDraft.isEmpty && !incomingDraft.isEmpty {
                        merged.draftSegmentGroups[segmentType] = incomingDraft
                    }
                }

                merged.sourceLabel = importWins ? item.sourceLabel : merged.sourceLabel
                reviewListItems[index] = merged
            } else {
                reviewListItems.append(item)
            }
        }

        reviewListItems.sort { lhs, rhs in
            if lhs.displayTitle == rhs.displayTitle {
                let leftSeason = lhs.season ?? 0
                let rightSeason = rhs.season ?? 0
                if leftSeason == rightSeason {
                    return (lhs.episode ?? 0) < (rhs.episode ?? 0)
                }
                return leftSeason < rightSeason
            }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        if let selectedReviewListItemID,
           reviewListItems.contains(where: { $0.id == selectedReviewListItemID }) {
            return
        }

        if let first = reviewListItems.first {
            selectedReviewListItemID = first.id
            if appMode == .listReview {
                applyReviewItemToEditor(first)
            }
        } else {
            selectedReviewListItemID = nil
        }
    }

    private func applyImportedReviewItems(_ importedItems: [ListReviewItem]) async {
        let importedCount = importedItems.count
        let tmdbIdsInOrder = importedItems.reduce(into: [Int]()) { partial, item in
            guard let tmdbId = item.tmdbId, tmdbId > 0 else { return }
            if !partial.contains(tmdbId) {
                partial.append(tmdbId)
            }
        }

        if tmdbIdsInOrder.count > 1 {
            queuedImportedTMDBBatches = tmdbIdsInOrder.map { tmdbId in
                ImportedTMDBReviewBatch(
                    tmdbId: tmdbId,
                    items: importedItems.filter { $0.tmdbId == tmdbId }
                )
            }
            queuedImportedTMDBIndex = 0

            let firstBatch = queuedImportedTMDBBatches[0]
            reviewListItems = []
            selectedReviewListItemID = nil
            mergeReviewListItems(firstBatch.items, importWins: true)
            await enrichImportedReviewItems(progressPrefix: "Loaded \(importQueuedTMDBProgressText).")
            updateQueuedTMDBProgressInfo(importedTotalCount: importedCount)
            return
        }

        clearQueuedImportedTMDBState()
        mergeReviewListItems(importedItems, importWins: true)
        await enrichImportedReviewItems(progressPrefix: nil)
        reviewListInfoMessage = "Imported \(importedCount) list item(s)"
    }

    private func updateQueuedTMDBProgressInfo(importedTotalCount: Int?) {
        guard !queuedImportedTMDBBatches.isEmpty,
              queuedImportedTMDBBatches.indices.contains(queuedImportedTMDBIndex)
        else {
            importQueuedTMDBProgressText = ""
            return
        }

        let currentBatch = queuedImportedTMDBBatches[queuedImportedTMDBIndex]
        let currentDisplay = queuedImportedTMDBIndex + 1
        let total = queuedImportedTMDBBatches.count
        importQueuedTMDBProgressText = "TMDB \(currentBatch.tmdbId) (\(currentDisplay)/\(total))"

        let importedPrefix = importedTotalCount.map { "Imported \($0) list item(s). " } ?? ""
        let suffix = hasNextQueuedImportedTMDB
            ? "Use 'Next TMDB' to load the next ID."
            : "Last TMDB ID loaded."
        reviewListInfoMessage = "\(importedPrefix)Loaded \(importQueuedTMDBProgressText). \(suffix)"
    }

    private func clearQueuedImportedTMDBState() {
        queuedImportedTMDBBatches = []
        queuedImportedTMDBIndex = -1
        importQueuedTMDBProgressText = ""
    }

    private func applyReviewItemToEditor(_ item: ListReviewItem) {
        isSynchronizingReviewSelection = true
        defer { isSynchronizingReviewSelection = false }

        selectedMediaType = item.mediaType
        tmdbIdText = item.tmdbId.map(String.init) ?? ""
        imdbIdText = item.imdbId ?? ""
        seasonText = item.season.map(String.init) ?? ""
        episodeText = item.episode.map(String.init) ?? ""
        matchedPosterURL = item.posterURL

        var ranges: [SegmentType: [SegmentRange]] = AppModel.makeSegmentDictionary(defaultValue: [])
        var drafts: [SegmentType: [SegmentDraft]] = AppModel.makeSegmentDictionary(defaultValue: [])
        let activePublicGroups = item.segmentGroups.isEmpty
            ? item.segments.reduce(into: [SegmentType: [SegmentRange]]()) { partial, entry in
                partial[entry.key] = [entry.value]
            }
            : item.segmentGroups

        let activeDraftGroups = item.draftSegmentGroups.isEmpty
            ? item.draftSegments.reduce(into: [SegmentType: [SegmentRange]]()) { partial, entry in
                partial[entry.key] = [entry.value]
            }
            : item.draftSegmentGroups

        for segmentType in SegmentType.allCases {
            let publicRanges = activePublicGroups[segmentType] ?? []
            if !publicRanges.isEmpty {
                ranges[segmentType] = publicRanges
            }

            let draftRanges = activeDraftGroups[segmentType] ?? []
            if !draftRanges.isEmpty {
                drafts[segmentType] = draftRanges.map {
                    SegmentDraft(startMs: $0.startMs, endMs: $0.endMs)
                }
            }
        }

        serverSegments = ranges
        localDrafts = drafts
        noSegmentFlags = AppModel.normalizedNoSegmentFlags(from: item.noSegmentFlags)
    }

    private func syncSelectedReviewItemFromEditorIfNeeded() {
        guard appMode == .listReview else { return }
        guard !isSynchronizingReviewSelection else { return }
        guard let selectedReviewListItemID,
              let index = reviewListItems.firstIndex(where: { $0.id == selectedReviewListItemID })
        else { return }

        var updated = reviewListItems[index]
        var segments: [SegmentType: SegmentRange] = [:]
        var grouped: [SegmentType: [SegmentRange]] = [:]

        for segmentType in SegmentType.allCases {
            let draftRanges = (localDrafts[segmentType] ?? [])
                .filter { $0.startMs != nil || $0.endMs != nil }
                .map { SegmentRange(startMs: $0.startMs, endMs: $0.endMs) }

            guard !draftRanges.isEmpty else { continue }
            grouped[segmentType] = draftRanges
            if let first = draftRanges.first {
                segments[segmentType] = first
            }
        }

        updated.draftSegments = segments
        updated.draftSegmentGroups = grouped
        updated.noSegmentFlags = AppModel.normalizedNoSegmentFlags(from: noSegmentFlags)
        reviewListItems[index] = updated
    }

    private func importDraftSegmentGroups(from item: ListReviewItem) -> [SegmentType: [SegmentRange]] {
        if !item.draftSegmentGroups.isEmpty {
            return item.draftSegmentGroups
        }
        if !item.draftSegments.isEmpty {
            return item.draftSegments.reduce(into: [SegmentType: [SegmentRange]]()) { partial, entry in
                partial[entry.key] = [entry.value]
            }
        }
        if !item.segmentGroups.isEmpty {
            return item.segmentGroups
        }
        return item.segments.reduce(into: [SegmentType: [SegmentRange]]()) { partial, entry in
            partial[entry.key] = [entry.value]
        }
    }

    private func enrichImportedReviewItems(progressPrefix: String?) async {
        guard !reviewListItems.isEmpty else { return }

        let tmdbKey = tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var tvMetadataByTMDBID: [Int: TMDBTVEpisodeReferenceResponse] = [:]

        if !tmdbKey.isEmpty {
            let tvTMDBIDsSet: Set<Int> = Set(
                reviewListItems.compactMap { item in
                    guard item.mediaType == .tv,
                          let tmdbId = item.tmdbId,
                          tmdbId > 0
                    else {
                        return nil
                    }
                    return tmdbId
                }
            )
            let tvTMDBIDs: [Int] = tvTMDBIDsSet.sorted()

            for tmdbId in tvTMDBIDs {
                guard let metadata = try? await tmdbClient.fetchTVEpisodeReferences(tmdbId: tmdbId, apiKey: tmdbKey) else {
                    continue
                }

                tvMetadataByTMDBID[tmdbId] = metadata

                let tvItemsForTMDB = reviewListItems.filter { item in
                    item.mediaType == .tv && item.tmdbId == tmdbId
                }
                guard let seedItem = tvItemsForTMDB.first else {
                    continue
                }

                var existingEpisodes = Set(
                    tvItemsForTMDB
                        .compactMap { item -> String? in
                            guard let season = item.season, let episode = item.episode else { return nil }
                            return "\(season)-\(episode)"
                        }
                )

                let runtimeMs = metadata.episodeRuntimeMinutes.map { max(0, $0) * 60_000 }
                var placeholders: [ListReviewItem] = []

                for ref in metadata.episodes {
                    let episodeKey = "\(ref.season)-\(ref.episode)"
                    guard !existingEpisodes.contains(episodeKey) else { continue }
                    existingEpisodes.insert(episodeKey)

                    let placeholder = AppModel.makeReviewItem(
                        title: metadata.seriesTitle,
                        mediaType: .tv,
                        tmdbId: tmdbId,
                        imdbId: seedItem.imdbId,
                        season: ref.season,
                        episode: ref.episode,
                        posterURL: metadata.posterURL ?? seedItem.posterURL,
                        videoDurationMs: runtimeMs,
                        sourceLabel: "TMDB",
                        groupedSegments: [:],
                        draftGroupedSegments: nil
                    )
                    placeholders.append(placeholder)
                }

                if !placeholders.isEmpty {
                    mergeReviewListItems(placeholders, importWins: false)
                }
            }
        }

        func enrichItem(_ item: ListReviewItem) async -> ListReviewItem {
            var item = item
            guard let tmdbId = item.tmdbId, tmdbId > 0 else { return item }
            let importedDurationMs = AppModel.normalizedPositiveDurationMs(item.videoDurationMs)

            let importedDraftGroups = importDraftSegmentGroups(from: item)
            let importedDraftPrimary = AppModel.primarySegments(from: importedDraftGroups)
            item.draftSegmentGroups = AppModel.normalizedSegmentGroups(from: importedDraftGroups)
            item.draftSegments = importedDraftPrimary

            let query = MediaQuery(
                tmdbId: tmdbId,
                imdbId: item.imdbId,
                season: item.mediaType == .tv ? item.season : nil,
                episode: item.mediaType == .tv ? item.episode : nil
            )

            let preferredDurationMs = await preferredPublicVersionDurationMs(for: query)
            var publicQuery = query
            publicQuery.durationMs = preferredDurationMs

            if let publicResponse = try? await theIntroDBClient.fetchMedia(query: publicQuery, apiKey: nil) {
                let publicGroups = publicResponse.payload.groupedSegments()
                item.segmentGroups = AppModel.normalizedSegmentGroups(from: publicGroups)
                item.segments = AppModel.primarySegments(from: item.segmentGroups)
                if let importedDurationMs {
                    item.videoDurationMs = importedDurationMs
                } else {
                    item.videoDurationMs = AppModel.resolvePreferredDurationMs(
                        publicPayloadDurationMs: publicResponse.payload.durationMs,
                        publicVersionDurationMs: preferredDurationMs,
                        tmdbDurationMs: nil,
                        fallbackDurationMs: item.videoDurationMs
                    )
                }
                item.sourceLabel = "Import + TMDB + TheIntroDB"
            } else {
                item.segmentGroups = [:]
                item.segments = [:]
                item.sourceLabel = "Import + TMDB"
            }

            if !tmdbKey.isEmpty {
                switch item.mediaType {
                case .tv:
                    var tvMetadata = tvMetadataByTMDBID[tmdbId]
                    if tvMetadata == nil {
                        tvMetadata = try? await tmdbClient.fetchTVEpisodeReferences(tmdbId: tmdbId, apiKey: tmdbKey)
                    }

                    if let tvMetadata {
                        item.title = tvMetadata.seriesTitle
                        item.posterURL = tvMetadata.posterURL ?? item.posterURL
                        if (item.videoDurationMs ?? 0) <= 0,
                           let runtimeMinutes = tvMetadata.episodeRuntimeMinutes {
                            item.videoDurationMs = max(0, runtimeMinutes) * 60_000
                        }
                    }
                case .movie:
                    if let movieMetadata = try? await tmdbClient.fetchMovieMetadata(tmdbId: tmdbId, apiKey: tmdbKey) {
                        item.title = movieMetadata.title
                        item.posterURL = movieMetadata.posterURL ?? item.posterURL
                        if (item.videoDurationMs ?? 0) <= 0 {
                            item.videoDurationMs = movieMetadata.runtimeMinutes.map { max(0, $0) * 60_000 }
                        }
                    }
                }
            }

            return item
        }

        let snapshot = reviewListItems
        let totalCount = snapshot.count

        for index in snapshot.indices {
            let item = snapshot[index]
            let enriched = await enrichItem(item)

            if let currentIndex = reviewListItems.firstIndex(where: { $0.id == item.id }) {
                reviewListItems[currentIndex] = enriched
            }

            let processed = index + 1
            let prefix = progressPrefix.map { "\($0) " } ?? ""
            reviewListInfoMessage = "\(prefix)Enriched \(processed)/\(totalCount) item(s)"
        }

        if selectedReviewListItemID == nil, let firstID = reviewListItems.first?.id {
            selectReviewListItem(firstID)
            return
        }

        if let selectedReviewListItemID,
           reviewListItems.contains(where: { $0.id == selectedReviewListItemID }) {
            selectReviewListItem(selectedReviewListItemID)
        }
    }

    private func captureEditingState(for mode: AppMode) {
        modeEditingStateByMode[mode] = ModeEditingState(
            selectedVideoURL: selectedVideoURL,
            videoTitle: videoTitle,
            timelineTimeMs: timeline.currentTimeMs,
            zoomLevel: zoomLevel,
            selectedMediaType: selectedMediaType,
            tmdbIdText: tmdbIdText,
            imdbIdText: imdbIdText,
            seasonText: seasonText,
            episodeText: episodeText,
            matchedPosterURL: matchedPosterURL,
            tmdbSearchText: tmdbSearchText,
            tmdbSearchResults: tmdbSearchResults,
            autoLookupCandidates: autoLookupCandidates,
            selectedAutoLookupTMDBID: selectedAutoLookupTMDBID,
            tmdbTitleHintsByID: tmdbTitleHintsByID,
            serverSegments: serverSegments,
            localDrafts: localDrafts,
            noSegmentFlags: noSegmentFlags,
            submissionMessages: submissionMessages,
            recapHintBuckets: recapHintBuckets,
            detectedScenes: detectedScenes,
            currentSceneIndex: currentSceneIndex,
            sceneDetectionMessage: sceneDetectionMessage,
            tmdbGenreNames: tmdbGenreNames
        )
    }

    private func restoreEditingState(for mode: AppMode) {
        guard let state = modeEditingStateByMode[mode] else {
            if mode == .listReview, let selectedReviewItem {
                applyReviewItemToEditor(selectedReviewItem)
                zoomLevel = minimumZoomLevel
                resetSegmentHistory()
            }
            return
        }

        if let videoURL = state.selectedVideoURL {
            let shouldReloadVideo = selectedVideoURL != videoURL
            selectedVideoURL = videoURL
            videoTitle = state.videoTitle
            if shouldReloadVideo || timeline.currentVideoAssetURL == nil {
                loadVideo(url: videoURL)
            }
        } else {
            selectedVideoURL = nil
            videoTitle = state.videoTitle
        }

        selectedMediaType = state.selectedMediaType
        tmdbIdText = state.tmdbIdText
        imdbIdText = state.imdbIdText
        seasonText = state.seasonText
        episodeText = state.episodeText
        matchedPosterURL = state.matchedPosterURL

        tmdbSearchText = state.tmdbSearchText
        tmdbSearchResults = state.tmdbSearchResults
        autoLookupCandidates = state.autoLookupCandidates
        selectedAutoLookupTMDBID = state.selectedAutoLookupTMDBID
        tmdbTitleHintsByID = state.tmdbTitleHintsByID

        serverSegments = state.serverSegments
        localDrafts = state.localDrafts
        noSegmentFlags = state.noSegmentFlags
        submissionMessages = state.submissionMessages

        recapHintBuckets = state.recapHintBuckets
        detectedScenes = state.detectedScenes
        currentSceneIndex = state.currentSceneIndex
        sceneDetectionMessage = state.sceneDetectionMessage
        tmdbGenreNames = state.tmdbGenreNames

        zoomLevel = max(minimumZoomLevel, state.zoomLevel)
        seekTimeline(to: state.timelineTimeMs)
        resetSegmentHistory()
    }

    nonisolated private static func reviewIdentityKey(mediaType: MediaType, tmdbId: Int?, imdbId: String?, season: Int?, episode: Int?) -> String {
        let tmdbPart = tmdbId.map(String.init) ?? "tmdb-none"
        let imdbPart = imdbId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "imdb-none"
        let seasonPart = season.map(String.init) ?? "season-none"
        let episodePart = episode.map(String.init) ?? "episode-none"
        return "\(mediaType.rawValue)|\(tmdbPart)|\(imdbPart)|\(seasonPart)|\(episodePart)"
    }

    private enum ReviewListImportParser {
        struct ExtractedSubmission {
            var mediaType: MediaType
            var tmdbId: Int?
            var imdbId: String?
            var season: Int?
            var episode: Int?
            var segmentType: SegmentType
            var startMs: Int
            var endMs: Int?
            var videoDurationMs: Int?
            var title: String?
            var posterURL: URL?
            var status: String?
            var isNoSegment: Bool
        }

        static func parse(data: Data, sourceLabel: String) throws -> [ListReviewItem] {
            let extracted = extractSubmissions(data: data)
            guard !extracted.isEmpty else {
                throw ReviewImportError.unsupportedFormat(sourceLabel)
            }
            return group(extracted: extracted, sourceLabel: sourceLabel)
        }

        private static func extractSubmissions(data: Data) -> [ExtractedSubmission] {
            var submissions: [ExtractedSubmission] = []

            if let root = try? JSONSerialization.jsonObject(with: data) {
                for dictionary in collectSubmissionDictionaries(from: root) {
                    if let extracted = extractSubmission(from: dictionary) {
                        submissions.append(extracted)
                    }
                }
            }

            if submissions.isEmpty,
               let text = String(data: data, encoding: .utf8) {
                for line in text.split(whereSeparator: { $0.isNewline }) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let lineData = trimmed.data(using: .utf8),
                          let root = try? JSONSerialization.jsonObject(with: lineData)
                    else {
                        continue
                    }

                    for dictionary in collectSubmissionDictionaries(from: root) {
                        if let extracted = extractSubmission(from: dictionary) {
                            submissions.append(extracted)
                        }
                    }
                }
            }

            return submissions
        }

        private static func collectSubmissionDictionaries(from root: Any) -> [[String: Any]] {
            if let array = root as? [Any] {
                return array.compactMap { $0 as? [String: Any] }
            }

            guard let object = root as? [String: Any] else {
                return []
            }

            if let submissions = object["submissions"] as? [Any] {
                return submissions.compactMap { $0 as? [String: Any] }
            }

            if let submission = object["submission"] as? [String: Any] {
                return [submission]
            }

            return [object]
        }

        private static func extractSubmission(from dictionary: [String: Any]) -> ExtractedSubmission? {
            guard let segmentRaw = stringValue(dictionary, keys: ["segment", "segment_type", "segmentType"]),
                  let segmentType = segmentType(from: segmentRaw)
            else {
                return nil
            }

            guard let startMs = intValue(dictionary, keys: ["start_ms", "startMs"]) ??
                secondsToMs(doubleValue(dictionary, keys: ["start_sec", "startSec"]))
            else {
                return nil
            }

            let endMs = intValue(dictionary, keys: ["end_ms", "endMs"]) ??
                secondsToMs(doubleValue(dictionary, keys: ["end_sec", "endSec"]))

            let isNoSegment = startMs == 0 && (endMs == 0 || endMs == nil)

            let tmdbId = intValue(dictionary, keys: ["tmdb_id", "tmdbId"])
            let imdbId = stringValue(dictionary, keys: ["imdb_id", "imdbId"])
            let season = intValue(dictionary, keys: ["season"])
            let episode = intValue(dictionary, keys: ["episode"])
            let videoDurationMs = intValue(dictionary, keys: ["video_duration_ms", "videoDurationMs"])
            let status = stringValue(dictionary, keys: ["status"])

            guard tmdbId != nil || (imdbId?.isEmpty == false) else {
                return nil
            }

            let show = dictionary["show"] as? [String: Any]
            let title = stringValue(show, keys: ["title", "name"]) ?? stringValue(dictionary, keys: ["title", "name"])
            let posterString = stringValue(show, keys: ["posterUrl", "poster_url", "posterURL"]) ??
                stringValue(dictionary, keys: ["posterUrl", "poster_url", "posterURL"])
            let posterURL = posterString.flatMap(URL.init(string:))

            let mediaType: MediaType
            if let rawType = stringValue(dictionary, keys: ["type"]),
               let parsedType = MediaType(rawValue: rawType.lowercased()) {
                mediaType = parsedType
            } else if season != nil || episode != nil {
                mediaType = .tv
            } else {
                mediaType = .movie
            }

            return ExtractedSubmission(
                mediaType: mediaType,
                tmdbId: tmdbId,
                imdbId: imdbId,
                season: season,
                episode: episode,
                segmentType: segmentType,
                startMs: startMs,
                endMs: endMs,
                videoDurationMs: videoDurationMs,
                title: title,
                posterURL: posterURL,
                status: status,
                isNoSegment: isNoSegment
            )
        }

        private static func group(extracted: [ExtractedSubmission], sourceLabel: String) -> [ListReviewItem] {
            var grouped: [String: ListReviewItem] = [:]

            for entry in extracted {
                let key = reviewIdentityKey(mediaType: entry.mediaType, tmdbId: entry.tmdbId, imdbId: entry.imdbId, season: entry.season, episode: entry.episode)
                let title = makeTitle(entry: entry)

                var draftSegmentGroups: [SegmentType: [SegmentRange]] = [:]
                var draftSegments: [SegmentType: SegmentRange] = [:]
                var noSegmentFlags: [SegmentType: Bool] = [:]

                if entry.isNoSegment {
                    noSegmentFlags[entry.segmentType] = true
                } else {
                    let segmentRange = SegmentRange(startMs: entry.startMs, endMs: entry.endMs)
                    draftSegmentGroups[entry.segmentType] = [segmentRange]
                    draftSegments[entry.segmentType] = segmentRange
                }

                let item = ListReviewItem(
                    identityKey: key,
                    title: title,
                    mediaType: entry.mediaType,
                    tmdbId: entry.tmdbId,
                    imdbId: entry.imdbId,
                    season: entry.season,
                    episode: entry.episode,
                    posterURL: entry.posterURL,
                    videoDurationMs: entry.videoDurationMs,
                    sourceLabel: sourceLabel,
                    segments: [:],
                    draftSegments: draftSegments,
                    draftSegmentGroups: draftSegmentGroups,
                    noSegmentFlags: AppModel.normalizedNoSegmentFlags(from: noSegmentFlags),
                    submitMessage: entry.status
                )

                if var existing = grouped[key] {
                    if entry.isNoSegment {
                        existing.noSegmentFlags[entry.segmentType] = true
                        existing.draftSegmentGroups[entry.segmentType]?.removeAll { $0.startMs == 0 && ($0.endMs == 0 || $0.endMs == nil) }
                        if existing.draftSegmentGroups[entry.segmentType]?.isEmpty == true {
                            existing.draftSegmentGroups.removeValue(forKey: entry.segmentType)
                            existing.draftSegments.removeValue(forKey: entry.segmentType)
                        }
                    } else {
                        let segmentRange = SegmentRange(startMs: entry.startMs, endMs: entry.endMs)
                        var draftGroups = existing.draftSegmentGroups
                        draftGroups[entry.segmentType, default: []].append(segmentRange)
                        existing.draftSegmentGroups = draftGroups
                        existing.draftSegments = primarySegments(from: draftGroups)
                    }
                    if existing.posterURL == nil {
                        existing.posterURL = entry.posterURL
                    }
                    if existing.videoDurationMs == nil {
                        existing.videoDurationMs = entry.videoDurationMs
                    }
                    grouped[key] = existing
                } else {
                    grouped[key] = item
                }
            }

            return grouped.values.sorted { lhs, rhs in
                if lhs.displayTitle == rhs.displayTitle {
                    let leftSeason = lhs.season ?? 0
                    let rightSeason = rhs.season ?? 0
                    if leftSeason == rightSeason {
                        return (lhs.episode ?? 0) < (rhs.episode ?? 0)
                    }
                    return leftSeason < rightSeason
                }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
        }

        private static func makeTitle(entry: ExtractedSubmission) -> String {
            if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return title
            }
            if let tmdbId = entry.tmdbId {
                return "TMDB \(tmdbId)"
            }
            if let imdbId = entry.imdbId, !imdbId.isEmpty {
                return imdbId
            }
            return "Untitled"
        }

        private static func reviewIdentityKey(mediaType: MediaType, tmdbId: Int?, imdbId: String?, season: Int?, episode: Int?) -> String {
            let tmdbPart = tmdbId.map(String.init) ?? "tmdb-none"
            let imdbPart = imdbId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "imdb-none"
            let seasonPart = season.map(String.init) ?? "season-none"
            let episodePart = episode.map(String.init) ?? "episode-none"
            return "\(mediaType.rawValue)|\(tmdbPart)|\(imdbPart)|\(seasonPart)|\(episodePart)"
        }

        private static func stringValue(_ dictionary: [String: Any]?, keys: [String]) -> String? {
            guard let dictionary else { return nil }
            for key in keys {
                if let value = dictionary[key] as? String {
                    return value
                }
            }
            return nil
        }

        private static func intValue(_ dictionary: [String: Any], keys: [String]) -> Int? {
            for key in keys {
                if let value = dictionary[key] as? Int {
                    return value
                }
                if let value = dictionary[key] as? NSNumber {
                    return value.intValue
                }
                if let value = dictionary[key] as? String, let intValue = Int(value) {
                    return intValue
                }
                if let value = dictionary[key] as? String, let doubleValue = Double(value) {
                    return Int(doubleValue.rounded())
                }
            }
            return nil
        }

        private static func doubleValue(_ dictionary: [String: Any], keys: [String]) -> Double? {
            for key in keys {
                if let value = dictionary[key] as? Double {
                    return value
                }
                if let value = dictionary[key] as? NSNumber {
                    return value.doubleValue
                }
                if let value = dictionary[key] as? String, let parsed = Double(value) {
                    return parsed
                }
            }
            return nil
        }

        private static func secondsToMs(_ seconds: Double?) -> Int? {
            guard let seconds else { return nil }
            return Int((seconds * 1000).rounded())
        }

        private static func segmentType(from rawValue: String) -> SegmentType? {
            switch rawValue.lowercased() {
            case "intro":
                return .intro
            case "recap":
                return .recap
            case "outro", "credits":
                return .credits
            case "preview":
                return .preview
            default:
                return nil
            }
        }
    }

    private enum ReviewImportError: LocalizedError {
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let sourceLabel):
                return "Unsupported review import format: \(sourceLabel)"
            }
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

    func isUploadingSegment(_ segment: SegmentType) -> Bool {
        activeSegmentUploadsByVideo[videoLoadID]?.contains(segment) ?? false
    }

    private func beginSegmentUploadTracking(videoLoadID: Int, segment: SegmentType) {
        var active = activeSegmentUploadsByVideo[videoLoadID] ?? []
        active.insert(segment)
        activeSegmentUploadsByVideo[videoLoadID] = active
    }

    private func endSegmentUploadTracking(videoLoadID: Int, segment: SegmentType) {
        guard var active = activeSegmentUploadsByVideo[videoLoadID] else { return }
        active.remove(segment)
        if active.isEmpty {
            activeSegmentUploadsByVideo.removeValue(forKey: videoLoadID)
        } else {
            activeSegmentUploadsByVideo[videoLoadID] = active
        }
    }

    private func beginUploadAllTracking(videoLoadID: Int) {
        activeUploadAllByVideo.insert(videoLoadID)
    }

    private func endUploadAllTracking(videoLoadID: Int) {
        activeUploadAllByVideo.remove(videoLoadID)
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
                tvdbId: nil,
                season: intOrNil(seasonText),
                episode: intOrNil(episodeText),
                durationMs: effectiveDurationMs
            )
        }

        return MediaQuery(
            tmdbId: tmdb,
            imdbId: imdb,
            tvdbId: nil,
            season: nil,
            episode: nil,
            durationMs: effectiveDurationMs
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
        NSApplication.shared.keyWindow?.undoManager
        ?? NSApplication.shared.mainWindow?.undoManager
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

    private func nearestDraftEnding(atOrBefore ms: Int) -> (segment: SegmentType, index: Int, endMs: Int)? {
        var best: (segment: SegmentType, index: Int, endMs: Int)?

        for segType in SegmentType.allCases {
            let segmentDrafts = drafts(for: segType)
            for (index, draft) in segmentDrafts.enumerated() {
                guard let endMs = draft.endMs, endMs <= ms else { continue }
                if let current = best {
                    if endMs > current.endMs {
                        best = (segType, index, endMs)
                    }
                } else {
                    best = (segType, index, endMs)
                }
            }
        }

        return best
    }

    private func nearestDraftStartMarker(atOrAfter ms: Int) -> Int? {
        SegmentType.allCases
            .flatMap { drafts(for: $0).compactMap(\ .startMs) }
            .filter { $0 >= ms }
            .min()
    }

    private func jumpTimestampFromPlayheadAndRotate(
        from currentMs: Int,
        in sortedTimestamps: [Int],
        toleranceMs: Int,
        previousDirection: Int?
    ) -> (timestamp: Int, direction: Int) {
        guard let first = sortedTimestamps.first else { return (currentMs, previousDirection ?? 1) }
        if sortedTimestamps.count == 1 { return (first, previousDirection ?? 1) }

        // If playhead is effectively on a marker, rotate in remembered direction.
        if let currentIndex = sortedTimestamps.firstIndex(where: { abs($0 - currentMs) <= toleranceMs }) {
            let direction = previousDirection ?? 1
            let step = direction >= 0 ? 1 : -1
            let nextIndex = (currentIndex + step + sortedTimestamps.count) % sortedTimestamps.count
            return (sortedTimestamps[nextIndex], direction >= 0 ? 1 : -1)
        }

        // First jump from arbitrary playhead: select nearest marker.
        // On equal distance, prefer the forward (ahead) marker.
        var nearestIndex = 0
        var nearestDistance = abs(sortedTimestamps[0] - currentMs)
        for idx in 1..<sortedTimestamps.count {
            let candidate = sortedTimestamps[idx]
            let distance = abs(candidate - currentMs)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = idx
            } else if distance == nearestDistance {
                let best = sortedTimestamps[nearestIndex]
                if candidate >= currentMs && best < currentMs {
                    nearestIndex = idx
                }
            }
        }

        let nearest = sortedTimestamps[nearestIndex]
        let direction = nearest >= currentMs ? 1 : -1
        return (nearest, direction)
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

    // MARK: - Scene Detection

    func toggleSceneDetection() {
        isSceneDetectionEnabled.toggle()
        if isSceneDetectionEnabled {
            scheduleSceneDetection(videoLoadID: videoLoadID)
        } else {
            pendingSceneDetectionTask?.cancel()
            pendingSceneDetectionTask = nil
            isDetectingScenes = false
            detectedScenes = []
            sceneDetectionMessage = ""
        }
    }

    func toggleMusicLikelihood() {
        isMusicLikelihoodEnabled.toggle()
        if isMusicLikelihoodEnabled {
            Task { await timeline.reloadMusicLikelihood() }
        } else {
            timeline.clearMusicLikelihood()
        }
    }

    func toggleSubmissionLogging() {
        isSubmissionLoggingEnabled.toggle()
    }

    private func scheduleSceneDetection(videoLoadID: Int, preferredVideoURL: URL? = nil) {
        guard isSceneDetectionEnabled else { return }
        guard self.videoLoadID == videoLoadID else { return }
        guard let videoURL = preferredVideoURL ?? timeline.currentVideoAssetURL else { return }

        // Never run scene detection against network-backed media.
        // Remote URLs can block decode and defeat the local-copy strategy.
        if timeline.isRemoteURL(videoURL) {
            isDetectingScenes = false
            sceneDetectionMessage = "Szenenerkennung wartet auf lokale Videokopie"
            return
        }

        let tmdbId = intOrNil(tmdbIdText)
        let apiKey = tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaType = selectedMediaType
        let existingGenres = tmdbGenreNames

        // Avoid restarting an in-progress detection when genre info hasn't changed.
        // fetchMedia may call here after autoDetect fills in genres, but if the preset
        // that would be used is the same as when detection started, a restart would
        // only discard progressive results without improving accuracy.
        if isDetectingScenes, let activeGenres = sceneDetectionActiveGenres {
            let activePreset = SceneDetector.Config.inferredPreset(from: activeGenres, mediaType: mediaType)
            let newPreset = SceneDetector.Config.inferredPreset(from: existingGenres, mediaType: mediaType)
            if activePreset == newPreset {
                return
            }
        }

        let sceneDetector = self.sceneDetector
        let tmdbClient = self.tmdbClient

        pendingSceneDetectionTask?.cancel()
        sceneDetectionActiveGenres = existingGenres
        isDetectingScenes = true
        sceneDetectionMessage = "Analysiere Szenenübergänge..."

        pendingSceneDetectionTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            var genres = existingGenres
            if genres.isEmpty, let tmdbId, !apiKey.isEmpty {
                do {
                    genres = try await tmdbClient.fetchGenres(mediaType: mediaType, tmdbId: tmdbId, apiKey: apiKey)
                } catch {
                    genres = []
                }
            }

            let preset = SceneDetector.Config.inferredPreset(from: genres, mediaType: mediaType)
            var config = SceneDetector.Config()
            config.applyPreset(preset)
            do {
                let scenes = try await sceneDetector.detectScenes(
                    asset: AVURLAsset(url: videoURL),
                    config: config,
                    onProgress: { partialScenes, progress in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard self.videoLoadID == videoLoadID else { return }
                            guard self.isDetectingScenes else { return }

                            self.detectedScenes = partialScenes
                            let percent = Int((progress * 100.0).rounded(.down))
                            self.sceneDetectionMessage = "Analysiere Szenenübergänge... \(partialScenes.count) gefunden (\(percent)%)"
                        }
                    }
                )
                let sortedScenes = scenes.sorted { $0.timestampMs < $1.timestampMs }

                await MainActor.run {
                    guard self.videoLoadID == videoLoadID else { return }
                    self.tmdbGenreNames = genres
                    self.detectedScenes = sortedScenes
                    self.currentSceneIndex = nil
                    self.sceneJumpDirection = nil
                    self.isDetectingScenes = false
                    self.sceneDetectionActiveGenres = nil
                    if sortedScenes.isEmpty {
                        self.sceneDetectionMessage = "Keine Szenenübergänge gefunden"
                    } else {
                        self.sceneDetectionMessage = "\(sortedScenes.count) Szenenübergänge erkannt (\(preset.rawValue))"
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.videoLoadID == videoLoadID else { return }
                    self.isDetectingScenes = false
                    self.sceneDetectionMessage = "Fehler: \(error.localizedDescription)"
                    self.detectedScenes = []
                    self.currentSceneIndex = nil
                    self.sceneJumpDirection = nil
                    self.sceneDetectionActiveGenres = nil
                }
            }
        }
    }

    func jumpToNextScene() {
        jumpToSceneTransition(directionHint: 1)
    }

    func jumpToPreviousScene() {
        jumpToSceneTransition(directionHint: -1)
    }

    // MARK: - Clerk Session Helpers

    private func parseClerkCurl(_ curlCommand: String) throws -> ClerkSession {
        // Session ID extrahieren: /v1/client/sessions/XXXX/tokens
        let sessionPattern = #"/sessions/([^/]+)/"#
        let sessionRegex = try NSRegularExpression(pattern: sessionPattern)
        guard let match = sessionRegex.firstMatch(in: curlCommand, range: NSRange(curlCommand.startIndex..., in: curlCommand)),
              let range = Range(match.range(at: 1), in: curlCommand) else {
            throw NSError(domain: "ClerkParse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session ID nicht gefunden"])
        }
        let sessionId = String(curlCommand[range])

        // Token extrahieren: --data 'token=eyJ...&...'
        let tokenPattern = #"token=([^'&\s]+)"#
        let tokenRegex = try NSRegularExpression(pattern: tokenPattern)
        guard let match = tokenRegex.firstMatch(in: curlCommand, range: NSRange(curlCommand.startIndex..., in: curlCommand)),
              let range = Range(match.range(at: 1), in: curlCommand) else {
            throw NSError(domain: "ClerkParse", code: 2, userInfo: [NSLocalizedDescriptionKey: "Token nicht gefunden"])
        }
        let token = String(curlCommand[range])

        // __client Cookie extrahieren
        let cookiePattern = #"__client=([^;\s]+)"#
        let cookieRegex = try NSRegularExpression(pattern: cookiePattern)
        guard let match = cookieRegex.firstMatch(in: curlCommand, range: NSRange(curlCommand.startIndex..., in: curlCommand)),
              let range = Range(match.range(at: 1), in: curlCommand) else {
            throw NSError(domain: "ClerkParse", code: 3, userInfo: [NSLocalizedDescriptionKey: "Client Cookie nicht gefunden"])
        }
        let clientCookie = String(curlCommand[range])

        return ClerkSession(sessionId: sessionId, currentToken: token, clientCookie: clientCookie)
    }

    private func refreshClerkToken(_ session: inout ClerkSession, forService service: String) async throws {
        let clerkHost = service == "theintrodb" ? "clerk.theintrodb.org" : "clerk.introdb.app"
        let url = URL(string: "https://\(clerkHost)/v1/client/sessions/\(session.sessionId)/tokens?__clerk_api_version=2025-11-10")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://\(service == "theintrodb" ? "theintrodb.org" : "introdb.app")", forHTTPHeaderField: "Origin")
        request.setValue("https://\(service == "theintrodb" ? "theintrodb.org" : "introdb.app")/", forHTTPHeaderField: "Referer")
        request.setValue("__client=\(session.clientCookie)", forHTTPHeaderField: "Cookie")

        let body = "organization_id=&token=\(session.currentToken)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "ClerkRefresh", code: 0, userInfo: [NSLocalizedDescriptionKey: "Token refresh fehlgeschlagen"])
        }

        let decoded = try JSONDecoder().decode(ClerkTokenResponse.self, from: data)
        session.currentToken = decoded.jwt
    }

    func backupTheIntroDBSubmissions() async {
        infoMessage = ""
        errorMessage = ""
        let clerkCurl = theIntroDBClerkCurl.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clerkCurl.isEmpty else {
            errorMessage = "TheIntroDB Clerk session not configured. Paste curl command from browser DevTools."
            return
        }

        infoMessage = "Backing up TheIntroDB submissions…"

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: Date())
        let dateComponents = timestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "T", with: "_")

        // Parse Clerk session
        do {
            theIntroDBClerkSession = try parseClerkCurl(clerkCurl)
        } catch {
            errorMessage = "Failed to parse Clerk curl: \(error.localizedDescription)"
            return
        }

        // Refresh token once to ensure it's valid for the duration of pagination
        do {
            if var session = theIntroDBClerkSession {
                try await refreshClerkToken(&session, forService: "theintrodb")
                theIntroDBClerkSession = session
            }
        } catch {
            errorMessage = "Failed to refresh Clerk token: \(error.localizedDescription)"
            return
        }

        defer {
            // Clean up Clerk session after backup
            theIntroDBClerkSession = nil
        }

        do {
            infoMessage = "Fetching TheIntroDB submissions…"
            
            guard let session = theIntroDBClerkSession else {
                errorMessage = "Failed to establish Clerk session"
                return
            }
            
            let submissions = try await theIntroDBClient.fetchAllSubmissionsWithClerk(
                token: session.currentToken
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(submissions)
            
            let filename = "theintrodb_submissions_\(dateComponents).json"
            let fileURL = downloadsURL.appendingPathComponent(filename)

            try jsonData.write(to: fileURL)
            infoMessage = "Backed up \(submissions.count) TheIntroDB submissions to: \(filename)"
        } catch {
            errorMessage = "TheIntroDB backup failed: \(error.localizedDescription)"
        }
    }

    func backupIntroDBSubmissions() async {
        infoMessage = ""
        errorMessage = ""
        let clerkCurl = introDBClerkCurl.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clerkCurl.isEmpty else {
            errorMessage = "IntroDB Clerk session not configured. Paste curl command from browser DevTools."
            return
        }

        infoMessage = "Backing up IntroDB submissions…"

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: Date())
        let dateComponents = timestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "T", with: "_")

        // Parse Clerk session
        do {
            introDBClerkSession = try parseClerkCurl(clerkCurl)
        } catch {
            errorMessage = "Failed to parse Clerk curl: \(error.localizedDescription)"
            return
        }

        // Refresh token once to ensure it's valid for the duration of pagination
        do {
            if var session = introDBClerkSession {
                try await refreshClerkToken(&session, forService: "introdb")
                introDBClerkSession = session
            }
        } catch {
            errorMessage = "Failed to refresh Clerk token: \(error.localizedDescription)"
            return
        }

        defer {
            // Clean up Clerk session after backup
            introDBClerkSession = nil
        }

        do {
            infoMessage = "Fetching IntroDB submissions…"
            
            guard let session = introDBClerkSession else {
                errorMessage = "Failed to establish Clerk session"
                return
            }
            
            let submissions = try await introDBClient.fetchAllSubmissionsWithClerk(
                token: session.currentToken
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(submissions)
            
            let filename = "introdb_submissions_\(dateComponents).json"
            let fileURL = downloadsURL.appendingPathComponent(filename)

            try jsonData.write(to: fileURL)
            infoMessage = "Backed up \(submissions.count) IntroDB submissions to: \(filename)"
        } catch {
            errorMessage = "IntroDB backup failed: \(error.localizedDescription)"
        }
    }

    private func jumpToSceneTransition(directionHint: Int) {
        let timestamps = detectedScenes.map(\.timestampMs).sorted()
        guard !timestamps.isEmpty else { return }

        let result = jumpTimestampFromPlayheadAndRotate(
            from: timeline.currentTimeMs,
            in: timestamps,
            toleranceMs: frameDurationMs,
            previousDirection: directionHint
        )
        sceneJumpDirection = result.direction
        frameStripFineModeToken &+= 1
        seekTimeline(to: result.timestamp)
        currentSceneIndex = detectedScenes.firstIndex(where: { $0.timestampMs == result.timestamp })
    }
}

private extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}
