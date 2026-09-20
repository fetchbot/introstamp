import Foundation

actor IntroDBClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let maxAttempts = 3
    private let retryableStatusCodes: Set<Int> = [429, 503]
    private var lastRateLimitReset: Date = .distantPast
    private var rateLimitRemaining: Int = Int.max

    init(baseURL: URL = URL(string: "http://api.introdb.app")!, session: URLSession = makeOptimizedSession()) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    private static func makeOptimizedSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 600.0
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }

    func fetchSegments(imdbId: String, season: Int, episode: Int, apiKey: String?) async throws -> ServiceResponse<IntroDBMediaResponse> {
        await waitForRateLimit()

        var components = URLComponents(url: baseURL.appending(path: "segments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbId),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]

        guard let url = components?.url else {
            throw APIClientError(statusCode: nil, message: "Failed to build IntroDB URL", usage: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAPIKeyIfPresent(&request, apiKey: apiKey)

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            let result = try decodeResponse(data: data, response: response, as: IntroDBMediaResponse.self)
            updateRateLimitFromUsage(result.usage)
            return result
        }
    }

    func submit(_ requestBody: IntroDBSubmissionRequest, apiKey: String) async throws -> ServiceResponse<IntroDBSubmissionResponse> {
        await waitForRateLimit()

        let url = baseURL.appending(path: "submit")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")

        do {
            request.httpBody = try encoder.encode(requestBody)
        } catch {
            await SegmentSubmitPersistentLogger.shared.log(
                service: "IntroDB",
                url: url.absoluteString,
                requestBody: "<encode failed>",
                statusCode: nil,
                responseBody: nil,
                errorMessage: "Failed to encode IntroDB submit payload"
            )
            throw APIClientError(statusCode: nil, message: "Failed to encode IntroDB submit payload", usage: nil)
        }

        let requestBodyText = String(data: request.httpBody ?? Data(), encoding: .utf8)
            ?? "<non-utf8 body: \(request.httpBody?.count ?? 0) bytes>"

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let responseText = String(data: data, encoding: .utf8)

            do {
                let result = try decodeResponse(data: data, response: response, as: IntroDBSubmissionResponse.self)
                await SegmentSubmitPersistentLogger.shared.log(
                    service: "IntroDB",
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
                    service: "IntroDB",
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

    private func applyAPIKeyIfPresent(_ request: inout URLRequest, apiKey: String?) {
        guard let apiKey = trimmed(apiKey) else { return }
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
    }

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse, as type: T.Type) throws -> ServiceResponse<T> {
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError(statusCode: nil, message: "Invalid IntroDB server response", usage: nil)
        }

        let usage = parseUsageHeaders(http)

        if (200...299).contains(http.statusCode) {
            do {
                let payload = try decoder.decode(T.self, from: data)
                return ServiceResponse(payload: payload, usage: usage)
            } catch {
                throw APIClientError(statusCode: http.statusCode, message: "Failed to decode IntroDB server response", usage: usage)
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

        throw APIClientError(statusCode: http.statusCode, message: errorMessage, usage: usage)
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
            } catch let error as APIClientError
                where shouldRetry(statusCode: error.statusCode) && attempt < (maxAttempts - 1)
            {
                lastError = error
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds(forAttempt: attempt))
            } catch {
                throw error
            }
        }

        throw lastError ?? APIClientError(statusCode: nil, message: "Retry exhausted", usage: nil)
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

    func fetchAllSubmissionsWithClerk(token: String) async throws -> [IntroDBSubmissionListItem] {
        var allSubmissions: [IntroDBSubmissionListItem] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            let response = try await fetchSubmissionsWithClerk(page: currentPage, perPage: 50, token: token)
            allSubmissions.append(contentsOf: response.submissions)

            // If we got fewer items than requested, we've reached the end
            // Otherwise, use totalPages if available
            if response.submissions.count < 50 {
                hasMorePages = false
            } else if let totalPages = response.pagination.totalPages {
                hasMorePages = currentPage < totalPages
            }
            currentPage += 1
        }

        return allSubmissions
    }

    private func fetchSubmissionsWithClerk(page: Int = 1, perPage: Int = 50, token: String) async throws -> IntroDBSubmissionsResponse {
        await waitForRateLimit()

        var components = URLComponents(url: baseURL.appending(path: "api/submissions/mine"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]

        guard let url = components?.url else {
            throw APIClientError(statusCode: nil, message: "Failed to build IntroDB submissions URL", usage: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await performWithRetry {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIClientError(statusCode: nil, message: "Invalid IntroDB server response", usage: nil)
            }

            let usage = parseUsageHeaders(http)

            if (200...299).contains(http.statusCode) {
                do {
                    let result = try decoder.decode(IntroDBSubmissionsResponse.self, from: data)
                    updateRateLimitFromUsage(usage)
                    return result
                } catch {
                    throw APIClientError(statusCode: http.statusCode, message: "Failed to decode IntroDB submissions response", usage: usage)
                }
            }

            let errorMessage: String
            if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
                errorMessage = raw
            } else {
                errorMessage = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }

            throw APIClientError(statusCode: http.statusCode, message: errorMessage, usage: usage)
        }
    }
}
