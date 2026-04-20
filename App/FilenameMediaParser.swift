import Foundation

enum FilenameMediaParser {
    private static let noiseTokens: Set<String> = [
        "480p", "576p", "720p", "1080p", "2160p",
        "x264", "x265", "h264", "h265", "hevc",
        "webrip", "web", "webdl", "bluray", "brrip",
        "hdrip", "dvdrip", "remux", "proper", "repack",
        "mkv", "mp4", "mov", "m4v", "avi"
    ]

    // Pre-compiled regex patterns for performance
    private static let seasonEpisodeStandardRegex = try! NSRegularExpression(pattern: #"\bS(\d{1,2})E(\d{1,2})\b"#, options: [.caseInsensitive])
    private static let seasonEpisodeAlternateRegex = try! NSRegularExpression(pattern: #"\b(\d{1,2})x(\d{1,2})\b"#, options: [.caseInsensitive])
    private static let yearRegex = try! NSRegularExpression(pattern: #"\b(19\d{2}|20\d{2})\b"#)

    static func parse(url: URL) -> ParsedFilenameHint {
        let filename = url.deletingPathExtension().lastPathComponent
        return parse(rawName: filename)
    }

    static func parse(rawName: String) -> ParsedFilenameHint {
        var working = rawName
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let seasonEpisode = extractSeasonEpisode(from: working)
        if let match = seasonEpisode?.matchedText {
            working = working.replacingOccurrences(of: match, with: " ", options: .caseInsensitive)
        }

        let year = extractYear(from: working)
        if let year {
            working = working.replacingOccurrences(of: String(year), with: " ")
        }

        let title = normalizeTitle(working)

        return ParsedFilenameHint(
            title: title.isEmpty ? rawName : title,
            year: year,
            season: seasonEpisode?.season,
            episode: seasonEpisode?.episode
        )
    }

    private static func normalizeTitle(_ input: String) -> String {
        let disallowed = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let cleaned = input.components(separatedBy: disallowed).joined(separator: " ")
        let compact = cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let filteredTokens = compact
            .split(separator: " ")
            .filter { token in
                !noiseTokens.contains(token.lowercased())
            }

        return filteredTokens.joined(separator: " ")
    }

    private static func extractYear(from input: String) -> Int? {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = yearRegex.firstMatch(in: input, options: [], range: range),
              let yearRange = Range(match.range(at: 1), in: input)
        else {
            return nil
        }
        return Int(input[yearRange])
    }

    private static func extractSeasonEpisode(from input: String) -> (season: Int, episode: Int, matchedText: String)? {
        let regexes = [seasonEpisodeStandardRegex, seasonEpisodeAlternateRegex]
        let range = NSRange(input.startIndex..<input.endIndex, in: input)

        for regex in regexes {
            guard let match = regex.firstMatch(in: input, options: [], range: range),
                  let seasonRange = Range(match.range(at: 1), in: input),
                  let episodeRange = Range(match.range(at: 2), in: input),
                  let fullRange = Range(match.range(at: 0), in: input),
                  let season = Int(input[seasonRange]),
                  let episode = Int(input[episodeRange])
            else {
                continue
            }

            return (season, episode, String(input[fullRange]))
        }

        return nil
    }
}
