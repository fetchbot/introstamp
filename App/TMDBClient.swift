import Foundation

struct TMDBClientError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

actor TMDBClient {
    private let baseURL: URL
    private let imageBaseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL = URL(string: "https://api.themoviedb.org/3")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.imageBaseURL = URL(string: "https://image.tmdb.org/t/p/")!
        self.session = session
        self.decoder = JSONDecoder()
    }

    func resolveFromFilename(_ url: URL, apiKey: String) async throws -> AutoLookupResult? {
        let hint = FilenameMediaParser.parse(url: url)
        return try await resolveHint(hint, apiKey: apiKey)
    }

    func resolveHints(_ hint: ParsedFilenameHint, apiKey: String, limit: Int = 6) async throws -> [AutoLookupResult] {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw TMDBClientError(message: "TMDB API key is missing")
        }

        guard !hint.title.isEmpty else {
            return []
        }

        let endpoint: String
        let yearQueryName: String

        switch hint.mediaTypeHint {
        case .movie:
            endpoint = "search/movie"
            yearQueryName = "year"
        case .tv:
            endpoint = "search/tv"
            yearQueryName = "first_air_date_year"
        }

        // Normalize title to NFC (precomposed) for TMDB API
        let nfcTitle = hint.title.precomposedStringWithCanonicalMapping

        var components = URLComponents(url: baseURL.appending(path: endpoint), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: nfcTitle),
            URLQueryItem(name: "include_adult", value: "false")
        ]

        if let year = hint.year {
            items.append(URLQueryItem(name: yearQueryName, value: String(year)))
        }

        components?.queryItems = items
        guard let url = components?.url else {
            throw TMDBClientError(message: "Failed to build TMDB lookup URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TMDBClientError(message: "Invalid TMDB response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "TMDB request failed"
            throw TMDBClientError(message: body)
        }

        let decoded = try decoder.decode(TMDBSearchResponse.self, from: data)
        let mapped = decoded.results
            .prefix(max(1, limit))
            .map { result in
                AutoLookupResult(
                    tmdbId: result.id,
                    imdbId: nil,
                    mediaType: hint.mediaTypeHint,
                    season: hint.season,
                    episode: hint.episode,
                    title: result.titleName,
                    matchedYear: result.releaseYear,
                    posterURL: posterURL(path: result.posterPath)
                )
            }
        return try await enrichWithIMDbIDs(results: mapped, mediaType: hint.mediaTypeHint, apiKey: cleanedKey)
    }

    func resolveHint(_ hint: ParsedFilenameHint, apiKey: String) async throws -> AutoLookupResult? {
        try await resolveHints(hint, apiKey: apiKey, limit: 1).first
    }

        func search(title: String, mediaType: MediaType, apiKey: String, limit: Int = 10) async throws -> [AutoLookupResult] {
            let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedKey.isEmpty else {
                throw TMDBClientError(message: "TMDB API key is missing")
            }
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

            let endpoint = mediaType == .movie ? "search/movie" : "search/tv"
            var components = URLComponents(url: baseURL.appending(path: endpoint), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "query", value: title),
                URLQueryItem(name: "include_adult", value: "false")
            ]
            guard let url = components?.url else {
                throw TMDBClientError(message: "Failed to build TMDB search URL")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TMDBClientError(message: "Invalid TMDB response")
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "TMDB request failed"
                throw TMDBClientError(message: body)
            }

            let decoded = try decoder.decode(TMDBSearchResponse.self, from: data)
            let mapped = decoded.results
                .prefix(max(1, limit))
                .map { result in
                    AutoLookupResult(
                        tmdbId: result.id,
                        imdbId: nil,
                        mediaType: mediaType,
                        season: nil,
                        episode: nil,
                        title: result.titleName,
                        matchedYear: result.releaseYear,
                        posterURL: posterURL(path: result.posterPath)
                    )
                }
            return try await enrichWithIMDbIDs(results: mapped, mediaType: mediaType, apiKey: cleanedKey)
        }

    private func enrichWithIMDbIDs(results: [AutoLookupResult], mediaType: MediaType, apiKey: String) async throws -> [AutoLookupResult] {
        guard !results.isEmpty else { return [] }

        var enriched = Array(repeating: Optional<AutoLookupResult>.none, count: results.count)
        try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for (index, result) in results.enumerated() {
                group.addTask {
                    let imdbId = try await self.fetchIMDbID(mediaType: mediaType, tmdbId: result.tmdbId, apiKey: apiKey)
                    return (index, imdbId)
                }
            }

            for try await (index, imdbId) in group {
                var item = results[index]
                item.imdbId = imdbId
                enriched[index] = item
            }
        }

        return enriched.compactMap { $0 }
    }

    private func fetchIMDbID(mediaType: MediaType, tmdbId: Int, apiKey: String) async throws -> String? {
        let pathPrefix = mediaType == .movie ? "movie" : "tv"
        var components = URLComponents(
            url: baseURL.appending(path: "\(pathPrefix)/\(tmdbId)/external_ids"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "language", value: "en-US")]

        guard let url = components?.url else {
            throw TMDBClientError(message: "Failed to build TMDB external IDs URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TMDBClientError(message: "Invalid TMDB response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "TMDB request failed"
            throw TMDBClientError(message: body)
        }

        return try decoder.decode(TMDBExternalIDsResponse.self, from: data).imdbId
    }

    private func posterURL(path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return imageBaseURL
            .appendingPathComponent("w154")
            .appendingPathComponent(cleanPath)
    }
}

private struct TMDBSearchResponse: Decodable {
    var results: [TMDBResult]
}

private struct TMDBResult: Decodable {
    var id: Int
    var title: String?
    var name: String?
    var releaseDate: String?
    var firstAirDate: String?
    var posterPath: String?

    var titleName: String {
        title ?? name ?? "Untitled"
    }

    var releaseYear: Int? {
        let value = releaseDate ?? firstAirDate
        guard let value else { return nil }
        let prefix = value.prefix(4)
        return Int(prefix)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
    }
}

private struct TMDBExternalIDsResponse: Decodable {
    var imdbId: String?

    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
    }
}
