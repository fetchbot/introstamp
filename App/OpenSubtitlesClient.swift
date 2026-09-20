import Foundation

struct OSSubtitleFile: Sendable {
    var fileId: Int
    var fileName: String
    var language: String
    var downloadCount: Int
}

struct OpenSubtitlesError: LocalizedError, Sendable {
    var message: String
    var statusCode: Int?
    var errorDescription: String? { message }
}

actor OpenSubtitlesClient {
    private let baseURL = URL(string: "https://api.opensubtitles.com/api/v1")!
    private let userAgent = "IntroStamp"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Search

    /// Search for subtitle files by IMDB ID, season and episode number.
    func searchSubtitles(
        imdbId: String,
        season: Int,
        episode: Int,
        language: String? = nil,
        apiKey: String
    ) async throws -> [OSSubtitleFile] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "imdb_id", value: imdbId),
            URLQueryItem(name: "type", value: "episode"),
            URLQueryItem(name: "season_number", value: String(season)),
            URLQueryItem(name: "episode_number", value: String(episode)),
        ]
        if let language, !language.isEmpty {
            queryItems.append(URLQueryItem(name: "languages", value: language))
        }

        var components = URLComponents(url: baseURL.appending(path: "subtitles"), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw OpenSubtitlesError(message: "Failed to build OpenSubtitles search URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        return try parseSearchResults(data: data)
    }

    // MARK: - Download

    /// Request a temporary download URL for a subtitle file, then fetch and return the SRT text.
    func downloadSubtitle(fileId: Int, apiKey: String) async throws -> String {
        let downloadURL = baseURL.appending(path: "download")
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = ["file_id": fileId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let link = json["link"] as? String,
            let fileURL = URL(string: link)
        else {
            throw OpenSubtitlesError(message: "OpenSubtitles download response missing 'link' field")
        }

        let (fileData, fileResponse) = try await session.data(from: fileURL)
        try validateHTTPResponse(fileResponse, data: fileData)

        // Subtitle files are always delivered as UTF-8 by OpenSubtitles.
        guard let text = String(data: fileData, encoding: .utf8)
                ?? String(data: fileData, encoding: .isoLatin1) else {
            throw OpenSubtitlesError(message: "Could not decode subtitle file as text")
        }
        return text
    }

    // MARK: - Private helpers

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode >= 200 && http.statusCode < 300 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let snippet = String(body.prefix(200))
            throw OpenSubtitlesError(
                message: "OpenSubtitles API error \(http.statusCode): \(snippet)",
                statusCode: http.statusCode
            )
        }
    }

    private func parseSearchResults(data: Data) throws -> [OSSubtitleFile] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataArray = json["data"] as? [[String: Any]]
        else {
            return []
        }

        var results: [OSSubtitleFile] = []
        for item in dataArray {
            guard
                let attributes = item["attributes"] as? [String: Any],
                let files = attributes["files"] as? [[String: Any]],
                let firstFile = files.first,
                let fileId = firstFile["file_id"] as? Int
            else { continue }

            let fileName = (firstFile["file_name"] as? String) ?? ""
            let language = (attributes["language"] as? String) ?? "en"
            let downloadCount = (attributes["download_count"] as? Int) ?? 0
            results.append(OSSubtitleFile(fileId: fileId, fileName: fileName, language: language, downloadCount: downloadCount))
        }
        return results
    }
}
