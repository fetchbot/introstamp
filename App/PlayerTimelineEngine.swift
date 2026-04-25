import AVFoundation
import Accelerate
import AppKit
import Observation
import SoundAnalysis

@MainActor
@Observable
final class PlayerTimelineEngine {
    var player: AVPlayer?
    var currentTimeMs: Int = 0
    var durationMs: Int = 0
    var waveformBuckets: [Double] = []
    var musicLikelihoodBuckets: [Double] = []
    var isLoadingWaveform = false
    /// Tracks the URL of the asset currently backing the player item.
    /// For SMB/remote files this switches from the network URL to the local
    /// temp copy once the copy is complete, so observers can rebuild
    /// asset-based resources (e.g. thumbnail generators) from the local file.
    var currentVideoAssetURL: URL? = nil

    private var periodicObserver: Any?
    private let waveformExtractor = WaveformExtractor()
    private let musicLikelihoodExtractor = WaveformExtractor()
    private var currentTempVideoURL: URL?
    private var currentLoadID = UUID()
    private var currentWaveformAnalysisID = UUID()
    private var seekSequence: UInt64 = 0
    private var pendingSeekTargetMs: Int?
    private var videoLoadTask: Task<Void, Never>?
    private var remoteCopyTask: Task<Bool, Never>?
    private var remoteCopyTaskID = UUID()
    private var musicLikelihoodTask: Task<Void, Never>?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var frameDurationSeconds: Double = 0

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer runs on the main queue; use assumeIsolated so the
            // cleanup executes synchronously before the process exits.
            MainActor.assumeIsolated {
                self?.deleteTempVideoFile()
            }
        }
    }

    func loadVideo(url: URL) {
        videoLoadTask?.cancel()
        remoteCopyTask?.cancel()
        remoteCopyTaskID = UUID()
        musicLikelihoodTask?.cancel()
        clearObserver()
        deleteTempVideoFile()
        let loadID = UUID()
        currentLoadID = loadID
        currentWaveformAnalysisID = UUID()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentTimeMs = 0
        durationMs = 0
        waveformBuckets = []
        musicLikelihoodBuckets = []
        isLoadingWaveform = true
        currentVideoAssetURL = url
        frameDurationSeconds = 0

        addPeriodicObserver(to: player)
        addTimeControlStatusObserver(to: player)

        videoLoadTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await loadFrameDuration(from: item.asset)
            guard !Task.isCancelled else { return }
            await loadDuration(from: item.asset)
            guard !Task.isCancelled else { return }

            if isRemoteURL(url) {
                guard let localURL = await localVideoURL(for: url) else {
                    guard currentLoadID == loadID else { return }
                    isLoadingWaveform = false
                    waveformBuckets = []
                    musicLikelihoodBuckets = []
                    return
                }

                guard currentLoadID == loadID else {
                    try? FileManager.default.removeItem(at: localURL)
                    return
                }

                currentTempVideoURL = localURL
                switchPlayerToLocalCopy(localURL)
                currentVideoAssetURL = localURL
                await loadWaveform(from: localURL)
                return
            }

            guard currentLoadID == loadID else { return }
            await loadWaveform(from: url)
        }
    }

    func seek(ms: Int) {
        guard let player else { return }
        let bounded = max(0, min(ms, durationMs > 0 ? durationMs : ms))
        let target = CMTime(value: CMTimeValue(bounded), timescale: 1000)

        seekSequence &+= 1
        let activeSeekSequence = seekSequence
        pendingSeekTargetMs = bounded
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard activeSeekSequence == self.seekSequence else { return }
                guard finished else {
                    self.pendingSeekTargetMs = nil
                    return
                }

                self.pendingSeekTargetMs = nil
                self.currentTimeMs = self.displayTimeMs(for: player, observedSeconds: player.currentTime().seconds)
            }
        }
        currentTimeMs = bounded
    }

    private func addPeriodicObserver(to player: AVPlayer) {
        // Higher update frequency keeps single-frame stepping in sync with UI overlays.
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        periodicObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let observedTimeMs = self.displayTimeMs(for: player, observedSeconds: time.seconds)

                if let pendingSeekTargetMs = self.pendingSeekTargetMs {
                    let isNearPendingTarget = abs(observedTimeMs - pendingSeekTargetMs) <= 33
                    if !isNearPendingTarget {
                        return
                    }
                    self.pendingSeekTargetMs = nil
                }

                self.currentTimeMs = observedTimeMs
            }
        }
    }

    private func addTimeControlStatusObserver(to player: AVPlayer) {
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = player.observe(\AVPlayer.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isPlayerActivelyPlaying(player) else { return }
                self.currentTimeMs = self.snappedFrameTimeMs(for: player.currentTime().seconds)
            }
        }
    }

    private func clearObserver() {
        if let periodicObserver, let player {
            player.removeTimeObserver(periodicObserver)
        }
        periodicObserver = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
    }

    private func isPlayerActivelyPlaying(_ player: AVPlayer) -> Bool {
        player.timeControlStatus == .playing && player.rate > 0
    }

    private func displayTimeMs(for player: AVPlayer, observedSeconds: Double) -> Int {
        if isPlayerActivelyPlaying(player) {
            return boundedTimeMs(Int((observedSeconds * 1000).rounded()))
        }
        return snappedFrameTimeMs(for: observedSeconds)
    }

    private func isRemoteURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return true }
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal {
            return !isLocal
        }
        return url.path.hasPrefix("/Volumes/")
    }

    private func localVideoURL(for url: URL) async -> URL? {
        guard isRemoteURL(url) else { return url }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntroStamp", isDirectory: true)
        let fileName = "\(UUID().uuidString)-\(url.lastPathComponent)"
        let destURL = tempDir.appendingPathComponent(fileName)

        remoteCopyTask?.cancel()
        let copyTaskID = UUID()
        remoteCopyTaskID = copyTaskID
        let copyTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try Self.copyFileCancellable(from: url, to: destURL, in: tempDir)
                return true
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destURL)
                return false
            } catch {
                try? FileManager.default.removeItem(at: destURL)
                return false
            }
        }
        remoteCopyTask = copyTask

        let copied = await copyTask.value
        guard remoteCopyTaskID == copyTaskID else {
            try? FileManager.default.removeItem(at: destURL)
            return nil
        }
        remoteCopyTask = nil
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: destURL)
            return nil
        }

        if copied {
            return destURL
        }
        return nil
    }

    private nonisolated static func copyFileCancellable(from sourceURL: URL, to destURL: URL, in tempDir: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        guard fileManager.createFile(atPath: destURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        let destinationHandle = try FileHandle(forWritingTo: destURL)
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        let chunkSize = 1_048_576
        while true {
            try Task.checkCancellation()
            let data = try sourceHandle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                break
            }
            try destinationHandle.write(contentsOf: data)
        }
    }

    private func switchPlayerToLocalCopy(_ localURL: URL) {
        guard let player else { return }
        let wasPlaying = player.rate > 0
        let targetTime = player.currentTime()

        let replacement = AVPlayerItem(url: localURL)
        player.replaceCurrentItem(with: replacement)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        Task { [weak self] in
            guard let self else { return }
            await loadFrameDuration(from: replacement.asset)
        }

        if wasPlaying {
            player.play()
        }
    }

    private func boundedTimeMs(_ ms: Int) -> Int {
        let bounded = max(0, ms)
        guard durationMs > 0 else { return bounded }
        return min(bounded, durationMs)
    }

    private func snappedFrameTimeMs(for seconds: Double) -> Int {
        guard seconds.isFinite, seconds >= 0 else { return 0 }

        guard frameDurationSeconds > 0 else {
            return boundedTimeMs(Int((seconds * 1000).rounded()))
        }

        let frameIndex = max(0, Int((seconds / frameDurationSeconds).rounded()))
        let snappedSeconds = Double(frameIndex) * frameDurationSeconds
        return boundedTimeMs(Int((snappedSeconds * 1000).rounded()))
    }

    private func deleteTempVideoFile() {
        guard let url = currentTempVideoURL else { return }
        try? FileManager.default.removeItem(at: url)
        currentTempVideoURL = nil
    }

    private func loadDuration(from asset: AVAsset) async {
        do {
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                durationMs = Int((seconds * 1000).rounded())
            }
        } catch {
            durationMs = 0
        }
    }

    private func loadFrameDuration(from asset: AVAsset) async {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                frameDurationSeconds = 0
                return
            }

            let minFrameDuration = try await videoTrack.load(.minFrameDuration)
            if minFrameDuration.isValid,
               minFrameDuration.seconds.isFinite,
               minFrameDuration.seconds > 0 {
                frameDurationSeconds = minFrameDuration.seconds
                return
            }

            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let fps = Double(nominalFrameRate)
            if fps.isFinite, fps > 0 {
                frameDurationSeconds = 1.0 / fps
                return
            }

            frameDurationSeconds = 0
        } catch {
            frameDurationSeconds = 0
        }
    }

    private func loadWaveform(from url: URL) async {
        defer { isLoadingWaveform = false }
        musicLikelihoodTask?.cancel()
        musicLikelihoodTask = nil
        let analysisID = UUID()
        currentWaveformAnalysisID = analysisID

        guard durationMs > 0 else {
            waveformBuckets = []
            musicLikelihoodBuckets = []
            return
        }

        do {
            let durationSnapshotMs = durationMs
            let capturedAnalysisID = analysisID
            let bucketCount = Self.bucketCount(for: durationSnapshotMs)

            if bucketCount > 0 {
                musicLikelihoodBuckets = Array(repeating: 0.0, count: bucketCount)
                musicLikelihoodTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    let rawLikelihood = await self.musicLikelihoodExtractor.extractMusicLikelihoodBuckets(
                        from: url,
                        bucketCount: bucketCount,
                        durationMs: durationSnapshotMs,
                        progressCallback: { @Sendable [weak self] partial in
                            Task { @MainActor [weak self] in
                                guard let self, self.currentWaveformAnalysisID == capturedAnalysisID else { return }
                                self.musicLikelihoodBuckets = self.smoothBuckets(partial, radius: 2)
                            }
                        }
                    )
                    guard !Task.isCancelled else { return }
                    let smoothed = self.smoothBuckets(rawLikelihood, radius: 2)
                    guard self.currentWaveformAnalysisID == capturedAnalysisID else { return }
                    self.musicLikelihoodBuckets = smoothed
                }
            }

            let buckets = try await waveformExtractor.extractWaveformBuckets(
                from: url,
                durationMs: durationSnapshotMs,
                progressCallback: { @Sendable [weak self] partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentWaveformAnalysisID == capturedAnalysisID else { return }
                        self.waveformBuckets = partial
                    }
                }
            )
            guard currentWaveformAnalysisID == analysisID else { return }

            waveformBuckets = buckets

            if !buckets.isEmpty, musicLikelihoodBuckets.count != buckets.count {
                musicLikelihoodBuckets = Array(repeating: 0.0, count: buckets.count)
            }
        } catch {
            waveformBuckets = []
            musicLikelihoodBuckets = []
        }
    }

    func reloadMusicLikelihood() async {
        guard let url = currentVideoAssetURL, !waveformBuckets.isEmpty else { return }
        musicLikelihoodTask?.cancel()
        let analysisID = UUID()
        currentWaveformAnalysisID = analysisID
        let capturedAnalysisID = analysisID
        let bucketCount = waveformBuckets.count
        let durationSnapshotMs = durationMs
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let rawLikelihood = await self.musicLikelihoodExtractor.extractMusicLikelihoodBuckets(
                from: url,
                bucketCount: bucketCount,
                durationMs: durationSnapshotMs,
                progressCallback: { @Sendable [weak self] partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentWaveformAnalysisID == capturedAnalysisID else { return }
                        self.musicLikelihoodBuckets = self.smoothBuckets(partial, radius: 2)
                    }
                }
            )
            guard !Task.isCancelled else { return }
            let smoothed = self.smoothBuckets(rawLikelihood, radius: 2)
            guard self.currentWaveformAnalysisID == analysisID else { return }
            self.musicLikelihoodBuckets = smoothed
        }
        musicLikelihoodTask = task
        await task.value
    }

    private func smoothBuckets(_ input: [Double], radius: Int) -> [Double] {
        guard !input.isEmpty, radius > 0 else { return input }

        var output = Array(repeating: 0.0, count: input.count)
        for index in input.indices {
            var weightedSum = 0.0
            var weightTotal = 0.0

            let start = max(0, index - radius)
            let end = min(input.count - 1, index + radius)

            for sampleIndex in start...end {
                let distance = abs(sampleIndex - index)
                let weight = Double(radius + 1 - distance)
                weightedSum += min(max(input[sampleIndex], 0), 1) * weight
                weightTotal += weight
            }

            output[index] = weightTotal > 0 ? min(max(weightedSum / weightTotal, 0), 1) : 0
        }

        return output
    }

    nonisolated static func bucketCount(for durationMs: Int) -> Int {
        guard durationMs > 0 else { return 0 }
        return max(120, min(2400, durationMs / 250))
    }
}

