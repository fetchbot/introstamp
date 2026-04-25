import Foundation
import XCTest
@testable import IntroStamp

final class IntroDBClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchMediaDecodesSegmentsAndUsageHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-123")
            XCTAssertTrue(request.url?.absoluteString.contains("tmdb_id=95479") == true)
            XCTAssertTrue(request.url?.absoluteString.contains("season=1") == true)
            XCTAssertTrue(request.url?.absoluteString.contains("episode=10") == true)

            let json = #"{"tmdb_id":95479,"type":"tv","season":1,"episode":10,"intro":[{"start_ms":170581,"end_ms":259986}],"credits":[{"start_ms":1278055,"end_ms":1368055}]}"#
            let data = Data(json.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "X-RateLimit-Limit": "30",
                    "X-RateLimit-Remaining": "29",
                    "X-UsageLimit-Limit": "200",
                    "X-UsageLimit-Remaining": "199"
                ]
            )!
            return (response, data)
        }

        let client = TheIntroDBClient(baseURL: URL(string: "https://example.com/v2")!, session: makeSession())

        let response = try await client.fetchMedia(
            query: MediaQuery(tmdbId: 95479, imdbId: nil, season: 1, episode: 10),
            apiKey: "key-123"
        )

        XCTAssertEqual(response.payload.tmdbId, 95479)
        XCTAssertEqual(response.payload.type, .tv)
        XCTAssertEqual(response.payload.intro?.first?.startMs, 170_581)
        XCTAssertEqual(response.payload.credits?.first?.endMs, 1_368_055)

        XCTAssertEqual(response.usage?.rateLimit, 30)
        XCTAssertEqual(response.usage?.usageRemaining, 199)
    }

    func testSubmitReturnsConflictError() async {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-123")

            let data = Data(#"{"error":"duplicate segment"}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: nil,
                headerFields: ["X-RateLimit-Remaining": "0"]
            )!
            return (response, data)
        }

        let client = TheIntroDBClient(baseURL: URL(string: "https://example.com/v2")!, session: makeSession())

        let request = TheIntroDBSubmissionRequest(
            tmdbId: 123,
            type: .movie,
            segment: .intro,
            season: nil,
            episode: nil,
            startMs: 0,
            endMs: 30_000,
            imdbId: nil
        )

        do {
            _ = try await client.submit(request, apiKey: "key-123")
            XCTFail("Expected submit to fail")
        } catch let error as APIClientError {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertTrue(error.message.contains("duplicate"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testIntroDBV1FetchDecodesSegments() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "idb_test")
            XCTAssertTrue(request.url?.absoluteString.contains("imdb_id=tt0944947") == true)
            XCTAssertTrue(request.url?.absoluteString.contains("season=1") == true)
            XCTAssertTrue(request.url?.absoluteString.contains("episode=1") == true)

            let json = #"{"imdb_id":"tt0944947","season":1,"episode":1,"intro":{"start_ms":1000,"end_ms":61000,"confidence":0.9,"submission_count":5},"recap":null,"outro":{"start_ms":3200000,"end_ms":3300000,"confidence":0.8,"submission_count":2}}"#
            let data = Data(json.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let client = IntroDBClient(baseURL: URL(string: "https://example.com")!, session: makeSession())
        let response = try await client.fetchSegments(imdbId: "tt0944947", season: 1, episode: 1, apiKey: "idb_test")

        XCTAssertEqual(response.payload.imdbId, "tt0944947")
        XCTAssertEqual(response.payload.intro?.startMs, 1_000)
        XCTAssertEqual(response.payload.outro?.endMs, 3_300_000)

        let grouped = response.payload.groupedSegments()
        XCTAssertEqual(grouped[.credits]?.first?.startMs, 3_200_000)
        XCTAssertEqual(grouped[.preview]?.count, 0)
    }

    func testIntroDBV1SubmitUsesXAPIKeyHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "idb_submit")

            let json = #"{"ok":true,"submission":{"id":"550e8400-e29b-41d4-a716-446655440123","status":"pending","weight":1}}"#
            let data = Data(json.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let client = IntroDBClient(baseURL: URL(string: "https://example.com")!, session: makeSession())
        let request = IntroDBSubmissionRequest(
            segmentType: .intro,
            imdbId: "tt0903747",
            season: 1,
            episode: 1,
            startSec: 1.5,
            endSec: 40.0,
            tvdbId: nil,
            tmdbId: nil
        )

        let response = try await client.submit(request, apiKey: "idb_submit")
        XCTAssertTrue(response.payload.ok)
        XCTAssertEqual(response.payload.submission.status, .pending)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("requestHandler is not set")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
