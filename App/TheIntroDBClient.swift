import Foundation

struct ServiceResponse<T: Sendable>: Sendable {
    var payload: T
    var usage: UsageHeaders?
}

struct APIClientError: LocalizedError, Sendable {
    var statusCode: Int?
    var message: String
    var usage: UsageHeaders?
    var retryAfterSeconds: TimeInterval?

    var errorDescription: String? { message }
}

actor TheIntroDBClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let maxAttempts = 3
    private let retryableStatusCodes: Set<Int> = [429, 503]
    private var lastRateLimitReset: Date = .distantPast
    private var rateLimitRemaining: Int = Int.max

    init(baseURL: URL = URL(string: "https://api.theintrodb.org/v3")!, session: URLSession = makeOptimizedSession()) {
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
        config.timeoutIntervalForRequest = 60.0  // Increased from 30 to handle gzip decompression
        config.timeoutIntervalForResource = 600.0  // Increased from 300 for large requests
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }

    func fetchMedia(query: MediaQuery, apiKey: String?) async throws -> ServiceResponse<TheIntroDBMediaResponse> {
        await waitForRateLimit()

        var components = URLComponents(url: baseURL.appending(path: "media"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []

        if let tmdbId = query.tmdbId {
            items.append(URLQueryItem(name: "tmdb_id", value: String(tmdbId)))
        }
        if let imdbId = trimmed(query.imdbId) {
            items.append(URLQueryItem(name: "imdb_id", value: imdbId))
        }
        if let tvdbId = query.tvdbId {
            items.append(URLQueryItem(name: "tvdb_id", value: String(tvdbId)))
        }
        if let season = query.season {
            items.append(URLQueryItem(name: "season", value: String(season)))
        }
        if let episode = query.episode {
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        if let durationMs = query.durationMs, durationMs >= 0 {
            items.append(URLQueryItem(name: "duration_ms", value: String(durationMs)))
        }

        components?.queryItems = items.isEmpty ? nil : items

        guard let url = components?.url else {
            throw APIClientError(statusCode: nil, message: "Failed to build media URL", usage: nil, retryAfterSeconds: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthIfPresent(&request, apiKey: apiKey)

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            let result = try decodeResponse(data: data, response: response, as: TheIntroDBMediaResponse.self)
            updateRateLimitFromUsage(result.usage)
            return result
        }
    }

    func fetchMediaVersions(query: MediaQuery, apiKey: String?) async throws -> ServiceResponse<TheIntroDBMediaVersionListResponse> {
        await waitForRateLimit()

        var components = URLComponents(url: baseURL.appending(path: "media"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [URLQueryItem(name: "list_versions", value: "true")]

        if let tmdbId = query.tmdbId {
            items.append(URLQueryItem(name: "tmdb_id", value: String(tmdbId)))
        }
        if let imdbId = trimmed(query.imdbId) {
            items.append(URLQueryItem(name: "imdb_id", value: imdbId))
        }
        if let tvdbId = query.tvdbId {
            items.append(URLQueryItem(name: "tvdb_id", value: String(tvdbId)))
        }
        if let season = query.season {
            items.append(URLQueryItem(name: "season", value: String(season)))
        }
        if let episode = query.episode {
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }

        components?.queryItems = items

        guard let url = components?.url else {
            throw APIClientError(statusCode: nil, message: "Failed to build media versions URL", usage: nil, retryAfterSeconds: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthIfPresent(&request, apiKey: apiKey)

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            let result = try decodeResponse(data: data, response: response, as: TheIntroDBMediaVersionListResponse.self)
            updateRateLimitFromUsage(result.usage)
            return result
        }
    }

    func submit(_ requestBody: TheIntroDBSubmissionRequest, apiKey: String) async throws -> ServiceResponse<TheIntroDBSubmissionResponse> {
        await waitForRateLimit()

        let url = baseURL.appending(path: "submit")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try encoder.encode(requestBody)
        } catch {
            await SegmentSubmitPersistentLogger.shared.log(
                service: "TheIntroDB",
                url: url.absoluteString,
                requestBody: "<encode failed>",
                statusCode: nil,
                responseBody: nil,
                errorMessage: "Failed to encode submit payload"
            )
            throw APIClientError(statusCode: nil, message: "Failed to encode submit payload", usage: nil)
        }

        let requestBodyText = String(data: request.httpBody ?? Data(), encoding: .utf8)
            ?? "<non-utf8 body: \(request.httpBody?.count ?? 0) bytes>"

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let responseText = String(data: data, encoding: .utf8)

            do {
                let result = try decodeResponse(data: data, response: response, as: TheIntroDBSubmissionResponse.self)
                await SegmentSubmitPersistentLogger.shared.log(
                    service: "TheIntroDB",
                    url: url.absoluteString,
                    requestBody: requestBodyText,
                    statusCode: statusCode,
                    responseBody: responseText,
                    errorMessage: nil
                )
                updateRateLimitFromUsage(result.usage)
                return result
            } catch {
                await SegmentSubmitPersistentLogger.shared.log(
                    service: "TheIntroDB",
                    url: url.absoluteString,
                    requestBody: requestBodyText,
                    statusCode: statusCode,
                    responseBody: responseText,
                    errorMessage: error.localizedDescription
                )
                throw error
            }
        }
    }

    private func applyAuthIfPresent(_ request: inout URLRequest, apiKey: String?) {
        guard let apiKey = trimmed(apiKey) else { return }
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse, as type: T.Type) throws -> ServiceResponse<T> {
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError(statusCode: nil, message: "Invalid server response", usage: nil, retryAfterSeconds: nil)
        }

        let usage = parseUsageHeaders(http)
        let retryAfterSeconds = retryAfterHeaderSeconds(http)

        if (200...299).contains(http.statusCode) {
            do {
                let payload = try decoder.decode(T.self, from: data)
                return ServiceResponse(payload: payload, usage: usage)
            } catch {
                throw APIClientError(statusCode: http.statusCode, message: "Failed to decode server response", usage: usage, retryAfterSeconds: retryAfterSeconds)
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

        throw APIClientError(statusCode: http.statusCode, message: errorMessage, usage: usage, retryAfterSeconds: retryAfterSeconds)
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

    private func retryAfterHeaderSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }

        if let seconds = TimeInterval(value), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let retryDate = formatter.date(from: value) {
            return max(0, retryDate.timeIntervalSinceNow)
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
            } catch let error as APIClientError
                where shouldRetry(statusCode: error.statusCode) && attempt < (maxAttempts - 1)
            {
                lastError = error
                updateRateLimitFromUsage(error.usage)
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds(forAttempt: attempt, error: error))
            } catch {
                throw error
            }
        }

        throw lastError ?? APIClientError(statusCode: nil, message: "Retry exhausted", usage: nil, retryAfterSeconds: nil)
    }

    private func shouldRetry(statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return retryableStatusCodes.contains(statusCode)
    }

    private func retryDelayNanoseconds(forAttempt attempt: Int, error: APIClientError) -> UInt64 {
        let delaySeconds: TimeInterval
        if let retryAfterSeconds = error.retryAfterSeconds, retryAfterSeconds > 0 {
            delaySeconds = retryAfterSeconds
        } else if let resetSeconds = error.usage?.rateResetSeconds, resetSeconds > 0 {
            delaySeconds = TimeInterval(resetSeconds)
        } else {
            delaySeconds = Double(1 << attempt) * 0.1
        }
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

    func fetchAllSubmissionsWithClerk(token: String) async throws -> [TheIntroDBSubmissionListItem] {
        var allSubmissions: [TheIntroDBSubmissionListItem] = []
        var currentOffset = 0
        let limit = 200
        var hasMoreSubmissions = true

        while hasMoreSubmissions {
            let response = try await fetchSubmissionsWithClerk(limit: limit, offset: currentOffset, token: token)
            allSubmissions.append(contentsOf: response.submissions)

            // If we got fewer items than the limit, we've reached the end
            // Otherwise, use the total count if available
            if response.submissions.count < limit {
                hasMoreSubmissions = false
            } else {
                hasMoreSubmissions = (currentOffset + limit) < response.total
            }
            currentOffset += limit
        }

        return allSubmissions
    }

    private func fetchSubmissionsWithClerk(limit: Int = 200, offset: Int = 0, token: String) async throws -> TheIntroDBSubmissionsResponse {
        await waitForRateLimit()

        var components = URLComponents(url: baseURL.appending(path: "submissions"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]

        guard let url = components?.url else {
            throw APIClientError(statusCode: nil, message: "Failed to build submissions URL", usage: nil, retryAfterSeconds: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            let result = try decodeResponse(data: data, response: response, as: TheIntroDBSubmissionsResponse.self)
            updateRateLimitFromUsage(result.usage)
            return result.payload
        }
    }
}
