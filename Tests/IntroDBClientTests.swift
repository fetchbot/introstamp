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

        let client = IntroDBClient(baseURL: URL(string: "https://example.com/v2")!, session: makeSession())

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

        let client = IntroDBClient(baseURL: URL(string: "https://example.com/v2")!, session: makeSession())

        let request = IntroDBSubmissionRequest(
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
        } catch let error as IntroDBClientError {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertTrue(error.message.contains("duplicate"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
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
