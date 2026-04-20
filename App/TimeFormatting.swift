import Foundation

enum TimeFormatting {
    static func display(ms: Int?) -> String {
        guard let ms else { return "--" }

        let totalMs = max(ms, 0)
        let totalSeconds = totalMs / 1000
        let milliseconds = totalMs % 1000

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        }
        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }

    static func display(ms: Double?) -> String {
        guard let ms else { return "--" }

        let totalMs = max(ms, 0)
        let totalSeconds = Int(totalMs / 1000)
        let milliseconds = Int(totalMs.truncatingRemainder(dividingBy: 1000))

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        }
        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }

    static func parse(text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let milliseconds = Int(trimmed) {
            return max(0, milliseconds)
        }

        let parts = trimmed.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let secondsPart = String(parts[parts.count - 1])
        let secondsAndFraction = secondsPart.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let seconds = Int(secondsAndFraction[0]), seconds >= 0 else { return nil }

        let milliseconds: Int
        if secondsAndFraction.count == 2 {
            let fraction = String(secondsAndFraction[1])
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return nil }
            let padded = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            guard let parsedMilliseconds = Int(padded) else { return nil }
            milliseconds = parsedMilliseconds
        } else {
            milliseconds = 0
        }

        guard let minutes = Int(parts[parts.count - 2]), minutes >= 0 else { return nil }
        let hours = parts.count == 3 ? (Int(parts[0]) ?? -1) : 0
        guard hours >= 0 else { return nil }

        let totalMs = (((hours * 60) + minutes) * 60 + seconds) * 1000 + milliseconds
        return max(0, totalMs)
    }
}
