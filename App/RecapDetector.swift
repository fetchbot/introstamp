import Foundation

enum RecapDetector {
    // MARK: - Configuration

    /// Width of each analysis window in milliseconds.
    private static let windowMs = 20_000
    /// How far each window advances before the next one starts.
    private static let strideMs = 5_000
    /// Minimum Jaccard similarity (0–1) for a window pair to count as a match.
    private static let similarityThreshold = 0.30
    /// Gaps between matched windows no larger than this are merged.
    private static let mergeGapMs = 10_000
    /// Minimum number of tokens a window must contain to be compared.
    private static let minTokenCount = 4

    // MARK: - Public API

    /// Compares subtitle entries from the current episode against those from the previous
    /// episode and returns time ranges (in the current episode's timeline) that are likely
    /// recap content — i.e. windows whose text closely resembles text from the previous episode.
    static func detect(
        current: [SubtitleEntry],
        previous: [SubtitleEntry]
    ) -> [(startMs: Int, endMs: Int)] {
        guard !current.isEmpty, !previous.isEmpty else { return [] }

        let currentDuration = (current.last?.endMs ?? 0) + windowMs
        let prevDuration = (previous.last?.endMs ?? 0) + windowMs

        let currentWindows = buildWindows(entries: current, durationMs: currentDuration)
        let prevWindows = buildWindows(entries: previous, durationMs: prevDuration)

        guard !currentWindows.isEmpty, !prevWindows.isEmpty else { return [] }

        // For each previous-episode window, pre-compute its token set once.
        let prevTokenSets: [Set<String>] = prevWindows.map { $0.tokens }

        var matchedRanges: [(startMs: Int, endMs: Int)] = []

        for window in currentWindows {
            guard window.tokens.count >= minTokenCount else { continue }
            let maxSimilarity = prevTokenSets.map { jaccard(window.tokens, $0) }.max() ?? 0
            if maxSimilarity >= similarityThreshold {
                matchedRanges.append((window.startMs, window.endMs))
            }
        }

        return mergeRanges(matchedRanges, gapMs: mergeGapMs)
    }

    /// Maps a list of time ranges to a per-bucket signal array aligned to the waveform.
    /// Each bucket with a value of 1.0 falls inside at least one recap range.
    static func toBuckets(
        ranges: [(startMs: Int, endMs: Int)],
        durationMs: Int,
        bucketCount: Int
    ) -> [Double] {
        guard bucketCount > 0, durationMs > 0 else { return [] }
        var buckets = [Double](repeating: 0.0, count: bucketCount)
        guard !ranges.isEmpty else { return buckets }

        let msPerBucket = Double(durationMs) / Double(bucketCount)

        for i in 0..<bucketCount {
            let bucketStartMs = Int(Double(i) * msPerBucket)
            let bucketEndMs = Int(Double(i + 1) * msPerBucket)
            for range in ranges {
                // Mark the bucket if the recap range overlaps it at all.
                if range.startMs < bucketEndMs && range.endMs > bucketStartMs {
                    buckets[i] = 1.0
                    break
                }
            }
        }

        return buckets
    }

    /// Tightens coarse detected ranges to the exact subtitle entry timestamps of lines
    /// whose vocabulary significantly overlaps the previous episode.
    /// Uses word-level matching (rather than exact text) to handle cases where the same
    /// dialogue was split across multiple SRT entries in one episode but merged into a
    /// single entry in the other.
    static func tighten(
        ranges: [(startMs: Int, endMs: Int)],
        current: [SubtitleEntry],
        previous: [SubtitleEntry]
    ) -> [(startMs: Int, endMs: Int)] {
        guard !ranges.isEmpty else { return [] }

        let previousNormalizedLines: Set<String> = Set(
            previous
                .map { normalizeText($0.text) }
                .filter { !$0.isEmpty }
        )
        let previousTrigrams: Set<String> = Set(
            previous.flatMap { entry in
                trigrams(from: normalizeText(entry.text))
            }
        )
        guard !previousNormalizedLines.isEmpty else { return ranges }

        var tightened: [(startMs: Int, endMs: Int)] = []

        for range in ranges {
            let matching = current.filter { entry in
                guard entry.endMs > range.startMs, entry.startMs < range.endMs else { return false }

                let normalized = normalizeText(entry.text)
                guard !normalized.isEmpty else { return false }

                // Exact line matches are the strongest signal.
                if previousNormalizedLines.contains(normalized) {
                    return true
                }

                // For split/merged subtitle lines across episodes, require trigram overlap.
                // This is much stricter than global word overlap and avoids over-extending
                // recap ranges into generic dialogue.
                let currentTrigrams = trigrams(from: normalized)
                guard currentTrigrams.count >= 2, !previousTrigrams.isEmpty else { return false }
                let overlapCount = currentTrigrams.filter { previousTrigrams.contains($0) }.count
                return Double(overlapCount) / Double(currentTrigrams.count) >= 0.5
            }
            if let minStart = matching.map(\.startMs).min(),
               let maxEnd = matching.map(\.endMs).max(),
               maxEnd > minStart {
                tightened.append((minStart, maxEnd))
            }
            // No matching lines found → drop this window entirely.
        }

        return mergeRanges(tightened, gapMs: 0)
    }


    private struct Window {
        var startMs: Int
        var endMs: Int
        var tokens: Set<String>
    }

    private static func buildWindows(entries: [SubtitleEntry], durationMs: Int) -> [Window] {
        var windows: [Window] = []
        var windowStart = 0

        while windowStart < durationMs {
            let windowEnd = windowStart + windowMs
            let text = entries
                .filter { $0.endMs > windowStart && $0.startMs < windowEnd }
                .map(\.text)
                .joined(separator: " ")
            let tokens = tokenise(text)
            windows.append(Window(startMs: windowStart, endMs: windowEnd, tokens: tokens))
            windowStart += strideMs
        }

        return windows
    }

    // MARK: - Tokenisation

    /// Lowercases, strips punctuation and splits on whitespace.
    /// Common filler tokens (e.g. "i", "a", "the") are kept intentionally — removing
    /// them would reduce discriminative power for short recap lines.
    private static func tokenise(_ text: String) -> Set<String> {
        let words = normalizeText(text).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        return Set(words)
    }

    /// Lowercases and strips anything that is not a letter, digit or whitespace.
    static func normalizeText(_ text: String) -> String {
        let lowercased = text.lowercased()
        let stripped = lowercased.unicodeScalars.filter { scalar in
            CharacterSet.letters.union(.decimalDigits).union(.whitespaces).contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func trigrams(from normalized: String) -> [String] {
        let words = normalized
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }
        guard words.count >= 3 else { return [] }

        var grams: [String] = []
        grams.reserveCapacity(words.count - 2)
        for i in 0..<(words.count - 2) {
            grams.append("\(words[i]) \(words[i + 1]) \(words[i + 2])")
        }
        return grams
    }

    // MARK: - Jaccard similarity

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    // MARK: - Range merging

    private static func mergeRanges(
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
}
