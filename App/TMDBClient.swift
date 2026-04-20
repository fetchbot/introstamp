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

        var components = URLComponents(url: baseURL.appending(path: endpoint), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: hint.title),
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
        return decoded.results
            .prefix(max(1, limit))
            .map { result in
                AutoLookupResult(
                    tmdbId: result.id,
                    mediaType: hint.mediaTypeHint,
                    season: hint.season,
                    episode: hint.episode,
                    title: result.titleName,
                    matchedYear: result.releaseYear,
                    posterURL: posterURL(path: result.posterPath)
                )
            }
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
            return decoded.results
                .prefix(max(1, limit))
                .map { result in
                    AutoLookupResult(
                        tmdbId: result.id,
                        mediaType: mediaType,
                        season: nil,
                        episode: nil,
                        title: result.titleName,
                        matchedYear: result.releaseYear,
                        posterURL: posterURL(path: result.posterPath)
                    )
                }
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
