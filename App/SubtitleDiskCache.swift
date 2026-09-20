import Foundation

/// Persists subtitle text to the Caches directory.
/// Files older than `maxAge` are pruned on the next access.
final class SubtitleDiskCache: Sendable {
    static let shared = SubtitleDiskCache()

    let maxAge: TimeInterval
    private let root: URL

    init(maxAge: TimeInterval = 60 * 60 * 24 * 30) { // 30 days
        self.maxAge = maxAge
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = caches.appendingPathComponent("IntroStamp/Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func get(imdbId: String, season: Int, episode: Int, language: String) -> String? {
        let url = subtitleFileURL(
            imdbId: imdbId,
            season: season,
            episode: episode,
            language: language,
            fileExtension: "srt"
        )
        return readIfFresh(url)
    }

    func set(_ text: String, imdbId: String, season: Int, episode: Int, language: String) {
        let url = subtitleFileURL(
            imdbId: imdbId,
            season: season,
            episode: episode,
            language: language,
            fileExtension: "srt"
        )
        write(text, to: url)
    }

    func get(imdbId: String, season: Int, episode: Int, language: String, fileExtension: String) -> String? {
        let url = subtitleFileURL(
            imdbId: imdbId,
            season: season,
            episode: episode,
            language: language,
            fileExtension: fileExtension
        )
        return readIfFresh(url)
    }

    func set(
        _ text: String,
        imdbId: String,
        season: Int,
        episode: Int,
        language: String,
        fileExtension: String
    ) {
        let url = subtitleFileURL(
            imdbId: imdbId,
            season: season,
            episode: episode,
            language: language,
            fileExtension: fileExtension
        )
        write(text, to: url)
    }

    func get(cacheKey: String) -> String? {
        let url = fileURL(cacheKey: cacheKey)
        return readIfFresh(url)
    }

    func set(_ text: String, cacheKey: String) {
        let url = fileURL(cacheKey: cacheKey)
        write(text, to: url)
    }

    func pruneExpired() {
        let key = "SubtitleDiskCache.lastPruned"
        let lastPruned = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastPruned) > 60 * 60 * 24 else { return }
        UserDefaults.standard.set(Date(), forKey: key)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries {
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    // MARK: - Private

    private func subtitleFileURL(
        imdbId: String,
        season: Int,
        episode: Int,
        language: String,
        fileExtension: String
    ) -> URL {
        let safeImdbId = sanitizeFileComponent(imdbId)
        let safeLanguage = sanitizeFileComponent(normalizeLanguage(language))
        let safeExtension = sanitizeFileExtension(fileExtension)
        let fileName = "\(safeImdbId)_s\(season)e\(episode)_\(safeLanguage).\(safeExtension)"
        return root.appendingPathComponent(fileName)
    }

    private func fileURL(cacheKey: String) -> URL {
        let safeCacheKey = sanitizeFileComponent(cacheKey)
        let fileName = "\(safeCacheKey).subtitle"
        return root.appendingPathComponent(fileName)
    }

    private func readIfFresh(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > maxAge {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func normalizeLanguage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let separatorIndex = trimmed.firstIndex(of: "-") {
            return String(trimmed[..<separatorIndex])
        }
        if let separatorIndex = trimmed.firstIndex(of: "_") {
            return String(trimmed[..<separatorIndex])
        }
        return trimmed
    }

    private func sanitizeFileComponent(_ value: String) -> String {
        let lowered = value.lowercased()
        let sanitized = lowered.map { char -> Character in
            if char.isLetter || char.isNumber || char == "_" || char == "-" {
                return char
            }
            return "_"
        }
        let collapsed = String(sanitized).replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "subtitle" : trimmed
    }

    private func sanitizeFileExtension(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sanitized = sanitizeFileComponent(trimmed)
        return sanitized.isEmpty ? "subtitle" : sanitized
    }
}
