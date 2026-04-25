import AVFoundation
import AVKit
import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

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

    private var apiKeyFillCount: Int {
        (introAPIKeyIsFilled ? 1 : 0) + (introDBAPIKeyIsFilled ? 1 : 0) + (tmdbAPIKeyIsFilled ? 1 : 0)
    }

    private var areAllAPIKeysFilled: Bool {
        apiKeyFillCount == 3
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                videoSection
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
                    Text("\(apiKeyFillCount)/3")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                        )
                    Spacer()
                    if areAllAPIKeysFilled {
                        Button(isAPIKeysSectionExpanded ? "Collapse" : "Edit") {
                            isAPIKeysSectionExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isAPIKeysSectionExpanded || !areAllAPIKeysFilled {
                    SecureField("TheIntroDB API key", text: $model.theIntroDBAPIKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField("IntroDB API key", text: $model.introDBAPIKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField("TMDB API key", text: $model.tmdbAPIKey)
                        .textFieldStyle(.roundedBorder)

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
                            Task { await model.fetchMedia(prefillDrafts: true) }
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
                        Task { await model.fetchMedia() }
                    } label: {
                        if model.isFetchingMedia {
                            Label {
                                Text("Load Existing Segments")
                            } icon: {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 14, height: 14)
                            }
                        } else {
                            Label("Load Existing Segments", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isFetchingMedia || model.isUploadingAll)

                    Button {
                        Task { await model.uploadAllSegments() }
                    } label: {
                        if model.isUploadingAll {
                            Label {
                                Text("Upload All Drafts")
                            } icon: {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 14, height: 14)
                            }
                        } else {
                            Label("Upload All Drafts", systemImage: "icloud.and.arrow.up.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(model.isUploadingAll || model.isFetchingMedia)
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
            if let player = model.timeline.player {
                FocusablePlayerView(player: player, requestID: model.playerFocusRequestID)
                    .frame(minHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.15))
                    .overlay {
                        TimelineUXHelpCard(showOpenVideoHint: true)
                            .padding(18)
                            .frame(maxWidth: 620, alignment: .center)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                audioTrack: model.audioWaveformTrack,
                onSeek: { model.seekTimeline(to: $0) },
                onSegmentDragSelect: { model.setDraftRange($0, startMs: $1, endMs: $2) },
                onDraftStartDrag: { model.setDraftStartMs($0, index: $1, ms: $2) },
                onDraftEndDrag: { model.setDraftEndMs($0, index: $1, ms: $2) },
                onDraftMove: { model.moveDraft($0, index: $1, to: $2, startMs: $3, endMs: $4) },
                onDraftHandleDragBegan: { model.beginSegmentDragChange() },
                onDraftHandleDragEnded: { model.endSegmentDragChange() },
                onMinimumZoomComputed: { model.updateMinimumZoom($0) }
                , videoLoadID: model.videoLoadID
            )
        }
        .padding(14)
        // Hidden keyboard shortcut buttons
        // I / ⇧I = Intro start / end
        // R / ⇧R = Recap start / end
        // C / ⇧C = Credits start / end
        .background {
            Group {
                Button("") { model.setDraftStart(.intro)   }.keyboardShortcut("i", modifiers: [])
                Button("") { model.setDraftEnd(.intro)     }.keyboardShortcut("I", modifiers: .shift)
                Button("") { model.setDraftStart(.recap)   }.keyboardShortcut("r", modifiers: [])
                Button("") { model.setDraftEnd(.recap)     }.keyboardShortcut("R", modifiers: .shift)
                Button("") { model.setDraftStart(.credits) }.keyboardShortcut("c", modifiers: [])
                Button("") { model.setDraftEnd(.credits)   }.keyboardShortcut("C", modifiers: .shift)
                Button("") { model.setDraftStart(.preview) }.keyboardShortcut("p", modifiers: [])
                Button("") { model.setDraftEnd(.preview)   }.keyboardShortcut("P", modifiers: .shift)
                Button("") { model.moveNearestSegmentEndToPlayhead() }.keyboardShortcut(",", modifiers: [])
                Button("") { model.requestPlayerFocus() }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onAppear {
            DispatchQueue.main.async {
                model.requestPlayerFocus()
            }
            installArrowKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeArrowKeyMonitor()
        }
    }

    private func installArrowKeyMonitorIfNeeded() {
        guard arrowKeyMonitor == nil else { return }
        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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

private struct TimelineUXHelpCard: View {
    let showOpenVideoHint: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showOpenVideoHint {
                Label("Open a local video file to begin", systemImage: "film")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Text("Quick controls")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    shortcutChip("I", "Intro start")
                    shortcutChip("⇧I", "Intro end")
                }
                HStack(spacing: 8) {
                    shortcutChip("R", "Recap start")
                    shortcutChip("⇧R", "Recap end")
                }
                HStack(spacing: 8) {
                    shortcutChip("C", "Credits start")
                    shortcutChip("⇧C", "Credits end")
                }
                HStack(spacing: 8) {
                    shortcutChip("P", "Preview start")
                    shortcutChip("⇧P", "Preview end")
                }
                HStack(spacing: 8) {
                    shortcutChip(",", "Move nearest boundary")
                }
            }

            Divider()

            Text("Timeline UX")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
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
        .padding(18)
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

private struct ShortcutChip: View {
    let key: String
    let action: String

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black.opacity(0.18))
                )

            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.35))
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

private func shortcutChip(_ key: String, _ action: String) -> some View {
    ShortcutChip(key: key, action: action)
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
                    requestSeconds: Double(boundedMs) / 1000.0
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
                    requestSeconds: seconds
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
                let count = CGFloat(halfCount * 2 + 1)
                let spacing: CGFloat = 2
                let rawThumbWidth = (geo.size.width - spacing * (count - 1)) / count
                let thumbWidth = min(maxThumbWidth, max(minThumbWidth, rawThumbWidth))
                let adaptiveHeight = min(maxThumbHeight, max(minThumbHeight, thumbWidth * (9.0 / 16.0)))
                let thumbHeight = min(maxThumbHeight, max(minThumbHeight, adaptiveHeight))

                HStack(spacing: spacing) {
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
                        .frame(width: thumbWidth, height: thumbHeight + labelHeight)
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
        .onChange(of: currentTimeMs) { _, newValue in
            handlePlayheadChange(newValue)
            scheduleIdleReloadIfPlayheadUnchanged(expectedTimeMs: newValue)
        }
        .onChange(of: keyboardFineModeToken) { _, _ in
            keyboardFineModeUntil = Date().addingTimeInterval(0.45)
            temporalMode = .fine
            focusedTimeMs = snappedFineFrameTimeMs(for: currentTimeMs)
        }
        .onChange(of: autoFineModeToken) { _, _ in
            keyboardFineModeUntil = Date().addingTimeInterval(0.45)
            temporalMode = .fine
            focusedTimeMs = snappedFineFrameTimeMs(for: currentTimeMs)
        }
        .onChange(of: assetURL) { _, _ in
            assetSessionToken = UUID()
            thumbnails = [:]
            fallbacksByMs = [:]
            fallbacksByCacheKey = [:]
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
        let isRealtimeOrFaster = speed >= realtimeSpeedThresholdMsPerSec

        // Force coarse mode immediately for normal playback / fast scrub (>= 1x),
        // before fine-step heuristics can keep fine mode alive.
        if isRealtimeOrFaster {
            temporalMode = .coarse
            focusedTimeMs = nil
        }

        let isFineStep = temporalMode == .fine && Double(deltaMs) <= fineStepToleranceMs
        let isKeyboardDrivenStep = now < keyboardFineModeUntil
        let isSuppressed = now < suppressActivityUntil

        if isKeyboardDrivenStep {
            isFastSeeking = false
            temporalMode = .fine
            focusedTimeMs = snappedFineFrameTimeMs(for: newPlayheadMs)
            isPlayheadSettled = true
            return
        }

        if isFineStep || isSuppressed {
            isFastSeeking = false
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

            if drafts.isEmpty {
                Text("No local drafts")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(drafts.enumerated()), id: \.offset) { index, draft in
                    HStack {
                        Text("#\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 22, alignment: .leading)
                            .foregroundStyle(.secondary)

                        DraftTimeField(value: draft.startMs, placeholder: "Start") { text in
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
                            model.setDraftStartMs(segment, index: index, ms: model.timeline.currentTimeMs)
                        } label: {
                            Image(systemName: "arrow.down.to.line.compact")
                        }
                        .buttonStyle(.plain)
                        .help("Use current playhead as start")

                        Spacer()

                        DraftTimeField(value: draft.endMs, placeholder: "End") { text in
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
                            model.setDraftEndMs(segment, index: index, ms: model.timeline.currentTimeMs)
                        } label: {
                            Image(systemName: "arrow.down.to.line.compact")
                        }
                        .buttonStyle(.plain)
                        .help("Use current playhead as end")

                        Button(role: .destructive) {
                            model.removeDraft(segment, index: index)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove draft")
                    }
                }
            }

            if let templateDurationMs {
                Text("Auto duration: \(TimeFormatting.display(ms: templateDurationMs))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Set Start @ Playhead") { model.setDraftStart(segment) }
                Button("Set End @ Playhead") { model.setDraftEnd(segment) }
                Button("Clear") { model.clearDraft(segment) }
                Spacer()
                Button {
                    Task { await model.uploadSegment(segment) }
                } label: {
                    if model.uploadingSegment == segment {
                        ZStack {
                            Text("Upload All")
                                .opacity(0)
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Text("Upload All")
                    }
                }
                .disabled(model.uploadingSegment != nil || model.isUploadingAll)
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
