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
    private var currentTempVideoURL: URL?
    private var currentLoadID = UUID()
    private var currentWaveformAnalysisID = UUID()

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

        addPeriodicObserver(to: player)

        Task {
            await loadDuration(from: item.asset)

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
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTimeMs = bounded
    }

    private func addPeriodicObserver(to player: AVPlayer) {
        // Higher update frequency keeps single-frame stepping in sync with UI overlays.
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        periodicObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTimeMs = max(0, Int((time.seconds * 1000).rounded()))
            }
        }
    }

    private func clearObserver() {
        if let periodicObserver, let player {
            player.removeTimeObserver(periodicObserver)
        }
        periodicObserver = nil
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

        let copied = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: tempDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: destURL)
                return true
            } catch {
                return false
            }
        }.value

        if copied {
            return destURL
        }
        return nil
    }

    private func switchPlayerToLocalCopy(_ localURL: URL) {
        guard let player else { return }
        let wasPlaying = player.rate > 0
        let targetTime = player.currentTime()

        let replacement = AVPlayerItem(url: localURL)
        player.replaceCurrentItem(with: replacement)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)

        if wasPlaying {
            player.play()
        }
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

    private func loadWaveform(from url: URL) async {
        defer { isLoadingWaveform = false }
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
            musicLikelihoodBuckets = Array(repeating: 0.0, count: buckets.count)

            guard !buckets.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let rawLikelihood = await self.waveformExtractor.extractMusicLikelihoodBuckets(
                    from: url,
                    bucketCount: buckets.count,
                    durationMs: durationSnapshotMs,
                    progressCallback: { @Sendable [weak self] partial in
                        Task { @MainActor [weak self] in
                            guard let self, self.currentWaveformAnalysisID == capturedAnalysisID else { return }
                            self.musicLikelihoodBuckets = self.smoothBuckets(partial, radius: 2)
                        }
                    }
                )
                let smoothed = self.smoothBuckets(rawLikelihood, radius: 2)
                guard self.currentWaveformAnalysisID == capturedAnalysisID else { return }
                self.musicLikelihoodBuckets = smoothed
            }
        } catch {
            waveformBuckets = []
            musicLikelihoodBuckets = []
        }
    }

    func reloadMusicLikelihood() async {
        guard let url = currentVideoAssetURL, !waveformBuckets.isEmpty else { return }
        let analysisID = UUID()
        currentWaveformAnalysisID = analysisID
        let capturedAnalysisID = analysisID
        let bucketCount = waveformBuckets.count
        let durationSnapshotMs = durationMs
        let rawLikelihood = await waveformExtractor.extractMusicLikelihoodBuckets(
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
        let smoothed = smoothBuckets(rawLikelihood, radius: 2)
        guard currentWaveformAnalysisID == analysisID else { return }
        musicLikelihoodBuckets = smoothed
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

        let bucketCount = max(120, min(2400, durationMs / 250))
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
            matchingAnyOf: ["music"],
            excluding: ["speech", "spoken", "voice", "vocal", "sing"]
        )
        let speechConfidence = highestConfidence(
            in: classificationResult,
            matchingAnyOf: ["speech", "spoken", "dialog", "dialogue", "voice", "narration", "conversation"],
            excluding: ["sing", "singer", "vocal music"]
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