actor WaveformExtractor {
    private var musicLikelihoodCache: [String: [Double]] = [:]
    private var musicLikelihoodCacheOrder: [String] = []
    private let musicLikelihoodCacheLimit = 8

    func extractWaveformBuckets(
        from url: URL,
        durationMs: Int,
        progressCallback: (@Sendable ([Double]) -> Void)? = nil
    ) async throws -> [Double] {
        guard durationMs > 0 else {
            return []
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            return []
        }

        let bucketCount = PlayerTimelineEngine.bucketCount(for: durationMs)
        var buckets = Array(repeating: 0.0, count: bucketCount)

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            return []
        }
        reader.add(output)

        guard reader.startReading() else {
            return []
        }

        let durationSeconds = max(Double(durationMs) / 1000.0, 0.001)
        var lastEmittedBucketIndex = -1
        let progressEmitStep = max(1, bucketCount / 25)

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = max(0, timestamp.seconds)
            let ratio = min(max(seconds / durationSeconds, 0), 1)
            let index = min(bucketCount - 1, max(0, Int((ratio * Double(bucketCount)).rounded(.down))))

            let peak = peakAmplitude(from: sampleBuffer)
            if peak > buckets[index] {
                buckets[index] = peak
            }

            if let cb = progressCallback, index - lastEmittedBucketIndex >= progressEmitStep {
                lastEmittedBucketIndex = index
                let currentMax = max(buckets[0...index].max() ?? 0, 0.001)
                var partial = Array(repeating: 0.0, count: bucketCount)
                for i in 0...index {
                    partial[i] = min(max(buckets[i] / currentMax, 0), 1)
                }
                cb(partial)
            }
        }

        let maxValue = buckets.max() ?? 0
        guard maxValue > 0 else {
            return []
        }

        return buckets.map { min(max($0 / maxValue, 0), 1) }
    }

    func extractMusicLikelihoodBuckets(
        from url: URL,
        bucketCount: Int,
        durationMs: Int,
        progressCallback: (@Sendable ([Double]) -> Void)? = nil
    ) async -> [Double] {
        let durationSeconds = max(Double(durationMs) / 1000.0, 0.001)
        guard bucketCount > 0, durationSeconds > 0 else { return [] }

        let cacheKey = makeMusicCacheKey(url: url, bucketCount: bucketCount, durationMs: durationMs)
        if let cached = musicLikelihoodCache[cacheKey], cached.count == bucketCount {
            return cached
        }

        let windowSeconds: Double = 2.0
        let overlapFactor: Double = 0.0

        do {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 600)
            request.overlapFactor = overlapFactor

            let observer = AudioLikelihoodObserver(
                bucketCount: bucketCount,
                durationSeconds: durationSeconds,
                progressCallback: progressCallback
            )
            try analyzer.add(request, withObserver: observer)
            await analyzer.analyze()
            let resolved = observer.resolvedMusicBuckets()
            storeMusicCache(value: resolved, for: cacheKey)
            return resolved
        } catch {
            return Array(repeating: 0.0, count: bucketCount)
        }
    }

    private func makeMusicCacheKey(url: URL, bucketCount: Int, durationMs: Int) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = values?.fileSize ?? -1
        let modTime = Int((values?.contentModificationDate?.timeIntervalSince1970 ?? 0).rounded())
        return "\(url.path)|\(fileSize)|\(modTime)|\(durationMs)|\(bucketCount)|fast"
    }

    private func storeMusicCache(value: [Double], for key: String) {
        musicLikelihoodCache[key] = value

        if let existingIndex = musicLikelihoodCacheOrder.firstIndex(of: key) {
            musicLikelihoodCacheOrder.remove(at: existingIndex)
        }
        musicLikelihoodCacheOrder.append(key)

        while musicLikelihoodCacheOrder.count > musicLikelihoodCacheLimit {
            let oldest = musicLikelihoodCacheOrder.removeFirst()
            musicLikelihoodCache.removeValue(forKey: oldest)
        }
    }

    private func peakAmplitude(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0
        }

        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength >= MemoryLayout<Int16>.stride else { return 0 }

        var maxSample: Float = 0
        var offset = 0

        while offset < totalLength {
            var lengthAtOffset = 0
            var chunkTotalLength = 0
            var chunkPointer: UnsafeMutablePointer<Int8>?

            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: offset,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &chunkTotalLength,
                dataPointerOut: &chunkPointer
            )

            guard status == kCMBlockBufferNoErr,
                  let chunkPointer,
                  lengthAtOffset > 0
            else {
                break
            }

            let sampleCount = lengthAtOffset / MemoryLayout<Int16>.stride
            if sampleCount > 0 {
                chunkPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                    // Convert Int16 samples to Float via vDSP (vectorized, SIMD-accelerated)
                    var floatBuffer = [Float](repeating: 0, count: sampleCount)
                    vDSP_vflt16(samples, 1, &floatBuffer, 1, vDSP_Length(sampleCount))
                    // Find max magnitude without a scalar loop
                    var chunkMax: Float = 0
                    vDSP_maxmgv(floatBuffer, 1, &chunkMax, vDSP_Length(sampleCount))
                    if chunkMax > maxSample { maxSample = chunkMax }
                }
            }

            offset += lengthAtOffset
        }

        return Double(maxSample) / Double(Int16.max)
    }
}

