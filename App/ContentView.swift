import AVFoundation
import AVKit
import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var curlInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarPane(model: model)
                    .navigationTitle("IntroStamp")
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360)
            } detail: {
                DetailPane(model: model)
            }

            StatusBar(model: model)
        }
        .sheet(isPresented: Binding(
            get: { model.backupServicePending != nil },
            set: { if !$0 { model.backupServicePending = nil } }
        )) {
            if let service = model.backupServicePending {
                curlInputSheet(for: service)
            }
        }
    }

    @ViewBuilder
    private func curlInputSheet(for service: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(service == "theintrodb" ? "TheIntroDB Backup" : "IntroDB.app Backup")
                .font(.headline)

            Text("Copy and paste the clerk token request/response as a cURL command from browser DevTools → Network tab")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $curlInput)
                .frame(height: 80)
                .font(.system(.caption, design: .monospaced))
                .border(Color.secondary.opacity(0.3), width: 1)
                .cornerRadius(4)

            HStack(spacing: 8) {
                Button("Cancel") {
                    model.backupServicePending = nil
                    curlInput = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Backup") {
                    Task {
                        if service == "theintrodb" {
                            model.theIntroDBClerkCurl = curlInput
                            await model.backupTheIntroDBSubmissions()
                        } else {
                            model.introDBClerkCurl = curlInput
                            await model.backupIntroDBSubmissions()
                        }
                        model.backupServicePending = nil
                        curlInput = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(curlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(width: 450, height: 250)
    }
}

private struct SidebarPane: View {
    @Bindable var model: AppModel
    @State private var isAPIKeysSectionExpanded: Bool = false

    private var introAPIKeyIsFilled: Bool {
        !model.theIntroDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tmdbAPIKeyIsFilled: Bool {
        !model.tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var introDBAPIKeyIsFilled: Bool {
        !model.introDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var openSubtitlesAPIKeyIsFilled: Bool {
        !model.openSubtitlesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var apiKeyFillCount: Int {
        (introAPIKeyIsFilled ? 1 : 0) + (introDBAPIKeyIsFilled ? 1 : 0) + (tmdbAPIKeyIsFilled ? 1 : 0) + (openSubtitlesAPIKeyIsFilled ? 1 : 0)
    }

    private var areAllAPIKeysFilled: Bool {
        apiKeyFillCount == 4
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                modeSection
                if model.appMode == .singleVideo {
                    videoSection
                }
                keysSection
                mediaSection
                segmentsSection
            }
            .padding(14)
        }
        .onSubmit {
            model.requestPlayerFocus()
        }
    }

    private var modeSection: some View {
        GroupBox("Mode") {
            Picker("View", selection: $model.appMode) {
                ForEach(AppMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var videoSection: some View {
        GroupBox("Video") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.videoTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)

                    Button("Open Local Video") {
                        model.chooseVideoFile()
                    }

                    if model.nextEpisodeURL != nil {
                        Button {
                            model.openNextEpisode()
                        } label: {
                            Label("Next Episode", systemImage: "arrow.right.circle")
                        }
                    }

                    if model.autoLookupCandidates.count > 1 {
                        Picker("TMDB Match", selection: Binding<Int?>(
                            get: { model.selectedAutoLookupTMDBID },
                            set: { newValue in
                                guard let tmdbId = newValue else { return }
                                model.selectAutoLookupCandidate(tmdbId: tmdbId)
                                Task { await model.fetchMedia(prefillDrafts: true) }
                            }
                        )) {
                            ForEach(model.autoLookupCandidates, id: \.tmdbId) { candidate in
                                Text(tmdbCandidateLabel(candidate))
                                    .tag(Optional(candidate.tmdbId))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    if !model.autoLookupMessage.isEmpty {
                        Text(model.autoLookupMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                posterThumbnail
            }
        }
    }

    @ViewBuilder
    private var posterThumbnail: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.black.opacity(0.06))
            .frame(width: 54, height: 81)
            .overlay {
                if let posterURL = model.matchedPosterURL {
                    AsyncImage(url: posterURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .empty:
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            Color.clear
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.6)
            }
    }

    private var keysSection: some View {
        GroupBox("API Keys") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: areAllAPIKeysFilled ? "key.fill" : "key")
                        .foregroundStyle(.secondary)
                    Text(areAllAPIKeysFilled ? "API keys configured" : "API keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(apiKeyFillCount)/4")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                        )
                    Spacer()
                    Button(isAPIKeysSectionExpanded ? "Collapse" : "Expand") {
                        isAPIKeysSectionExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                }

                if isAPIKeysSectionExpanded {
                    SecureField("TheIntroDB API key", text: $model.theIntroDBAPIKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField("IntroDB API key", text: $model.introDBAPIKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField("TMDB API key", text: $model.tmdbAPIKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField("OpenSubtitles API key", text: $model.openSubtitlesAPIKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        TextField("Local OpenSubtitles folder (optional)", text: $model.localOpenSubtitlesDirectoryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            model.chooseLocalOpenSubtitlesDirectory()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(model.areAPIKeyFieldsEmpty ? "Get Keys from Keychain" : "Save Keys to Keychain") {
                        if model.areAPIKeyFieldsEmpty {
                            model.loadKeysFromKeychain()
                        } else {
                            model.saveKeysToKeychain()
                            if areAllAPIKeysFilled {
                                isAPIKeysSectionExpanded = false
                            }
                        }
                    }
                }
            }
        }
    }

    private var mediaSection: some View {
        GroupBox("Media Identification") {
            VStack(alignment: .leading, spacing: 8) {
                // TMDB free-text search
                HStack(spacing: 6) {
                    TextField("Search TMDB…", text: $model.tmdbSearchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.searchTMDB() } }
                    if model.isTMDBSearching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Button {
                            Task { await model.searchTMDB() }
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .disabled(model.tmdbSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if !model.tmdbSearchResults.isEmpty {
                    Picker("Result", selection: Binding<Int?>(
                        get: { nil },
                        set: { newValue in
                            guard let tmdbId = newValue,
                                  let result = model.tmdbSearchResults.first(where: { $0.tmdbId == tmdbId })
                            else { return }
                            model.selectTMDBSearchResult(result)
                        }
                    )) {
                        Text("Select result…").tag(Optional<Int>.none)
                        ForEach(model.tmdbSearchResults, id: \.tmdbId) { result in
                            Text(tmdbCandidateLabel(result)).tag(Optional(result.tmdbId))
                        }
                    }
                    .pickerStyle(.menu)
                }

                TextField("TMDB ID", text: $model.tmdbIdText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard model.appMode == .listReview else { return }
                        Task { await model.loadReviewListFromCurrentSelection() }
                    }

                TextField("IMDB ID (optional)", text: $model.imdbIdText)
                    .textFieldStyle(.roundedBorder)

                Picker("Type", selection: $model.selectedMediaType) {
                    ForEach(MediaType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                if model.selectedMediaType == .tv {
                    HStack {
                        TextField("Season", text: $model.seasonText)
                            .textFieldStyle(.roundedBorder)
                        TextField("Episode", text: $model.episodeText)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Button {
                        Task {
                            if model.appMode == .singleVideo {
                                await model.fetchMedia()
                            } else {
                                await model.loadReviewListFromCurrentSelection()
                            }
                        }
                    } label: {
                        if model.appMode == .singleVideo && model.isFetchingMedia {
                            Label {
                                Text("Load Existing Segments")
                            } icon: {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 14, height: 14)
                            }
                        } else if model.appMode == .listReview && model.isLoadingReviewList {
                            Label {
                                Text("Load Review List")
                            } icon: {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 14, height: 14)
                            }
                        } else {
                            Label(model.appMode == .singleVideo ? "Load Existing Segments" : "Load Review List", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isFetchingMedia || model.isLoadingReviewList)

                    Button {
                        Task {
                            if model.appMode == .singleVideo {
                                await model.uploadAllSegments()
                            } else {
                                model.chooseReviewImportFiles()
                            }
                        }
                    } label: {
                        if model.appMode == .singleVideo && model.isUploadingAll {
                            Label {
                                Text("Upload All Drafts")
                            } icon: {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 14, height: 14)
                            }
                        } else {
                            Label(model.appMode == .singleVideo ? "Upload All Drafts" : "Import Segment JSON", systemImage: model.appMode == .singleVideo ? "icloud.and.arrow.up.fill" : "tray.and.arrow.down.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(model.isUploadingAll || model.isFetchingMedia || model.isLoadingReviewList)
                }

                if model.appMode == .listReview {
                    if !model.reviewListInfoMessage.isEmpty {
                        Text(model.reviewListInfoMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !model.reviewListErrorMessage.isEmpty {
                        Text(model.reviewListErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var segmentsSection: some View {
        GroupBox("Segment Drafts") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SegmentType.allCases) { segment in
                    SegmentEditorRow(model: model, segment: segment)
                    if segment != SegmentType.allCases.last {
                        Divider()
                    }
                }
            }
        }
    }

}

private func tmdbCandidateLabel(_ candidate: AutoLookupResult) -> String {
    if let year = candidate.matchedYear {
        return "\(candidate.title) (\(year)) • TMDB \(candidate.tmdbId)"
    }
    return "\(candidate.title) • TMDB \(candidate.tmdbId)"
}

private struct StatusBar: View {
    @Bindable var model: AppModel

    private var message: String {
        if !model.errorMessage.isEmpty {
            return model.errorMessage
        }
        if !model.infoMessage.isEmpty {
            return model.infoMessage
        }
        return "Ready"
    }

    private var messageColor: Color {
        if !model.errorMessage.isEmpty {
            return .red
        }
        if !model.infoMessage.isEmpty {
            return .green
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.caption)
                .foregroundStyle(messageColor)
                .lineLimit(1)

            Spacer()

            if !model.usageMessage.isEmpty {
                Text(model.usageMessage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if model.isDetectingScenes {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    if model.detectedScenes.isEmpty {
                        Text("Scenes…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Scenes \(model.detectedScenes.count)…")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .help(model.sceneDetectionMessage)
            } else if !model.sceneDetectionMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: model.detectedScenes.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(model.detectedScenes.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                    if model.detectedScenes.isEmpty {
                        Text("Scenes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Scenes \(model.detectedScenes.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .help(model.sceneDetectionMessage)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct DetailPane: View {
    @Bindable var model: AppModel
    @State private var arrowKeyMonitor: Any?
    @State private var keyboardFineModeToken: Int = 0

    var body: some View {
        VStack(spacing: 12) {
            if model.appMode == .singleVideo {
                if let player = model.timeline.player {
                    FocusablePlayerView(player: player, requestID: model.playerFocusRequestID)
                        .frame(minHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.15))
                        .overlay {
                            GeometryReader { proxy in
                                let availableWidth = max(260, proxy.size.width - 24)
                                let availableHeight = max(120, proxy.size.height - 24)
                                TimelineUXHelpCard(showOpenVideoHint: true)
                                    .frame(maxWidth: availableWidth)
                                    .frame(maxHeight: availableHeight)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            }
                        }
                        .frame(minHeight: 300)
                }

                if model.timeline.player != nil {
                    FrameStripView(
                        asset: model.timeline.player?.currentItem?.asset,
                        assetURL: model.timeline.currentVideoAssetURL,
                        currentTimeMs: model.timeline.currentTimeMs,
                        durationMs: model.timeline.durationMs,
                        keyboardFineModeToken: keyboardFineModeToken,
                        autoFineModeToken: model.frameStripFineModeToken,
                        sceneTransitions: model.detectedScenes,
                        onSeek: { model.seekTimeline(to: $0) }
                    )
                }

                TimelineView(
                    durationMs: model.effectiveDurationMs,
                    videoDurationMs: model.timeline.durationMs,
                    currentTimeMs: model.timeline.currentTimeMs,
                    zoom: $model.zoomLevel,
                    minimumZoom: model.minimumZoomLevel,
                    serverSegments: model.serverSegments,
                    drafts: model.localDrafts,
                    autoRecapDraftKeys: model.autoRecapDraftKeys,
                    noSegmentFlags: model.noSegmentFlags,
                    audioTrack: model.audioWaveformTrack,
                    isAutoRecapEnabled: model.isAutoRecapDetectionEnabled,
                    hasSubtitleSourceConfigured: model.hasRecapSubtitleSourceConfigured,
                    onToggleAutoRecap: {
                        let hasSource = model.hasRecapSubtitleSourceConfigured
                        let enabling = !model.isAutoRecapDetectionEnabled
                        if enabling && !hasSource {
                            model.recapDetectionMessage = "OpenSubtitles API key or local subtitle folder missing."
                            return
                        }
                        model.isAutoRecapDetectionEnabled = enabling
                        if enabling {
                            Task { await model.detectRecap() }
                        } else {
                            model.clearRecapHint()
                        }
                    },
                    isSceneDetectionEnabled: model.isSceneDetectionEnabled,
                    onToggleSceneDetection: { model.toggleSceneDetection() },
                    isMusicLikelihoodEnabled: model.isMusicLikelihoodEnabled,
                    onToggleMusicLikelihood: { model.toggleMusicLikelihood() },
                    isSubmissionLoggingEnabled: model.isSubmissionLoggingEnabled,
                    onToggleSubmissionLogging: { model.toggleSubmissionLogging() },
                    onSeek: { model.seekTimeline(to: $0) },
                    onSegmentDragSelect: { model.setDraftRange($0, startMs: $1, endMs: $2) },
                    onDraftStartDrag: { model.setDraftStartMs($0, index: $1, ms: $2) },
                    onDraftEndDrag: { model.setDraftEndMs($0, index: $1, ms: $2) },
                    onDraftMove: { model.moveDraft($0, index: $1, to: $2, startMs: $3, endMs: $4) },
                    onDraftHandleDragBegan: { model.beginSegmentDragChange() },
                    onDraftHandleDragEnded: { model.endSegmentDragChange() },
                    onMinimumZoomComputed: { model.updateMinimumZoom($0) },
                    videoLoadID: model.videoLoadID
                )
            } else {
                VStack(spacing: 12) {
                    ListReviewPane(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    TimelineView(
                        durationMs: model.effectiveDurationMs,
                        videoDurationMs: model.selectedReviewItem?.videoDurationMs ?? model.effectiveDurationMs,
                        currentTimeMs: model.timeline.currentTimeMs,
                        zoom: $model.zoomLevel,
                        minimumZoom: model.minimumZoomLevel,
                        serverSegments: model.serverSegments,
                        drafts: model.localDrafts,
                        autoRecapDraftKeys: model.autoRecapDraftKeys,
                        noSegmentFlags: model.noSegmentFlags,
                        audioTrack: .empty,
                        isAutoRecapEnabled: false,
                        hasSubtitleSourceConfigured: false,
                        onToggleAutoRecap: {},
                        isSceneDetectionEnabled: false,
                        onToggleSceneDetection: {},
                        isMusicLikelihoodEnabled: false,
                        onToggleMusicLikelihood: {},
                        isSubmissionLoggingEnabled: model.isSubmissionLoggingEnabled,
                        onToggleSubmissionLogging: { model.toggleSubmissionLogging() },
                        onSeek: { model.seekTimeline(to: $0) },
                        onSegmentDragSelect: { model.setDraftRange($0, startMs: $1, endMs: $2) },
                        onDraftStartDrag: { model.setDraftStartMs($0, index: $1, ms: $2) },
                        onDraftEndDrag: { model.setDraftEndMs($0, index: $1, ms: $2) },
                        onDraftMove: { model.moveDraft($0, index: $1, to: $2, startMs: $3, endMs: $4) },
                        onDraftHandleDragBegan: { model.beginSegmentDragChange() },
                        onDraftHandleDragEnded: { model.endSegmentDragChange() },
                        onMinimumZoomComputed: { model.updateMinimumZoom($0) },
                        videoLoadID: model.videoLoadID,
                        draftOutlineOnly: true
                    )
                    .frame(minHeight: 180, alignment: .bottom)
                }
            }
        }
        .padding(14)
        .onAppear {
            if model.appMode == .singleVideo {
                DispatchQueue.main.async {
                    model.requestPlayerFocus()
                }
                installArrowKeyMonitorIfNeeded()
            }
        }
        .onDisappear {
            removeArrowKeyMonitor()
        }
    }

    private func installArrowKeyMonitorIfNeeded() {
        guard arrowKeyMonitor == nil else { return }
        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Keep frame-strip refinement responsive on arrow-key navigation,
            // while letting menu-command shortcuts handle actual actions.
            switch event.keyCode {
            case 123, 124: // Left / Right arrows
                keyboardFineModeToken &+= 1
            default:
                break
            }
            return event
        }
    }

    private func removeArrowKeyMonitor() {
        if let arrowKeyMonitor {
            NSEvent.removeMonitor(arrowKeyMonitor)
            self.arrowKeyMonitor = nil
        }
    }
}

private struct ListReviewPane: View {
    @Bindable var model: AppModel

    private var groupedItems: [(key: String, title: String, posterURL: URL?, rows: [ListReviewItem])] {
        let grouped = Dictionary(grouping: model.reviewListItems, by: { $0.groupKey })
        return grouped
            .map { key, rows in
                let sortedRows = rows.sorted {
                    let lSeason = $0.season ?? 0
                    let rSeason = $1.season ?? 0
                    if lSeason == rSeason {
                        return ($0.episode ?? 0) < ($1.episode ?? 0)
                    }
                    return lSeason < rSeason
                }
                return (key: key, title: sortedRows.first?.displayTitle ?? "Untitled", posterURL: sortedRows.first?.posterURL, rows: sortedRows)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        if model.reviewListItems.isEmpty {
            ContentUnavailableView(
                "No Review List Items",
                systemImage: "list.bullet.rectangle",
                description: Text("Use TMDB load or import segment JSON to populate compact review rows.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedItems, id: \.key) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(group.title) \(tmdbLabel(for: group.rows.first))")
                                    .font(.headline)
                                Spacer()
                                if model.hasNextQueuedImportedTMDB {
                                    Button {
                                        Task { await model.loadNextImportedTMDBGroup() }
                                    } label: {
                                        Label("Next TMDB", systemImage: "arrow.right.circle")
                                            .labelStyle(.titleAndIcon)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .help("Loads the next imported TMDB ID and replaces the current review list")
                                }
                                Button {
                                    model.removeReviewGroup(group.key)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.bordered)
                                Button {
                                    Task { await model.submitReviewGroup(group.key) }
                                } label: {
                                    Label("Submit All", systemImage: "arrow.up")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.bordered)
                            }

                            Divider()

                            HStack(alignment: .top, spacing: 12) {
                                poster(for: group.posterURL)

                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                                        if shouldShowSeasonDivider(rows: group.rows, at: index) {
                                            seasonDividerLabel(for: row.season)
                                        }

                                        CompactReviewRow(
                                            item: row,
                                            isSelected: row.id == model.selectedReviewListItemID,
                                            onSelect: {
                                                model.selectReviewListItem(row.id)
                                            },
                                            onSubmit: {
                                                Task { await model.submitReviewListItem(row.id) }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                }
                .padding(.vertical, 6)
            }
        }
    }

    private func poster(for url: URL?) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.black.opacity(0.08))
            .frame(width: 64, height: 96)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            Color.clear
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func tmdbLabel(for item: ListReviewItem?) -> String {
        guard let item else { return "" }
        if let tmdbId = item.tmdbId {
            return "(TMDB \(tmdbId))"
        }
        return ""
    }

    private func shouldShowSeasonDivider(rows: [ListReviewItem], at index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        if index == 0 { return rows[index].season != nil }
        return rows[index].season != rows[index - 1].season
    }

    @ViewBuilder
    private func seasonDividerLabel(for season: Int?) -> some View {
        if let season {
            HStack(spacing: 8) {
                Capsule()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 12, height: 3)
                Text("Season \(season)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 1)
            }
            .padding(.top, 4)
            .padding(.bottom, 1)
        }
    }
}

private struct CompactReviewRow: View {
    let item: ListReviewItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onSubmit: () -> Void

    private let comparisonHighlightThresholdMs = 500

    private var effectiveDuration: Int {
        let publicEnds = item.segmentGroups.values
            .flatMap { $0 }
            .compactMap { $0.endMs ?? $0.startMs }
        let draftSource = item.draftSegmentGroups.isEmpty ? item.segmentGroups : item.draftSegmentGroups
        let draftEnds = draftSource.values
            .flatMap { $0 }
            .compactMap { $0.endMs ?? $0.startMs }
        let ends = publicEnds + draftEnds
        return max(item.videoDurationMs ?? 0, ends.max() ?? 0, 1)
    }

    private var publicSegmentGroups: [SegmentType: [SegmentRange]] {
        item.segmentGroups.isEmpty
            ? item.segments.reduce(into: [:]) { partial, entry in partial[entry.key] = [entry.value] }
            : item.segmentGroups
    }

    private var activeDraftSegmentGroups: [SegmentType: [SegmentRange]] {
        if item.draftSegmentGroups.isEmpty {
            if !item.draftSegments.isEmpty {
                return item.draftSegments.reduce(into: [:]) { partial, entry in partial[entry.key] = [entry.value] }
            }
            return publicSegmentGroups
        }
        return item.draftSegmentGroups
    }

    private func barMetrics(for segment: SegmentRange, width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        let startValue = segment.startMs ?? 0
        let endValue = segment.endMs ?? effectiveDuration
        guard endValue > startValue else { return nil }

        let startRatio = max(0, min(1, CGFloat(startValue) / CGFloat(effectiveDuration)))
        let endRatio = max(0, min(1, CGFloat(endValue) / CGFloat(effectiveDuration)))
        let barWidth = max((endRatio - startRatio) * width, 2)
        return (x: startRatio * width, width: barWidth)
    }

    private func normalizedStartMs(for segment: SegmentRange) -> Int {
        max(segment.startMs ?? 0, 0)
    }

    private func normalizedEndMs(for segment: SegmentRange) -> Int {
        max(segment.endMs ?? effectiveDuration, 0)
    }

    private func timingDifferenceMs(between draft: SegmentRange, and publicRange: SegmentRange) -> Int {
        max(
            abs(normalizedStartMs(for: draft) - normalizedStartMs(for: publicRange)),
            abs(normalizedEndMs(for: draft) - normalizedEndMs(for: publicRange))
        )
    }

    private func shouldHighlightDifference(segmentType: SegmentType, draftIndex: Int) -> Bool {
        let publicRanges = publicSegmentGroups[segmentType] ?? []
        let draftRanges = activeDraftSegmentGroups[segmentType] ?? []

        guard draftIndex < draftRanges.count else { return false }
        guard draftIndex < publicRanges.count else { return true }
        return timingDifferenceMs(between: draftRanges[draftIndex], and: publicRanges[draftIndex]) > comparisonHighlightThresholdMs
    }

    @ViewBuilder
    private func publicBars(for segmentType: SegmentType, width: CGFloat) -> some View {
        let ranges = publicSegmentGroups[segmentType] ?? []
        ForEach(Array(ranges.enumerated()), id: \.offset) { _, segment in
            if let metrics = barMetrics(for: segment, width: width) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(segmentType.color.opacity(0.28))
                    .frame(width: metrics.width, height: 10)
                    .offset(x: metrics.x)
            }
        }
    }

    @ViewBuilder
    private func draftBars(for segmentType: SegmentType, width: CGFloat) -> some View {
        let ranges = activeDraftSegmentGroups[segmentType] ?? []
        ForEach(Array(ranges.enumerated()), id: \.offset) { draftIndex, segment in
            if let metrics = barMetrics(for: segment, width: width) {
                let highlightDifference = shouldHighlightDifference(segmentType: segmentType, draftIndex: draftIndex)
                if highlightDifference {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.yellow.opacity(0.95), lineWidth: 3)
                        .frame(width: metrics.width + 2, height: 12)
                        .offset(x: metrics.x - 1, y: 0)
                }

                RoundedRectangle(cornerRadius: 2)
                    .stroke(segmentType.color, lineWidth: 1.6)
                    .frame(width: metrics.width, height: 10)
                    .offset(x: metrics.x)
            }
        }
    }

    private var statusText: String? {
        guard let submitMessage = item.submitMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !submitMessage.isEmpty else {
            return nil
        }
        return submitMessage
    }

    private var statusColor: Color? {
        guard let statusText else { return nil }
        switch statusText.lowercased() {
        case "accepted":
            return .green
        case "pending":
            return .orange
        case "rejected":
            return .red
        default:
            return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(item.rowLabel)
                .font(.caption.monospacedDigit())
                .frame(width: 58, alignment: .leading)

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.22))
                        .frame(height: 10)

                    ForEach(SegmentType.allCases, id: \.self) { segmentType in
                        publicBars(for: segmentType, width: width)
                        draftBars(for: segmentType, width: width)
                    }
                }
            }
            .frame(height: 10)

            if let statusText, let statusColor {
                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12), in: Capsule())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 72, alignment: .center)
            } else {
                Text(" ")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 72, height: 18)
                    .hidden()
            }

            Button {
                onSubmit()
            } label: {
                if item.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .frame(width: 28, height: 24)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 0.8)
        )
    }
}

private struct TimelineUXHelpCard: View {
    let showOpenVideoHint: Bool

    private var draftRows: [(String, String)] {
        [
            ("I / ⇧I / ⌥I", "Start / End / No Intro"),
            ("R / ⇧R / ⌥R", "Start / End / No Recap"),
            ("C / ⇧C / ⌥C", "Start / End / No Credits"),
            ("P / ⇧P / ⌥P", "Start / End / No Preview")
        ]
    }

    private var jumpRows: [(String, String)] {
        [
            ("⌘I / ⌘⇧I", "Next Intro Start / End"),
            ("⌘R / ⌘⇧R", "Next Recap Start / End"),
            ("⌘C / ⌘⇧C", "Next Credits Start / End"),
            ("⌘P / ⌘⇧P", "Next Preview Start / End")
        ]
    }

    private var boundaryRows: [(String, String)] {
        [
            ("⇧← / ⇧→", "Jump to previous / next scene transition"),
            ("⌘← / ⌘→", "Nudge nearest boundary ±1 frame"),
            ("⌥← / ⌥→", "Nudge nearest boundary ±1 s"),
            (",", "Move nearest boundary to playhead")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if showOpenVideoHint {
                    Label("Open a local video file to begin", systemImage: "film")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                Text("Quick controls")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ShortcutGroupCard(title: "Draft", rows: draftRows)
                        ShortcutGroupCard(title: "Jump", rows: jumpRows)
                        ShortcutGroupCard(title: "Boundary", rows: boundaryRows)
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ShortcutGroupCard(title: "Draft", rows: draftRows)
                        ShortcutGroupCard(title: "Jump", rows: jumpRows)
                        ShortcutGroupCard(title: "Boundary", rows: boundaryRows)
                    }
                }

                Divider()

                Text("Timeline UX")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 6) {
                    uxHint("arrow.right.circle", "⌘⇧N", "Open next video file")
                    uxHint("arrow.left.and.line.vertical.and.arrow.right", "Drag on timeline", "Seek playhead")
                    uxHint("photo.on.rectangle", "Click thumbnail in frame strip", "Seek and switch to single-frame mode")
                    uxHint("arrow.up.left.and.arrow.down.right", "⌥ + Drag", "Create segment in hovered row")
                    uxHint("arrow.up.and.down.and.arrow.left.and.right", "⇧ + Drag on draft bar", "Move complete segment and change row/type")
                    uxHint("arrowtriangle.left.and.line.vertical.and.arrowtriangle.right.fill", "Drag segment edges", "Adjust start and end")
                    uxHint("arrow.down.to.line.compact", "Set icon beside time fields", "Copy current playhead into start/end")
                    uxHint("scope", "Scope icon", "Jump playhead to boundary")
                    uxHint("arrow.up.and.down", "Vertical trackpad scroll", "Zoom timeline")
                }
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

private struct ShortcutGroupCard: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                compactShortcutLine(row.0, row.1)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.18))
        )
    }
}

private struct FocusablePlayerView: NSViewRepresentable {
    let player: AVPlayer
    let requestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        context.coordinator.lastRequestID = requestID
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }

        guard context.coordinator.lastRequestID != requestID else { return }
        context.coordinator.lastRequestID = requestID
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator {
        var lastRequestID = 0
    }
}

private struct CompactShortcutLine: View {
    let key: String
    let action: String

    private var keyParts: [String] {
        key
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(keyParts.enumerated()), id: \.offset) { index, part in
                    Text(part)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.black.opacity(0.12))
                        )

                    if index < keyParts.count - 1 {
                        Text("/")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 88, alignment: .leading)

            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.28))
        )
    }
}

private struct UXHintRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .padding(.top, 1)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func compactShortcutLine(_ key: String, _ action: String) -> some View {
    CompactShortcutLine(key: key, action: action)
}

private func uxHint(_ symbol: String, _ title: String, _ detail: String) -> some View {
    UXHintRow(symbol: symbol, title: title, detail: detail)
}

// MARK: - Frame Strip

private struct FrameStripView: View {
    let asset: AVAsset?
    let assetURL: URL?
    let currentTimeMs: Int
    let durationMs: Int
    let keyboardFineModeToken: Int
    let autoFineModeToken: Int
    let sceneTransitions: [SceneChange]
    let onSeek: (Int) -> Void

    private let halfCount = 6
    private let baseThumbHeight: CGFloat = 52
    private let minThumbHeight: CGFloat = 32
    private let maxThumbHeight: CGFloat = 60
    private let minThumbWidth: CGFloat = 24
    private let maxThumbWidth: CGFloat = 120
    private let labelHeight: CGFloat = 14
    private let stripVerticalPadding: CGFloat = 4

    @State private var thumbnails: [String: ThumbnailEntry] = [:]
    @State private var prevSceneThumbnail: ThumbnailEntry?
    @State private var nextSceneThumbnail: ThumbnailEntry?
    @State private var frameSpec = FrameStripSpec.default
    @State private var generator: FrameImageGenerator?
    @State private var temporalMode: FrameTemporalMode = .coarse
    @State private var focusedTimeMs: Int?
    @State private var lastObservedPlayheadMs: Int?
    @State private var lastObservedAt = Date.distantPast
    @State private var suppressActivityUntil = Date.distantPast
    @State private var keyboardFineModeUntil = Date.distantPast
    @State private var isPlayheadSettled = true
    @State private var isFastSeeking = false
    @State private var lastThumbnailLoadAt = Date.distantPast
    @State private var playheadIdleToken = UUID()
    @State private var assetSessionToken = UUID()
    /// Time-keyed image cache that survives scope changes; used as fallback while
    /// new thumbnails for the current scope are still loading.
    @State private var fallbacksByMs: [Int: NSImage] = [:]
    /// Cache-keyed fallback to keep each strip slot stable across passes.
    @State private var fallbacksByCacheKey: [String: NSImage] = [:]

    private var anchorTimeMs: Int {
        focusedTimeMs ?? currentTimeMs
    }

    /// The time range covered by the regular thumbnail cells, so scene slots only
    /// show transitions that are outside the visible strip window.
    private var stripVisibleRange: (min: Int, max: Int) {
        let times = frameItems.map { Int($0.displayMs.rounded()) }
        return (times.min() ?? anchorTimeMs, times.max() ?? anchorTimeMs)
    }

    private var prevTransitionMs: Int? {
        let minMs = stripVisibleRange.min
        return sceneTransitions.map(\.timestampMs).filter { $0 < minMs }.max()
    }

    private var nextTransitionMs: Int? {
        let maxMs = stripVisibleRange.max
        return sceneTransitions.map(\.timestampMs).filter { $0 > maxMs }.min()
    }

    private var sceneTransitionLoadKey: String {
        "\(prevTransitionMs ?? -1)-\(nextTransitionMs ?? -1)"
    }

    private var coarseStepMs: Int {
        // Use half of the fine-window span so adjacent overview picks overlap.
        // This keeps a cut visible after one refinement and avoids repeated edge hopping.
        let seconds = 6.0 / max(frameSpec.fps, 1)
        return max(1, Int((seconds * 1000).rounded()))
    }

    private var anchorCoarseMs: Int {
        let step = coarseStepMs
        return (anchorTimeMs / step) * step
    }

    private var anchorFrameIndex: Int {
        let seconds = Double(anchorTimeMs) / 1000.0
        return max(0, Int((seconds * frameSpec.fps).rounded()))
    }

    private var frameDurationMs: Double {
        1000.0 / max(frameSpec.fps, 1)
    }

    private var fineStepToleranceMs: Double {
        max(frameDurationMs * 1.5, 20)
    }

    // Motion-state thumbnail reload throttle.
    private let motionReloadThrottleSeconds: TimeInterval = 0.2
    // If playhead timestamp stays unchanged for this long, treat it as idle and reload.
    private let playheadIdleReloadDelay: Duration = .milliseconds(200)
    // 1x playback/scrub speed in ms/sec.
    private let realtimeSpeedThresholdMsPerSec: Double = 1000
    // ms/sec; slightly above 1x to avoid false positives from timing jitter.
    private let fastSeekThresholdMsPerSec: Double = 1100

    private var frameItems: [StripFrameItem] {
        switch temporalMode {
        case .coarse:
            return (0..<(halfCount * 2 + 1)).map { i in
                let raw = anchorCoarseMs + (i - halfCount) * coarseStepMs
                let boundedMs = boundedTimeMs(raw)
                return StripFrameItem(
                    id: "coarse-\(i)-\(boundedMs)",
                    cacheKey: "coarse-\(boundedMs)",
                    displayMs: Double(boundedMs),
                    requestSeconds: Double(boundedMs) / 1000.0,
                    expectedFrameIndex: nil
                )
            }
        case .fine:
            return (0..<(halfCount * 2 + 1)).map { i in
                let raw = anchorFrameIndex + (i - halfCount)
                let boundedIndex = boundedFrameIndex(raw)
                let seconds = Double(boundedIndex) / frameSpec.fps
                return StripFrameItem(
                    id: "fine-\(i)-\(boundedIndex)",
                    cacheKey: "fine-\(boundedIndex)",
                    displayMs: seconds * 1000,
                    requestSeconds: seconds,
                    expectedFrameIndex: boundedIndex
                )
            }
        }
    }

    private var closestFrameID: String {
        frameItems.min(by: {
            abs(resolvedTimeMs(for: $0) - Double(currentTimeMs)) < abs(resolvedTimeMs(for: $1) - Double(currentTimeMs))
        })?.id ?? ""
    }

    private var selectedFrameID: String {
        if temporalMode == .coarse,
           frameItems.indices.contains(halfCount) {
            return frameItems[halfCount].id
        }
        return closestFrameID
    }

    private var stripHeight: CGFloat {
        baseThumbHeight + labelHeight + stripVerticalPadding * 2
    }

    private var modeBadgeText: String {
        switch temporalMode {
        case .coarse:
            return "Overview \(coarseStepMs) ms"
        case .fine:
            return "Single Frames"
        }
    }

    private var modeBadgeDetail: String {
        let fpsText = String(format: "%.2f", frameSpec.fps)
        switch temporalMode {
        case .coarse:
            return "step = 6/fps, fps \(fpsText)"
        case .fine:
            return "1 frame step, fps \(fpsText)"
        }
    }

    private var loadKey: String {
        switch temporalMode {
        case .coarse:
            return "coarse-\(anchorCoarseMs)-\(coarseStepMs)"
        case .fine:
            return "fine-\(anchorFrameIndex)"
        }
    }

    private func boundedFrameIndex(_ frameIndex: Int) -> Int {
        let bounded = max(0, frameIndex)
        if let maxFrameIndex = frameSpec.maxFrameIndex {
            return min(bounded, maxFrameIndex)
        }
        return bounded
    }

    private func boundedTimeMs(_ ms: Int) -> Int {
        let bounded = max(0, ms)
        if durationMs > 0 {
            return min(bounded, durationMs)
        }
        return bounded
    }

    private func activateFineMode(at ms: Int) {
        temporalMode = .fine
        focusedTimeMs = snappedFineFrameTimeMs(for: ms)
        suppressActivityUntil = Date().addingTimeInterval(0.45)
        // Do not debounce immediately after a click-to-refine transition.
        isPlayheadSettled = true
    }

    private func snappedFineFrameTimeMs(for ms: Int) -> Int {
        let seconds = Double(boundedTimeMs(ms)) / 1000.0
        let index = boundedFrameIndex(Int((seconds * frameSpec.fps).rounded()))
        let snappedSeconds = Double(index) / frameSpec.fps
        return boundedTimeMs(Int((snappedSeconds * 1000).rounded()))
    }

    private func resolvedTimeMs(for item: StripFrameItem) -> Double {
        if temporalMode == .fine {
            // Keep fine-mode stepping deterministic even when generator returns
            // a nearby decode timestamp.
            return item.displayMs
        }
        return Double(thumbnails[item.cacheKey]?.actualTimeMs ?? Int(item.displayMs.rounded()))
    }

    /// Returns the best available image for a frame item: primary cache first,
    /// then the nearest fallback from a previous scope (within 2 coarse steps).
    private func resolvedImage(for item: StripFrameItem) -> NSImage? {
        if let image = thumbnails[item.cacheKey]?.image { return image }
        if let image = fallbacksByCacheKey[item.cacheKey] { return image }
        let targetMs = Int(resolvedTimeMs(for: item).rounded())
        let toleranceMs = max(coarseStepMs * 2, 500)
        return fallbacksByMs
            .filter { abs($0.key - targetMs) <= toleranceMs }
            .min { abs($0.key - targetMs) < abs($1.key - targetMs) }
            .map(\.value)
    }

    private func tolerance(for item: StripFrameItem) -> CMTime {
        switch temporalMode {
        case .coarse:
            return CMTime(value: CMTimeValue(max(1, coarseStepMs / 2)), timescale: 1000)
        case .fine:
            // Fine mode must match real frames exactly.
            return .zero
        }
    }

    private func frameIndex(forTimeMs ms: Int) -> Int {
        let seconds = Double(max(0, ms)) / 1000.0
        return boundedFrameIndex(Int((seconds * frameSpec.fps).rounded()))
    }

    private func acceptsDecodedThumbnail(_ entry: ThumbnailEntry, for item: StripFrameItem) -> Bool {
        // Fine mode is expected to be frame-accurate: only accept exact decoder-frame matches.
        guard temporalMode == .fine else { return true }
        guard let expectedFrameIndex = item.expectedFrameIndex else { return true }
        let actualFrameIndex = frameIndex(forTimeMs: entry.actualTimeMs)
        return actualFrameIndex == expectedFrameIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(modeBadgeText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(temporalMode == .coarse ? Color.blue.opacity(0.18) : Color.green.opacity(0.2))
                    )

                Text(modeBadgeDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .opacity(isPlayheadSettled ? 0 : 1)

                Spacer(minLength: 0)
            }

            GeometryReader { geo in
                let count = CGFloat(halfCount * 2 + 1 + 2) // +2 for scene transition slots
                let spacing: CGFloat = 2
                let rawThumbWidth = (geo.size.width - spacing * (count - 1)) / count
                let thumbWidth = min(maxThumbWidth, max(minThumbWidth, rawThumbWidth))
                let adaptiveHeight = min(maxThumbHeight, max(minThumbHeight, thumbWidth * (9.0 / 16.0)))
                let thumbHeight = min(maxThumbHeight, max(minThumbHeight, adaptiveHeight))
                let cellHeight = thumbHeight + labelHeight

                HStack(spacing: spacing) {
                    // Left slot: previous scene transition
                    if let ms = prevTransitionMs {
                        SceneTransitionThumbCell(
                            timeMs: ms,
                            image: prevSceneThumbnail?.image,
                            direction: .previous,
                            onTap: {
                                activateFineMode(at: ms)
                                onSeek(ms)
                            }
                        )
                        .frame(width: thumbWidth, height: cellHeight)
                    } else {
                        Color.clear.frame(width: thumbWidth, height: cellHeight)
                    }

                    ForEach(frameItems, id: \.id) { item in
                        FrameThumbCell(
                            timeMs: resolvedTimeMs(for: item),
                            image: resolvedImage(for: item),
                            isCurrent: item.id == selectedFrameID,
                            onTap: {
                                let resolvedMs = Int(resolvedTimeMs(for: item).rounded())
                                activateFineMode(at: resolvedMs)
                                onSeek(resolvedMs)
                            }
                        )
                        .frame(width: thumbWidth, height: cellHeight)
                    }

                    // Right slot: next scene transition
                    if let ms = nextTransitionMs {
                        SceneTransitionThumbCell(
                            timeMs: ms,
                            image: nextSceneThumbnail?.image,
                            direction: .next,
                            onTap: {
                                activateFineMode(at: ms)
                                onSeek(ms)
                            }
                        )
                        .frame(width: thumbWidth, height: cellHeight)
                    } else {
                        Color.clear.frame(width: thumbWidth, height: cellHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.vertical, stripVerticalPadding)
            }
            .frame(height: stripHeight)
        }
        .task(id: assetURL) {
            let session = assetSessionToken
            await configureFrameSpec(session: session)
            await loadThumbnails(session: session, scopeKey: loadKey)
        }
        .task(id: loadKey) {
            await loadThumbnails(scopeKey: loadKey)
        }
        .task(id: sceneTransitionLoadKey) {
            await loadSceneTransitionThumbnails()
        }
        .onChange(of: currentTimeMs) { _, newValue in
            handlePlayheadChange(newValue)
            scheduleIdleReloadIfPlayheadUnchanged(expectedTimeMs: newValue)
        }
        .onChange(of: keyboardFineModeToken) { _, _ in
            activateKeyboardFineMode()
        }
        .onChange(of: autoFineModeToken) { _, _ in
            activateKeyboardFineMode()
        }
        .onChange(of: assetURL) { _, _ in
            assetSessionToken = UUID()
            thumbnails = [:]
            fallbacksByMs = [:]
            fallbacksByCacheKey = [:]
            prevSceneThumbnail = nil
            nextSceneThumbnail = nil
            generator?.cancelPendingRequests()
            generator = nil
            temporalMode = .coarse
            focusedTimeMs = nil
            isPlayheadSettled = true
            isFastSeeking = false
            lastThumbnailLoadAt = .distantPast
            playheadIdleToken = UUID()
            keyboardFineModeUntil = Date.distantPast
        }
    }

    private func scheduleIdleReloadIfPlayheadUnchanged(expectedTimeMs: Int) {
        let token = UUID()
        playheadIdleToken = token

        Task {
            try? await Task.sleep(for: playheadIdleReloadDelay)
            guard !Task.isCancelled, playheadIdleToken == token else { return }
            guard currentTimeMs == expectedTimeMs else { return }

            // Playback/scrub stopped producing new timestamps.
            isFastSeeking = false
            isPlayheadSettled = true
            await loadThumbnails(scopeKey: loadKey)
        }
    }

    private func activateKeyboardFineMode() {
        let now = Date()
        // Keep a slightly longer window so key-repeat and delayed observer
        // updates do not accidentally fall back to coarse mode.
        keyboardFineModeUntil = now.addingTimeInterval(0.7)
        suppressActivityUntil = now.addingTimeInterval(0.25)
        isFastSeeking = false
        isPlayheadSettled = true
        temporalMode = .fine
        focusedTimeMs = snappedFineFrameTimeMs(for: currentTimeMs)
    }

    private func handlePlayheadChange(_ newPlayheadMs: Int) {
        let now = Date()
        defer {
            lastObservedPlayheadMs = newPlayheadMs
            lastObservedAt = now
        }

        guard let lastMs = lastObservedPlayheadMs else {
            temporalMode = .coarse
            isFastSeeking = false
            return
        }

        let deltaMs = abs(newPlayheadMs - lastMs)
        guard deltaMs > 0 else { return }

        let dt = now.timeIntervalSince(lastObservedAt)
        let speed = dt > 0 ? Double(deltaMs) / dt : 0
        let isKeyboardDrivenStep = now < keyboardFineModeUntil
        let isSuppressed = now < suppressActivityUntil

        if isKeyboardDrivenStep {
            isFastSeeking = false
            temporalMode = .fine
            focusedTimeMs = snappedFineFrameTimeMs(for: newPlayheadMs)
            isPlayheadSettled = true
            return
        }

        let looksLikeDiscreteFrameStep =
            temporalMode == .coarse
            && isPlayheadSettled
            && dt >= 0.08
            && dt <= 1.2
            && Double(deltaMs) <= fineStepToleranceMs

        if looksLikeDiscreteFrameStep {
            isFastSeeking = false
            temporalMode = .fine
            focusedTimeMs = snappedFineFrameTimeMs(for: newPlayheadMs)
            isPlayheadSettled = true
            return
        }

        let isRealtimeOrFaster = speed >= realtimeSpeedThresholdMsPerSec

        // Force coarse mode immediately for normal playback / fast scrub (>= 1x),
        // before fine-step heuristics can keep fine mode alive.
        if isRealtimeOrFaster {
            temporalMode = .coarse
            focusedTimeMs = nil
        }

        let isFineStep = temporalMode == .fine && Double(deltaMs) <= fineStepToleranceMs

        if isFineStep || isSuppressed {
            isFastSeeking = false
            temporalMode = .fine
            focusedTimeMs = newPlayheadMs
            isPlayheadSettled = true
            return
        }

        let isFast = speed > fastSeekThresholdMsPerSec
        isFastSeeking = isFast
        if isFast {
            generator?.cancelPendingRequests()
        }

        isPlayheadSettled = false

        if speed > 700 {
            temporalMode = .coarse
            focusedTimeMs = nil
        }
    }

    private func loadSceneTransitionThumbnails() async {
        guard let asset else {
            prevSceneThumbnail = nil
            nextSceneThumbnail = nil
            return
        }
        if generator == nil {
            generator = FrameImageGenerator(asset: asset)
        }
        guard let gen = generator else { return }
        gen.setMaximumSize(CGSize(width: 32, height: 18))
        let tol = CMTime(value: CMTimeValue(max(1, coarseStepMs / 2)), timescale: 1000)

        let prevMs = prevTransitionMs
        if let ms = prevMs {
            if prevSceneThumbnail?.actualTimeMs != ms {
                let time = CMTime(seconds: Double(ms) / 1000.0, preferredTimescale: 600)
                if let entry = try? await gen.image(at: time, tolerance: tol) {
                    prevSceneThumbnail = entry
                }
            }
        } else {
            prevSceneThumbnail = nil
        }

        let nextMs = nextTransitionMs
        if let ms = nextMs {
            if nextSceneThumbnail?.actualTimeMs != ms {
                let time = CMTime(seconds: Double(ms) / 1000.0, preferredTimescale: 600)
                if let entry = try? await gen.image(at: time, tolerance: tol) {
                    nextSceneThumbnail = entry
                }
            }
        } else {
            nextSceneThumbnail = nil
        }
    }

    private func configureFrameSpec(session: UUID? = nil) async {
        let expectedSession = session ?? assetSessionToken
        guard expectedSession == assetSessionToken else { return }

        guard let asset else {
            guard expectedSession == assetSessionToken else { return }
            frameSpec = .default
            thumbnails = [:]
            return
        }

        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                frameSpec = .default
                thumbnails = [:]
                return
            }

            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let minFrameDuration = try await videoTrack.load(.minFrameDuration)
            let loadedDuration = try await asset.load(.duration)

            var fps = Double(nominalFrameRate)
            if !fps.isFinite || fps <= 0,
               minFrameDuration.isValid,
               minFrameDuration.seconds.isFinite,
               minFrameDuration.seconds > 0 {
                fps = 1.0 / minFrameDuration.seconds
            }
            if !fps.isFinite || fps <= 0 {
                fps = 30
            }
            fps = min(max(fps, 1), 120)

            var maxFrameIndex: Int?
            if loadedDuration.isValid,
               loadedDuration.seconds.isFinite,
               loadedDuration.seconds > 0 {
                maxFrameIndex = max(0, Int((loadedDuration.seconds * fps).rounded(.down)))
            } else if durationMs > 0 {
                maxFrameIndex = max(0, Int(((Double(durationMs) / 1000.0) * fps).rounded(.down)))
            }

            guard expectedSession == assetSessionToken else { return }
            frameSpec = FrameStripSpec(fps: fps, maxFrameIndex: maxFrameIndex)
            thumbnails = [:]
            generator?.cancelPendingRequests()
            generator = FrameImageGenerator(asset: asset)
        } catch {
            guard expectedSession == assetSessionToken else { return }
            frameSpec = .default
            thumbnails = [:]
            generator?.cancelPendingRequests()
            generator = nil
        }
    }

    private func loadThumbnails(session: UUID? = nil, scopeKey: String? = nil) async {
        let expectedSession = session ?? assetSessionToken
        guard expectedSession == assetSessionToken else { return }
        let expectedScopeKey = scopeKey ?? loadKey
        guard expectedScopeKey == loadKey else {
            generator?.cancelPendingRequests()
            return
        }

        guard !isFastSeeking else { return }

        let now = Date()
        if !isPlayheadSettled,
           now.timeIntervalSince(lastThumbnailLoadAt) < motionReloadThrottleSeconds {
            return
        }
        lastThumbnailLoadAt = now

        guard let asset else { return }
        // Keep thumbnails from previous scopes so the strip never goes blank;
        // flush when the cache grows large to bound memory usage.
        if thumbnails.count > 150 { thumbnails.removeAll() }
        let items = frameItems

        // Prioritize center-first loading so fine mode becomes useful immediately.
        let sortedByCenter = items.enumerated()
            .sorted { abs($0.offset - halfCount) < abs($1.offset - halfCount) }
            .map(\.element)

        var seenKeys = Set<String>()
        var needed: [StripFrameItem] = []
        needed.reserveCapacity(sortedByCenter.count)
        for item in sortedByCenter {
            guard thumbnails[item.cacheKey] == nil else { continue }
            guard seenKeys.insert(item.cacheKey).inserted else { continue }
            needed.append(item)
        }
        guard !needed.isEmpty else { return }

        if generator == nil {
            generator = FrameImageGenerator(asset: asset)
        }
        guard let genBox = generator else { return }

        // Use one fixed low-power thumbnail size across all modes.
        genBox.setMaximumSize(CGSize(width: 32, height: 18))

        // Load the 5 center-most frames first so the strip is useful immediately,
        // then verify the scope is still current before loading the outer frames.
        let priorityBatch = needed.prefix(5)
        let remainingBatch = needed.dropFirst(5)

        for item in priorityBatch {
            guard expectedSession == assetSessionToken else { return }
            guard expectedScopeKey == loadKey else {
                generator?.cancelPendingRequests()
                return
            }
            guard !Task.isCancelled else { return }
            let requestTimescale: CMTimeScale = temporalMode == .fine ? 60000 : 600
            let time = CMTime(seconds: item.requestSeconds, preferredTimescale: requestTimescale)
            if let entry = try? await genBox.image(at: time, tolerance: tolerance(for: item)) {
                guard expectedSession == assetSessionToken else { return }
                guard expectedScopeKey == loadKey else {
                    generator?.cancelPendingRequests()
                    return
                }
                guard acceptsDecodedThumbnail(entry, for: item) else { continue }
                thumbnails[item.cacheKey] = entry
                if fallbacksByCacheKey.count >= 400 { fallbacksByCacheKey.removeAll() }
                fallbacksByCacheKey[item.cacheKey] = entry.image
                if fallbacksByMs.count >= 200 { fallbacksByMs.removeAll() }
                fallbacksByMs[entry.actualTimeMs] = entry.image
            }
        }

        // Explicit checkpoint before loading outer frames.
        guard expectedSession == assetSessionToken else { return }
        guard expectedScopeKey == loadKey else {
            generator?.cancelPendingRequests()
            return
        }
        guard !Task.isCancelled else { return }

        for item in remainingBatch {
            guard expectedSession == assetSessionToken else { return }
            guard expectedScopeKey == loadKey else {
                generator?.cancelPendingRequests()
                return
            }
            guard !Task.isCancelled else { return }
            let requestTimescale: CMTimeScale = temporalMode == .fine ? 60000 : 600
            let time = CMTime(seconds: item.requestSeconds, preferredTimescale: requestTimescale)
            if let entry = try? await genBox.image(at: time, tolerance: tolerance(for: item)) {
                guard expectedSession == assetSessionToken else { return }
                guard expectedScopeKey == loadKey else {
                    generator?.cancelPendingRequests()
                    return
                }
                guard acceptsDecodedThumbnail(entry, for: item) else { continue }
                thumbnails[item.cacheKey] = entry
                if fallbacksByCacheKey.count >= 400 { fallbacksByCacheKey.removeAll() }
                fallbacksByCacheKey[item.cacheKey] = entry.image
                if fallbacksByMs.count >= 200 { fallbacksByMs.removeAll() }
                fallbacksByMs[entry.actualTimeMs] = entry.image
            }
        }
    }
}

private struct ThumbnailEntry {
    let image: NSImage
    let actualTimeMs: Int
}

private enum FrameTemporalMode {
    case coarse
    case fine
}

private struct StripFrameItem {
    let id: String
    let cacheKey: String
    let displayMs: Double
    let requestSeconds: Double
    let expectedFrameIndex: Int?
}

private struct FrameStripSpec {
    let fps: Double
    let maxFrameIndex: Int?

    static let `default` = FrameStripSpec(fps: 30, maxFrameIndex: nil)
}

/// Wraps AVAssetImageGenerator as @unchecked Sendable so it can cross
/// actor boundaries when calling the async image(at:) API.
private final class FrameImageGenerator: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(asset: AVAsset) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 32, height: 18)
    }

    func cancelPendingRequests() {
        generator.cancelAllCGImageGeneration()
    }

    func setMaximumSize(_ size: CGSize) {
        generator.maximumSize = size
    }

    func image(at time: CMTime, tolerance: CMTime) async throws -> ThumbnailEntry {
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let result = try await generator.image(at: time)
        let actualSeconds = result.actualTime.seconds
        let actualTimeMs: Int
        if actualSeconds.isFinite {
            actualTimeMs = max(0, Int((actualSeconds * 1000).rounded()))
        } else {
            actualTimeMs = max(0, Int((time.seconds * 1000).rounded()))
        }

        return ThumbnailEntry(
            image: NSImage(cgImage: result.image, size: .zero),
            actualTimeMs: actualTimeMs
        )
    }
}

private enum SceneTransitionDirection {
    case previous, next
}

private struct SceneTransitionThumbCell: View {
    let timeMs: Int
    let image: NSImage?
    let direction: SceneTransitionDirection
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                ZStack(alignment: direction == .previous ? .topLeading : .topTrailing) {
                    Color.black.opacity(0.25)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    Image(systemName: "scissors")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            Color.orange.opacity(isHovered ? 1.0 : 0.65),
                            lineWidth: 1.0
                        )
                }

                Text(TimeFormatting.display(ms: timeMs))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

private struct FrameThumbCell: View {
    let timeMs: Double
    let image: NSImage?
    let isCurrent: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                ZStack {
                    Color.black.opacity(0.2)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isCurrent ? Color.blue : Color.white.opacity(isHovered ? 0.5 : 0.12),
                            lineWidth: isCurrent ? 1.5 : 0.75
                        )
                }

                Text(TimeFormatting.display(ms: timeMs))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

private struct DraftTimeField: View {
    let value: Int?
    let placeholder: String
    let onSubmitValue: (String) -> Void

    @State private var text: String

    init(value: Int?, placeholder: String, onSubmitValue: @escaping (String) -> Void) {
        self.value = value
        self.placeholder = placeholder
        self.onSubmitValue = onSubmitValue
        _text = State(initialValue: TimeFormatting.display(ms: value))
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 92)
            .onSubmit {
                onSubmitValue(text)
            }
            .onChange(of: value) { _, newValue in
                text = TimeFormatting.display(ms: newValue)
            }
    }
}

private struct SegmentEditorRow: View {
    @Bindable var model: AppModel
    let segment: SegmentType

    var body: some View {
        let drafts = model.drafts(for: segment)
        let existingCount = model.serverSegments[segment]?.count ?? 0
        let templateDurationMs = model.templateDurationMs(for: segment)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(segment.displayName, systemImage: "timeline.selection")
                    .foregroundStyle(segment.color)

                Spacer()
                Text("Existing: \(existingCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Drafts: \(drafts.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            let effectiveDrafts = drafts.isEmpty ? [SegmentDraft.empty] : drafts
            let theIntroKeyFilled = !model.theIntroDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ForEach(Array(effectiveDrafts.enumerated()), id: \.offset) { index, draft in
                let isVirtual = drafts.isEmpty
                let isNoSegment = model.noSegmentFlags[segment] ?? false
                HStack {
                    Text("#\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 22, alignment: .leading)
                        .foregroundStyle(.secondary)

                    DraftTimeField(value: draft.startMs, placeholder: "--") { text in
                        model.updateDraftStartText(segment, index: index, text: text)
                    }
                    Button {
                        jumpToDraftTime(draft.startMs)
                    } label: {
                        Image(systemName: "scope")
                    }
                    .buttonStyle(.plain)
                    .help("Jump playhead to start")
                    .disabled(draft.startMs == nil)

                    Button {
                        if isVirtual {
                            model.setDraftStart(segment)
                        } else {
                            model.setDraftStartMs(segment, index: index, ms: model.timeline.currentTimeMs)
                        }
                    } label: {
                        Image(systemName: "arrow.down.to.line.compact")
                    }
                    .buttonStyle(.plain)
                    .help("Use current playhead as start")

                    Spacer()

                    DraftTimeField(value: draft.endMs, placeholder: "--") { text in
                        model.updateDraftEndText(segment, index: index, text: text)
                    }
                    Button {
                        jumpToDraftTime(draft.endMs)
                    } label: {
                        Image(systemName: "scope")
                    }
                    .buttonStyle(.plain)
                    .help("Jump playhead to end")
                    .disabled(draft.endMs == nil)

                    Button {
                        if isVirtual {
                            model.setDraftEnd(segment)
                        } else {
                            model.setDraftEndMs(segment, index: index, ms: model.timeline.currentTimeMs)
                        }
                    } label: {
                        Image(systemName: "arrow.down.to.line.compact")
                    }
                    .buttonStyle(.plain)
                    .help("Use current playhead as end")

                    if !isVirtual {
                        Button(role: .destructive) {
                            model.removeDraft(segment, index: index)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove draft")
                    }

                    if theIntroKeyFilled {
                        Button {
                            model.setNoSegment(segment, enabled: !isNoSegment)
                        } label: {
                            Image(systemName: isNoSegment ? "minus.circle.fill" : "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isNoSegment ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .help(isNoSegment ? "Remove no-\(segment.displayName) mark" : "Mark as no \(segment.displayName)")
                    }
                }
            }

            if let templateDurationMs {
                Text("Auto duration: \(TimeFormatting.display(ms: templateDurationMs))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    Task { await model.uploadSegment(segment) }
                } label: {
                    if model.isUploadingSegment(segment) {
                        ZStack {
                            Label("Upload \(segment.displayName)", systemImage: "icloud.and.arrow.up")
                                .opacity(0)
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Label("Upload \(segment.displayName)", systemImage: "icloud.and.arrow.up")
                    }
                }
                .disabled(model.isUploadingSegment(segment) || model.isUploadingAll)
            }

            if let status = model.submissionMessages[segment], !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func jumpToDraftTime(_ value: Int?) {
        guard let value else { return }
        model.seekTimeline(to: value)
        model.requestPlayerFocus()
    }
}
