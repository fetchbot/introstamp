import Foundation

enum ASSParser {
    /// Parses an ASS subtitle string and returns entries sorted by start time.
    /// Handles common dialogue lines like:
    /// Dialogue: 0,0:00:02.04,0:00:05.25,Default,,0,0,0,,Text
    static func parse(_ content: String) -> [SubtitleEntry] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var entries: [SubtitleEntry] = []

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("dialogue:") else { continue }

            let payload = line.dropFirst("Dialogue:".count)
            let fields = payload.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 10 else { continue }

            let startRaw = fields[1].trimmingCharacters(in: .whitespaces)
            let endRaw = fields[2].trimmingCharacters(in: .whitespaces)
            guard let startMs = parseTimestamp(startRaw), let endMs = parseTimestamp(endRaw), endMs > startMs else {
                continue
            }

            let text = normalizeDialogueText(fields[9])
            guard !text.isEmpty else { continue }

            entries.append(SubtitleEntry(startMs: startMs, endMs: endMs, text: text))
        }

        return entries.sorted { $0.startMs < $1.startMs }
    }

    private static func parseTimestamp(_ raw: String) -> Int? {
        // ASS timestamps are usually H:MM:SS.cc (centiseconds)
        let parts = raw.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }

        let secAndFrac = parts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let seconds = Int(secAndFrac[0]) else { return nil }

        var millis = 0
        if secAndFrac.count == 2 {
            var fraction = String(secAndFrac[1])
            if fraction.count < 2 {
                fraction = fraction.padding(toLength: 2, withPad: "0", startingAt: 0)
            }
            if fraction.count > 2 {
                fraction = String(fraction.prefix(2))
            }
            millis = (Int(fraction) ?? 0) * 10
        }

        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    private static func normalizeDialogueText(_ raw: String) -> String {
        var text = raw
        // Remove ASS override blocks like {\an8}.
        while let range = text.range(of: #"\{[^\}]*\}"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        // Normalize explicit ASS line breaks.
        text = text.replacingOccurrences(of: "\\N", with: " ")
        text = text.replacingOccurrences(of: "\\n", with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