private final class AudioLikelihoodObserver: NSObject, SNResultsObserving {
    private let bucketCount: Int
    private let durationSeconds: Double
    private var musicSums: [Double]
    private var speechSums: [Double]
    private var counts: [Int]

    private let progressCallback: (@Sendable ([Double]) -> Void)?
    private var resultCount = 0

    init(bucketCount: Int, durationSeconds: Double, progressCallback: (@Sendable ([Double]) -> Void)? = nil) {
        self.bucketCount = bucketCount
        self.durationSeconds = max(durationSeconds, 0.001)
        self.musicSums = Array(repeating: 0.0, count: bucketCount)
        self.speechSums = Array(repeating: 0.0, count: bucketCount)
        self.counts = Array(repeating: 0, count: bucketCount)
        self.progressCallback = progressCallback
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }
        let musicConfidence = highestConfidence(
            in: classificationResult,
            matchingAnyOf: ["music", "singing", "choir", "yodeling", "rapping", "humming", "whistling"],
            excluding: ["speech", "spoken", "voice"]
        )
        let speechConfidence = highestConfidence(
            in: classificationResult,
            matchingAnyOf: ["speech", "spoken", "dialog", "dialogue", "voice", "narration", "conversation"],
            excluding: ["sing", "choir", "yodel", "rapping", "humming", "whistling", "music"]
        )

