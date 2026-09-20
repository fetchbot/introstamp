import Foundation

struct SubtitleEntry: Sendable {
    var startMs: Int
    var endMs: Int
    var text: String
}

enum SRTParser {
    /// Parses an SRT string and returns an array of subtitle entries sorted by start time.
    static func parse(_ content: String) -> [SubtitleEntry] {
        // Normalise line endings so we can split uniformly.
        let normalised = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // SRT blocks are separated by one or more blank lines.
        let blocks = normalised.components(separatedBy: "\n\n")

        var entries: [SubtitleEntry] = []
        entries.reserveCapacity(blocks.count)

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard lines.count >= 2 else { continue }

            // The first non-empty line is the sequence number — skip it.
            // Find the timestamp line (contains " --> ").
            guard let timestampLineIndex = lines.firstIndex(where: { $0.contains(" --> ") }) else { continue }
            let timestampLine = lines[timestampLineIndex]

            guard let (startMs, endMs) = parseTimestampLine(timestampLine) else { continue }

            // Everything after the timestamp line is the subtitle text.
            let textLines = lines[(timestampLineIndex + 1)...]
                .filter { !isSSATag($0) }
            let text = textLines.joined(separator: " ").strippingHTMLTags()

            guard !text.isEmpty else { continue }
            entries.append(SubtitleEntry(startMs: startMs, endMs: endMs, text: text))
        }

        return entries.sorted { $0.startMs < $1.startMs }
    }

    // MARK: - Timestamp parsing

    /// Parses "HH:MM:SS,mmm --> HH:MM:SS,mmm" (both comma and period decimal separators accepted).
    private static func parseTimestampLine(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: " --> ")
        guard parts.count == 2 else { return nil }
        guard
            let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
            let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (start, end)
    }

    /// Converts "HH:MM:SS,mmm" or "HH:MM:SS.mmm" to milliseconds.
    private static func parseTimestamp(_ ts: String) -> Int? {
        // Normalise decimal separator.
        let normalised = ts.replacingOccurrences(of: ",", with: ".")
        let parts = normalised.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        guard
            let hours = Int(parts[0]),
            let minutes = Int(parts[1])
        else { return nil }

        let secParts = parts[2].components(separatedBy: ".")
        guard let seconds = Int(secParts[0]) else { return nil }
        var millis = 0
        if secParts.count > 1 {
            // Pad or truncate to exactly 3 digits.
            var msStr = secParts[1]
            if msStr.count < 3 { msStr = msStr.padding(toLength: 3, withPad: "0", startingAt: 0) }
            if msStr.count > 3 { msStr = String(msStr.prefix(3)) }
            millis = Int(msStr) ?? 0
        }

        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + millis
    }

    // MARK: - Formatting tags

    private static func isSSATag(_ line: String) -> Bool {
        line.hasPrefix("{") && line.hasSuffix("}")
    }
}

private extension String {
    /// Removes common HTML-style tags used in SRT files (e.g. <i>, <b>, <font …>).
    func strippingHTMLTags() -> String {
        var result = self
        // Simple greedy pass — good enough for SRT tag stripping.
        while let range = result.range(of: #"<[^>]+>"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
