import AVFoundation
import CoreVideo

final class SceneDetector: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (_ partialScenes: [SceneChange], _ progress: Double) -> Void

    struct Config {
        enum Preset: String, CaseIterable {
            case standard = "standard"
            case anime = "anime"
            case liveAction = "liveaction"
            case darkLiveAction = "dark-liveaction"
            case sports = "sports"
        }

        var preset: Preset = .standard
        var threshold: Double = 0.10
        var spikeFactor: Double = 2.8
        var minGap: Double = 0.10
        var maxAnalysisFPS: Double = 15.0
        var gridWidth: Int = 32
        var gridHeight: Int = 18

        static func inferredPreset(from genres: [String], mediaType: MediaType) -> Preset {
            let normalizedGenres = Set(genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

            if normalizedGenres.contains("animation") || normalizedGenres.contains("anime") {
                return .anime
            }

            if normalizedGenres.contains("sports") || normalizedGenres.contains("sport") {
                return .sports
            }

            if normalizedGenres.contains("horror")
                || normalizedGenres.contains("thriller")
                || normalizedGenres.contains("mystery")
                || normalizedGenres.contains("crime")
                || normalizedGenres.contains("war")
            {
                return .darkLiveAction
            }

            if normalizedGenres.contains("action")
                || normalizedGenres.contains("adventure")
                || normalizedGenres.contains("drama")
                || normalizedGenres.contains("science fiction")
                || normalizedGenres.contains("sci-fi")
                || normalizedGenres.contains("fantasy")
            {
                return .liveAction
            }

            if mediaType == .tv && normalizedGenres.contains("documentary") {
                return .darkLiveAction
            }

            return .standard
        }

        mutating func applyPreset(_ preset: Preset) {
            self.preset = preset

            switch preset {
            case .standard:
                threshold = 0.10
                spikeFactor = 2.8
                minGap = 0.10
                maxAnalysisFPS = 15.0
                gridWidth = 28
                gridHeight = 16
            case .anime:
                threshold = 0.085
                spikeFactor = 2.4
                minGap = 0.08
                maxAnalysisFPS = 18.0
                gridWidth = 36
                gridHeight = 20
            case .liveAction:
                threshold = 0.115
                spikeFactor = 3.1
                minGap = 0.12
                maxAnalysisFPS = 15.0
                gridWidth = 32
                gridHeight = 18
            case .darkLiveAction:
                threshold = 0.090
                spikeFactor = 2.6
                minGap = 0.12
                maxAnalysisFPS = 15.0
                gridWidth = 40
                gridHeight = 22
            case .sports:
                threshold = 0.140
                spikeFactor = 3.8
                minGap = 0.10
                maxAnalysisFPS = 20.0
                gridWidth = 28
                gridHeight = 16
            }
        }
    }

    func detectScenes(
        asset: AVAsset,
        config: Config = Config(),
        onProgress: ProgressHandler? = nil
    ) async throws -> [SceneChange] {
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "SceneDetection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid duration"])
        }

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw NSError(domain: "SceneDetection", code: -2, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        let nominalFPS = (try? await track.load(.nominalFrameRate)) ?? 0
        let minFrameDuration = (try? await track.load(.minFrameDuration)) ?? .invalid
        let effectiveFPS: Double = {
            if nominalFPS > 0 { return Double(nominalFPS) }
            let seconds = CMTimeGetSeconds(minFrameDuration)
            if seconds.isFinite, seconds > 0 { return 1.0 / seconds }
            return 25.0
        }()

        let minGapFrames = max(1, Int((config.minGap * effectiveFPS).rounded(.up)))
        let gradualMinFrames = max(4, Int((0.18 * effectiveFPS).rounded(.up)))
        let gradualMinDiff = max(0.018, config.threshold * 0.35)
        let analysisStride = max(1, Int((effectiveFPS / max(1.0, config.maxAnalysisFPS)).rounded(.down)))
        let gradualMinAnalyzedFrames = max(3, Int((Double(gradualMinFrames) / Double(analysisStride)).rounded(.up)))

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NSError(domain: "SceneDetection", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot create reader"])
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw NSError(domain: "SceneDetection", code: -4, userInfo: [NSLocalizedDescriptionKey: "Cannot add track output"])
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw NSError(domain: "SceneDetection", code: -5, userInfo: [NSLocalizedDescriptionKey: "Cannot start reader"])
        }

        let descriptorSize = config.gridWidth * config.gridHeight
        var prevDescriptor = [UInt8](repeating: 0, count: descriptorSize)
        var currDescriptor = [UInt8](repeating: 0, count: descriptorSize)
        var hasPrev = false

        var changes: [SceneChange] = []
        var lastCutFrameIndex: Int?
        let rollingWindowSize = 12
        var rollingScores = [Double](repeating: 0.0, count: rollingWindowSize)
        var rollingScoreCount = 0
        var rollingScoreWriteIndex = 0
        var rollingScoreSum = 0.0

        struct GradualCandidate {
            var startFrame: Int
            var startTime: CMTime
            var startMean: Double
            var lastTime: CMTime
            var lastMean: Double
            var frames: Int
            var sumAbsDelta: Double
            var peakDiff: Double
        }

        var gradual: GradualCandidate?
        var decodedFrames = 0
        var prevMeanLuma = 0.0
        var hasPrevMean = false
        var lastReportedProgressStep = -1
        var lastReportedSceneCount = -1

        func reportProgress(at seconds: Double, force: Bool = false) {
            guard let onProgress else { return }
            let normalized = duration > 0 ? max(0.0, min(1.0, seconds / duration)) : 0.0
            let step = Int((normalized * 100.0).rounded(.down)) / 2
            let sceneCountChanged = changes.count != lastReportedSceneCount
            let progressChanged = step != lastReportedProgressStep
            guard force || sceneCountChanged || progressChanged else { return }

            lastReportedProgressStep = step
            lastReportedSceneCount = changes.count
            onProgress(changes, normalized)
        }

        func finalizeGradual(currentFrame: Int) {
            guard let g = gradual else { return }
            defer { gradual = nil }

            if g.frames < gradualMinAnalyzedFrames { return }
            if let last = lastCutFrameIndex, g.startFrame - last < minGapFrames { return }
            if let last = lastCutFrameIndex, currentFrame - last < minGapFrames { return }

            let totalDelta = g.lastMean - g.startMean
            let monotonicRatio = g.sumAbsDelta > 0 ? abs(totalDelta) / g.sumAbsDelta : 0
            let durationFrames = max(1, g.frames * analysisStride)
            let avgDeltaPerFrame = abs(totalDelta) / Double(durationFrames)

            let isFade = monotonicRatio >= 0.72 && abs(totalDelta) >= 0.05 && avgDeltaPerFrame >= 0.002
            let type: SceneChange.TransitionType
            if isFade {
                type = totalDelta > 0 ? .fadeIn : .fadeOut
            } else {
                type = .dissolve
            }

            let midSeconds = (CMTimeGetSeconds(g.startTime) + CMTimeGetSeconds(g.lastTime)) * 0.5
            let midTime = CMTime(seconds: midSeconds, preferredTimescale: 600)
            let timestampMs = Int(CMTimeGetSeconds(midTime) * 1000)
            let endTimestampMs = Int(CMTimeGetSeconds(g.lastTime) * 1000)
            let item = SceneChange(
                index: changes.count + 1,
                timestampMs: timestampMs,
                endTimestampMs: endTimestampMs,
                score: g.peakDiff,
                type: type
            )
            changes.append(item)
            lastCutFrameIndex = g.startFrame
            reportProgress(at: CMTimeGetSeconds(g.lastTime), force: true)
        }

        reportProgress(at: 0, force: true)

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }

            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            decodedFrames += 1

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let t = CMTimeGetSeconds(pts)
            if !t.isFinite { continue }

            let shouldAnalyzeFrame = decodedFrames == 1 || (decodedFrames % analysisStride == 0)
            if !shouldAnalyzeFrame {
                reportProgress(at: t)
                continue
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            var descriptorSum = 0
            var descriptorDiffSum = 0
            fillLumaDescriptorAndStats(
                pixelBuffer: pixelBuffer,
                gridWidth: config.gridWidth,
                gridHeight: config.gridHeight,
                output: &currDescriptor,
                previousDescriptor: hasPrev ? prevDescriptor : nil,
                lumaSum: &descriptorSum,
                diffSum: &descriptorDiffSum
            )

            let currMeanLuma = Double(descriptorSum) / (Double(currDescriptor.count) * 255.0)

            if hasPrev {
                let score = Double(descriptorDiffSum) / (Double(currDescriptor.count) * 255.0)
                let motionBaseline = rollingScoreCount == 0
                    ? 0.0
                    : rollingScoreSum / Double(rollingScoreCount)
                let adaptiveThreshold = max(config.threshold, motionBaseline * config.spikeFactor)
                let gapOK = lastCutFrameIndex.map { decodedFrames - $0 >= minGapFrames } ?? true
                let isGradualFrame = score >= gradualMinDiff && score < adaptiveThreshold * 0.9

                if score >= adaptiveThreshold && gapOK {
                    finalizeGradual(currentFrame: decodedFrames)

                    let timestampMs = Int(CMTimeGetSeconds(pts) * 1000)
                    let item = SceneChange(
                        index: changes.count + 1,
                        timestampMs: timestampMs,
                        endTimestampMs: nil,
                        score: score,
                        type: .hardCut
                    )
                    changes.append(item)
                    lastCutFrameIndex = decodedFrames
                    rollingScoreCount = 0
                    rollingScoreWriteIndex = 0
                    rollingScoreSum = 0
                    reportProgress(at: t, force: true)

                    gradual = nil
                } else {
                    if rollingScoreCount < rollingWindowSize {
                        rollingScores[rollingScoreWriteIndex] = score
                        rollingScoreSum += score
                        rollingScoreCount += 1
                    } else {
                        let evicted = rollingScores[rollingScoreWriteIndex]
                        rollingScores[rollingScoreWriteIndex] = score
                        rollingScoreSum += score - evicted
                    }
                    rollingScoreWriteIndex = (rollingScoreWriteIndex + 1) % rollingWindowSize

                    if isGradualFrame, hasPrevMean {
                        if gradual == nil {
                            gradual = GradualCandidate(
                                startFrame: max(1, decodedFrames - analysisStride),
                                startTime: pts,
                                startMean: prevMeanLuma,
                                lastTime: pts,
                                lastMean: currMeanLuma,
                                frames: 1,
                                sumAbsDelta: abs(currMeanLuma - prevMeanLuma),
                                peakDiff: score
                            )
                        } else {
                            gradual!.frames += 1
                            gradual!.lastTime = pts
                            gradual!.sumAbsDelta += abs(currMeanLuma - gradual!.lastMean)
                            gradual!.lastMean = currMeanLuma
                            gradual!.peakDiff = max(gradual!.peakDiff, score)
                        }
                    } else {
                        finalizeGradual(currentFrame: decodedFrames)
                    }
                }
            } else {
                hasPrev = true
            }

            swap(&prevDescriptor, &currDescriptor)
            prevMeanLuma = currMeanLuma
            hasPrevMean = true
            reportProgress(at: t)
        }

        finalizeGradual(currentFrame: decodedFrames)
        reportProgress(at: duration, force: true)

        if analysisStride > 1, !changes.isEmpty {
            changes = refineHardCutTimestamps(
                asset: asset,
                track: track,
                changes: changes,
                config: config,
                effectiveFPS: effectiveFPS,
                durationSeconds: duration,
                analysisStride: analysisStride
            )
        }

        return changes
    }

    private func refineHardCutTimestamps(
        asset: AVAsset,
        track: AVAssetTrack,
        changes: [SceneChange],
        config: Config,
        effectiveFPS: Double,
        durationSeconds: Double,
        analysisStride: Int
    ) -> [SceneChange] {
        guard effectiveFPS.isFinite, effectiveFPS > 0 else { return changes }

        let frameDuration = 1.0 / effectiveFPS
        let refinementRadiusFrames = max(1, analysisStride)
        var refined = changes

        for idx in refined.indices {
            if Task.isCancelled { break }
            let item = refined[idx]
            guard item.type == .hardCut else { continue }

            guard let candidate = refineHardCutCandidate(
                asset: asset,
                track: track,
                aroundTimestampMs: item.timestampMs,
                config: config,
                frameDuration: frameDuration,
                durationSeconds: durationSeconds,
                radiusFrames: refinementRadiusFrames
            ) else {
                continue
            }

            refined[idx] = SceneChange(
                index: item.index,
                timestampMs: candidate.timestampMs,
                endTimestampMs: nil,
                score: max(item.score, candidate.score),
                type: .hardCut
            )
        }

        return refined
    }

    private func refineHardCutCandidate(
        asset: AVAsset,
        track: AVAssetTrack,
        aroundTimestampMs: Int,
        config: Config,
        frameDuration: Double,
        durationSeconds: Double,
        radiusFrames: Int
    ) -> (timestampMs: Int, score: Double)? {
        guard let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }

        let centerSeconds = max(0, min(durationSeconds, Double(aroundTimestampMs) / 1000.0))
        let radiusSeconds = frameDuration * Double(radiusFrames)
        let startSeconds = max(0, centerSeconds - radiusSeconds)
        let endSeconds = min(durationSeconds, centerSeconds + radiusSeconds)
        let rangeDurationSeconds = endSeconds - startSeconds
        guard rangeDurationSeconds > 0 else { return nil }

        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: rangeDurationSeconds, preferredTimescale: 600)
        )

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { return nil }
        reader.add(trackOutput)
        guard reader.startReading() else { return nil }

        let descriptorSize = config.gridWidth * config.gridHeight
        var prevDescriptor = [UInt8](repeating: 0, count: descriptorSize)
        var currDescriptor = [UInt8](repeating: 0, count: descriptorSize)
        var hasPrev = false

        var bestScore = -1.0
        var bestTimestampMs = aroundTimestampMs
        var bestDistance = Double.greatestFiniteMagnitude

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                break
            }

            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let t = CMTimeGetSeconds(pts)
            if !t.isFinite { continue }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            var lumaSum = 0
            var diffSum = 0
            fillLumaDescriptorAndStats(
                pixelBuffer: pixelBuffer,
                gridWidth: config.gridWidth,
                gridHeight: config.gridHeight,
                output: &currDescriptor,
                previousDescriptor: hasPrev ? prevDescriptor : nil,
                lumaSum: &lumaSum,
                diffSum: &diffSum
            )

            if hasPrev {
                let score = Double(diffSum) / (Double(currDescriptor.count) * 255.0)
                let distance = abs(t - centerSeconds)
                if score > bestScore || (abs(score - bestScore) < 0.000_001 && distance < bestDistance) {
                    bestScore = score
                    bestDistance = distance
                    bestTimestampMs = Int((t * 1000.0).rounded())
                }
            } else {
                hasPrev = true
            }

            swap(&prevDescriptor, &currDescriptor)
        }

        guard bestScore >= 0 else { return nil }
        return (timestampMs: max(0, bestTimestampMs), score: bestScore)
    }

    private func fillLumaDescriptorAndStats(
        pixelBuffer: CVPixelBuffer,
        gridWidth: Int,
        gridHeight: Int,
        output: inout [UInt8],
        previousDescriptor: [UInt8]?,
        lumaSum: inout Int,
        diffSum: inout Int
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let plane = 0
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)

        guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            output.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                base.initialize(repeating: 0, count: buffer.count)
            }
            lumaSum = 0
            diffSum = 0
            return
        }

        let base = baseAddr.assumingMemoryBound(to: UInt8.self)
        let cellW = max(1, width / gridWidth)
        let cellH = max(1, height / gridHeight)

        lumaSum = 0
        diffSum = 0

        var idx = 0
        for gy in 0..<gridHeight {
            let y = min(height - 1, gy * cellH + cellH / 2)
            let row = base.advanced(by: y * rowBytes)
            for gx in 0..<gridWidth {
                let x = min(width - 1, gx * cellW + cellW / 2)
                let sample = row[x]
                output[idx] = sample
                lumaSum += Int(sample)
                if let previousDescriptor {
                    diffSum += abs(Int(sample) - Int(previousDescriptor[idx]))
                }
                idx += 1
            }
        }
    }
}