        guard musicConfidence > 0 || speechConfidence > 0 else { return }

        let start = max(0, classificationResult.timeRange.start.seconds)
        let end = max(start, classificationResult.timeRange.end.seconds)
        let startRatio = min(max(start / durationSeconds, 0), 1)
        let endRatio = min(max(end / durationSeconds, 0), 1)

        let startIndex = min(bucketCount - 1, max(0, Int((startRatio * Double(bucketCount)).rounded(.down))))
        let endIndex = min(bucketCount - 1, max(startIndex, Int((endRatio * Double(bucketCount)).rounded(.down))))

        for index in startIndex...endIndex {
            musicSums[index] += Double(musicConfidence)
            speechSums[index] += Double(speechConfidence)
            counts[index] += 1
        }

        resultCount += 1
        if resultCount % 15 == 0, let cb = progressCallback {
            cb(resolvedMusicBuckets())
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        // Keep observer resilient: unresolved buckets default to zero likelihood.
    }

    func requestDidComplete(_ request: SNRequest) {
        progressCallback?(resolvedMusicBuckets())
    }

    func resolvedMusicBuckets() -> [Double] {
        let speechSuppressionFactor = 0.75
        return (0..<bucketCount).map { index in
            let count = counts[index]
            guard count > 0 else { return 0 }

            let music = min(max(musicSums[index] / Double(count), 0), 1)
            let speech = min(max(speechSums[index] / Double(count), 0), 1)
            let effectiveMusic = max(0, music - (speech * speechSuppressionFactor))
            return min(max(effectiveMusic, 0), 1)
        }
    }

    private func highestConfidence(
        in result: SNClassificationResult,
        matchingAnyOf keywords: [String],
        excluding excludedKeywords: [String]
    ) -> Double {
        var best: Double = 0
        for classification in result.classifications {
            let identifier = classification.identifier.lowercased()
            let matchesKeyword = keywords.contains { identifier.contains($0) }
            guard matchesKeyword else { continue }

            let isExcluded = excludedKeywords.contains { identifier.contains($0) }
            guard !isExcluded else { continue }

            if classification.confidence > best {
                best = classification.confidence
            }
        }
        return best
    }
}
