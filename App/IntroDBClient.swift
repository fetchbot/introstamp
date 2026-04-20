import Foundation

struct IntroDBResponse<T: Sendable>: Sendable {
    var payload: T
    var usage: UsageHeaders?
}

struct IntroDBClientError: LocalizedError, Sendable {
    var statusCode: Int?
    var message: String
    var usage: UsageHeaders?

    var errorDescription: String? { message }
}

actor IntroDBClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let maxAttempts = 3
    private let retryableStatusCodes: Set<Int> = [429, 503]
    private var lastRateLimitReset: Date = .distantPast
    private var rateLimitRemaining: Int = Int.max

    init(baseURL: URL = URL(string: "https://api.theintrodb.org/v2")!, session: URLSession = makeOptimizedSession()) {
        self.baseURL = baseURL
        self.session = session
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        self.decoder = decoder
        self.encoder = encoder
    }

    private static func makeOptimizedSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 300.0
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }

    func fetchMedia(query: MediaQuery, apiKey: String?) async throws -> IntroDBResponse<IntroDBMediaResponse> {
        await waitForRateLimit()

        var components = URLComponents(url: baseURL.appending(path: "media"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []

        if let tmdbId = query.tmdbId {
            items.append(URLQueryItem(name: "tmdb_id", value: String(tmdbId)))
        }
        if let imdbId = trimmed(query.imdbId) {
            items.append(URLQueryItem(name: "imdb_id", value: imdbId))
        }
        if let season = query.season {
            items.append(URLQueryItem(name: "season", value: String(season)))
        }
        if let episode = query.episode {
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }

        components?.queryItems = items.isEmpty ? nil : items

        guard let url = components?.url else {
            throw IntroDBClientError(statusCode: nil, message: "Failed to build media URL", usage: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthIfPresent(&request, apiKey: apiKey)

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            let result = try decodeResponse(data: data, response: response, as: IntroDBMediaResponse.self)
            updateRateLimitFromUsage(result.usage)
            return result
        }
    }

    func submit(_ requestBody: IntroDBSubmissionRequest, apiKey: String) async throws -> IntroDBResponse<IntroDBSubmissionResponse> {
        await waitForRateLimit()

        let url = baseURL.appending(path: "submit")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try encoder.encode(requestBody)
        } catch {
            throw IntroDBClientError(statusCode: nil, message: "Failed to encode submit payload", usage: nil)
        }

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            let result = try decodeResponse(data: data, response: response, as: IntroDBSubmissionResponse.self)
            updateRateLimitFromUsage(result.usage)
            return result
        }
    }

    private func applyAuthIfPresent(_ request: inout URLRequest, apiKey: String?) {
        guard let apiKey = trimmed(apiKey) else { return }
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse, as type: T.Type) throws -> IntroDBResponse<T> {
        guard let http = response as? HTTPURLResponse else {
            throw IntroDBClientError(statusCode: nil, message: "Invalid server response", usage: nil)
        }

        let usage = parseUsageHeaders(http)

        if (200...299).contains(http.statusCode) {
            do {
                let payload = try decoder.decode(T.self, from: data)
                return IntroDBResponse(payload: payload, usage: usage)
            } catch {
                throw IntroDBClientError(statusCode: http.statusCode, message: "Failed to decode server response", usage: usage)
            }
        }

        let errorMessage: String
        if let parsed = try? decoder.decode(IntroDBErrorPayload.self, from: data) {
            if let details = parsed.details, !details.isEmpty {
                errorMessage = "\(parsed.error): \(details)"
            } else {
                errorMessage = parsed.error
            }
        } else if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            errorMessage = raw
        } else {
            errorMessage = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        }

        throw IntroDBClientError(statusCode: http.statusCode, message: errorMessage, usage: usage)
    }

    private func parseUsageHeaders(_ response: HTTPURLResponse) -> UsageHeaders {
        UsageHeaders(
            rateLimit: intHeader("X-RateLimit-Limit", response: response),
            rateRemaining: intHeader("X-RateLimit-Remaining", response: response),
            rateResetSeconds: intHeader("X-RateLimit-Reset", response: response),
            usageLimit: intHeader("X-UsageLimit-Limit", response: response),
            usageRemaining: intHeader("X-UsageLimit-Remaining", response: response),
            usageResetSeconds: intHeader("X-UsageLimit-Reset", response: response)
        )
    }

    private func intHeader(_ name: String, response: HTTPURLResponse) -> Int? {
        if let value = response.value(forHTTPHeaderField: name) {
            return Int(value)
        }
        return nil
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func performWithRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch let error as IntroDBClientError
                where shouldRetry(statusCode: error.statusCode) && attempt < (maxAttempts - 1)
            {
                lastError = error
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds(forAttempt: attempt))
            } catch {
                throw error
            }
        }

        throw lastError ?? IntroDBClientError(statusCode: nil, message: "Retry exhausted", usage: nil)
    }

    private func shouldRetry(statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return retryableStatusCodes.contains(statusCode)
    }

    private func retryDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let delaySeconds = Double(1 << attempt) * 0.1
        return UInt64(delaySeconds * 1_000_000_000)
    }

    private func updateRateLimitFromUsage(_ usage: UsageHeaders?) {
        guard let usage else { return }
        if let remaining = usage.rateRemaining {
            rateLimitRemaining = remaining
        }
        if let reset = usage.rateResetSeconds {
            lastRateLimitReset = Date().addingTimeInterval(TimeInterval(reset))
        }
    }

    private func waitForRateLimit() async {
        let timeUntilReset = lastRateLimitReset.timeIntervalSinceNow
        if rateLimitRemaining <= 1 && timeUntilReset > 0 {
            try? await Task.sleep(nanoseconds: UInt64(timeUntilReset * 1_000_000_000))
        }
    }
}
