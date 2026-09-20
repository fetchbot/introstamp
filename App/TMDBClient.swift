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

    func fetchGenres(mediaType: MediaType, tmdbId: Int, apiKey: String) async throws -> [String] {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw TMDBClientError(message: "TMDB API key is missing")
        }

        let endpoint = mediaType == .movie ? "movie" : "tv"
        var components = URLComponents(
            url: baseURL.appending(path: "\(endpoint)/\(tmdbId)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "language", value: "en-US")]

        guard let url = components?.url else {
            throw TMDBClientError(message: "Failed to build TMDB details URL")
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

        let details = try decoder.decode(TMDBDetailsResponse.self, from: data)
        return details.genres.map { $0.name }
    }

    func fetchTVEpisodeReferences(tmdbId: Int, apiKey: String) async throws -> TMDBTVEpisodeReferenceResponse {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw TMDBClientError(message: "TMDB API key is missing")
        }

        var components = URLComponents(
            url: baseURL.appending(path: "tv/\(tmdbId)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "language", value: "en-US")]

        guard let url = components?.url else {
            throw TMDBClientError(message: "Failed to build TMDB TV details URL")
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

        let details = try decoder.decode(TMDBTVDetailsResponse.self, from: data)
        let episodes = details.seasons
            .filter { $0.seasonNumber >= 0 && $0.episodeCount > 0 }
            .flatMap { season in
                (1...season.episodeCount).map { episode in
                    TMDBTVEpisodeReference(season: season.seasonNumber, episode: episode)
                }
            }

        return TMDBTVEpisodeReferenceResponse(
            seriesTitle: details.name ?? "TMDB \(tmdbId)",
            posterURL: posterURL(path: details.posterPath),
            episodeRuntimeMinutes: details.episodeRunTime?.first,
            episodes: episodes
        )
    }

    func fetchMovieRuntimeMinutes(tmdbId: Int, apiKey: String) async throws -> Int? {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw TMDBClientError(message: "TMDB API key is missing")
        }

        var components = URLComponents(
            url: baseURL.appending(path: "movie/\(tmdbId)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "language", value: "en-US")]

        guard let url = components?.url else {
            throw TMDBClientError(message: "Failed to build TMDB movie details URL")
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

        let details = try decoder.decode(TMDBMovieDetailsResponse.self, from: data)
        return details.runtime
    }

    func fetchTVEpisodeRuntimeMinutes(tmdbId: Int, season: Int, episode: Int, apiKey: String) async throws -> Int? {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw TMDBClientError(message: "TMDB API key is missing")
        }

        var components = URLComponents(
            url: baseURL.appending(path: "tv/\(tmdbId)/season/\(season)/episode/\(episode)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "language", value: "en-US")]

        guard let url = components?.url else {
            throw TMDBClientError(message: "Failed to build TMDB TV episode details URL")
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

        let details = try decoder.decode(TMDBTVEpisodeDetailsResponse.self, from: data)
        return details.runtime
    }

    func fetchMovieMetadata(tmdbId: Int, apiKey: String) async throws -> TMDBMovieMetadata {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw TMDBClientError(message: "TMDB API key is missing")
        }

        var components = URLComponents(
            url: baseURL.appending(path: "movie/\(tmdbId)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "language", value: "en-US")]

        guard let url = components?.url else {
            throw TMDBClientError(message: "Failed to build TMDB movie details URL")
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

        let details = try decoder.decode(TMDBMovieDetailsResponse.self, from: data)
        return TMDBMovieMetadata(
            title: details.title ?? "TMDB \(tmdbId)",
            posterURL: posterURL(path: details.posterPath),
            runtimeMinutes: details.runtime
        )
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

private struct TMDBDetailsResponse: Decodable {
    var genres: [TMDBGenre]
}

struct TMDBTVEpisodeReference: Hashable, Sendable {
    var season: Int
    var episode: Int
}

struct TMDBTVEpisodeReferenceResponse: Sendable {
    var seriesTitle: String
    var posterURL: URL?
    var episodeRuntimeMinutes: Int?
    var episodes: [TMDBTVEpisodeReference]
}

struct TMDBMovieMetadata: Sendable {
    var title: String
    var posterURL: URL?
    var runtimeMinutes: Int?
}

private struct TMDBTVDetailsResponse: Decodable {
    var name: String?
    var posterPath: String?
    var episodeRunTime: [Int]?
    var seasons: [TMDBTVSeasonSummary]

    enum CodingKeys: String, CodingKey {
        case name
        case posterPath = "poster_path"
        case episodeRunTime = "episode_run_time"
        case seasons
    }
}

private struct TMDBMovieDetailsResponse: Decodable {
    var title: String?
    var posterPath: String?
    var runtime: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case posterPath = "poster_path"
        case runtime
    }
}

private struct TMDBTVEpisodeDetailsResponse: Decodable {
    var runtime: Int?
}

private struct TMDBTVSeasonSummary: Decodable {
    var seasonNumber: Int
    var episodeCount: Int

    enum CodingKeys: String, CodingKey {
        case seasonNumber = "season_number"
        case episodeCount = "episode_count"
    }
}

private struct TMDBGenre: Decodable {
    var name: String
}
