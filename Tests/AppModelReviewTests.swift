import Foundation
import XCTest
@testable import IntroStamp

final class AppModelReviewTests: XCTestCase {
    override func tearDown() {
        ReviewMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testListReviewNoSegmentFlagsRemainPerEpisode() {
        let model = AppModel(shouldAccessKeychain: false)
        model.appMode = .listReview

        var first = Self.makeReviewItem(tmdbId: 9876, season: 1, episode: 1)
        first.noSegmentFlags = [.intro: true]
        let second = Self.makeReviewItem(tmdbId: 9876, season: 1, episode: 2)

        model.reviewListItems = [first, second]

        model.selectReviewListItem(first.id)
        XCTAssertEqual(model.noSegmentFlags[.intro], true)

        model.selectReviewListItem(second.id)
        XCTAssertEqual(model.noSegmentFlags[.intro], false)

        model.setNoSegment(.recap, enabled: true)

        let updatedFirst = model.reviewListItems.first(where: { $0.id == first.id })
        let updatedSecond = model.reviewListItems.first(where: { $0.id == second.id })

        XCTAssertEqual(updatedFirst?.noSegmentFlags[.recap] ?? false, false)
        XCTAssertEqual(updatedSecond?.noSegmentFlags[.recap] ?? false, true)

        model.selectReviewListItem(first.id)
        XCTAssertEqual(model.noSegmentFlags[.intro], true)
        XCTAssertEqual(model.noSegmentFlags[.recap], false)
    }

    func testGroupKey_TVPrefersTMDBAndIgnoresIMDbMismatch() {
        var withoutIMDb = Self.makeReviewItem(tmdbId: 96402, season: 1, episode: 1)
        withoutIMDb.imdbId = nil

        var withIMDb = Self.makeReviewItem(tmdbId: 96402, season: 2, episode: 1)
        withIMDb.imdbId = "tt11428630"

        XCTAssertEqual(withoutIMDb.groupKey, withIMDb.groupKey)
    }

    func testSubmitReviewGroup_UploadsNoSegmentOnlyForFlaggedEpisode() async throws {
        struct CapturedSubmit {
            var season: Int?
            var episode: Int?
            var keys: Set<String>
            var segment: String?
        }

        let lock = NSLock()
        var capturedSubmissions: [CapturedSubmit] = []

        ReviewMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-123")
            XCTAssertEqual(request.url?.path, "/v3/submit")

            guard let body = Self.requestBodyData(from: request),
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            else {
                XCTFail("Expected JSON body")
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, Data("{}".utf8))
            }

            let captured = CapturedSubmit(
                season: json["season"] as? Int,
                episode: json["episode"] as? Int,
                keys: Set(json.keys),
                segment: json["segment"] as? String
            )

            lock.withLock {
                capturedSubmissions.append(captured)
            }

            let data = Data(#"{"submissions":[{"id":"550e8400-e29b-41d4-a716-446655440000","tmdbId":9876,"type":"tv","segment":"intro","season":1,"episode":1,"status":"pending","weight":1}]}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let client = TheIntroDBClient(baseURL: URL(string: "https://example.com/v3")!, session: makeSession())
        let firstGroupKey = "tv|tmdb|9876"
        let model = await MainActor.run { () -> AppModel in
            let model = AppModel(theIntroDBClient: client, shouldAccessKeychain: false)
            model.appMode = .listReview
            model.theIntroDBAPIKey = "key-123"

            var first = Self.makeReviewItem(tmdbId: 9876, season: 1, episode: 1)
            first.noSegmentFlags = [.intro: true]
            let second = Self.makeReviewItem(tmdbId: 9876, season: 1, episode: 2)

            model.reviewListItems = [first, second]
            return model
        }

        await model.submitReviewGroup(firstGroupKey)

        let submissions = lock.withLock { capturedSubmissions }

        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.season, 1)
        XCTAssertEqual(submissions.first?.episode, 1)
        XCTAssertEqual(submissions.first?.segment, "intro")
        XCTAssertEqual(submissions.first?.keys, Set([
            "tmdb_id", "type", "segment", "season", "episode",
            "start_ms", "end_ms", "video_duration_ms", "imdb_id"
        ]))
    }

    @MainActor
    func testImportReviewFiles_TVAddsMissingEpisodesFromTMDB() async throws {
        let session = makeSession()
        let theIntro = TheIntroDBClient(baseURL: URL(string: "https://example.com/v3")!, session: session)
        let tmdb = TMDBClient(baseURL: URL(string: "https://tmdb.example/3")!, session: session)

        ReviewMockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.host == "tmdb.example", url.path == "/3/tv/9876" {
                let json = #"{"name":"Demo Series","poster_path":"/poster.jpg","episode_run_time":[24],"seasons":[{"season_number":0,"episode_count":2},{"season_number":1,"episode_count":3}]}"#
                let data = Data(json.utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }

            if url.host == "example.com", url.path == "/v3/media" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let season = Self.intQueryItem(named: "season", in: components)
                let episode = Self.intQueryItem(named: "episode", in: components)
                let listVersions = Self.stringQueryItem(named: "list_versions", in: components)

                if listVersions == "true" {
                    let data = Data(#"{"versions":[{"duration_ms":1440000,"submission_count":1}]}"#.utf8)
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, data)
                }

                if season == 1, episode == 1 {
                    let data = Data(#"{"tmdb_id":9876,"type":"tv","season":1,"episode":1,"duration_ms":1440000,"intro":[{"start_ms":1000,"end_ms":90000}],"recap":[],"credits":[],"preview":[]}"#.utf8)
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, data)
                }

                let data = Data(#"{"error":"not found"}"#.utf8)
                let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }

            throw URLError(.unsupportedURL)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-import-")
            .appendingPathExtension("json")
        let importPayload = #"[{"tmdb_id":9876,"type":"tv","season":1,"episode":1,"segment":"intro","start_ms":1000,"end_ms":90000}]"#
        try Data(importPayload.utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let model = AppModel(
            theIntroDBClient: theIntro,
            tmdbClient: tmdb,
            shouldAccessKeychain: false
        )
        model.appMode = .listReview
        model.tmdbAPIKey = "tmdb-key"

        await model.importReviewFiles(urls: [tempURL])

        let episodes = model.reviewListItems
            .filter { $0.tmdbId == 9876 && $0.mediaType == .tv && $0.season == 1 }
            .compactMap(\.episode)
            .sorted()

        let specialEpisodes = model.reviewListItems
            .filter { $0.tmdbId == 9876 && $0.mediaType == .tv && $0.season == 0 }
            .compactMap(\.episode)
            .sorted()

        XCTAssertEqual(episodes, [1, 2, 3])
        XCTAssertEqual(specialEpisodes, [1, 2])
    }

    func testSubmitReviewListItem_UsesNoSegmentAndNormalSegmentsPerItem() async throws {
        struct CapturedSubmit {
            var segment: String?
            var season: Int?
            var episode: Int?
            var startMs: Int?
            var endMs: Int?
            var keys: Set<String>
        }

        let lock = NSLock()
        var capturedSubmissions: [CapturedSubmit] = []

        ReviewMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-123")
            XCTAssertEqual(request.url?.path, "/v3/submit")

            guard let body = Self.requestBodyData(from: request),
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            else {
                XCTFail("Expected JSON body")
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, Data("{}".utf8))
            }

            let captured = CapturedSubmit(
                segment: json["segment"] as? String,
                season: json["season"] as? Int,
                episode: json["episode"] as? Int,
                startMs: json["start_ms"] as? Int,
                endMs: json["end_ms"] as? Int,
                keys: Set(json.keys)
            )

            lock.withLock {
                capturedSubmissions.append(captured)
            }

            let data = Data(#"{"submissions":[{"id":"550e8400-e29b-41d4-a716-446655440000","tmdbId":9876,"type":"tv","segment":"intro","season":1,"episode":1,"status":"pending","weight":1}]}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let client = TheIntroDBClient(baseURL: URL(string: "https://example.com/v3")!, session: makeSession())
        let itemID = "tv|9876|tt-demo|1|1"

        let model = await MainActor.run { () -> AppModel in
            let model = AppModel(theIntroDBClient: client, shouldAccessKeychain: false)
            model.appMode = .listReview
            model.theIntroDBAPIKey = "key-123"

            var item = Self.makeReviewItem(tmdbId: 9876, season: 1, episode: 1)
            item.noSegmentFlags = [.intro: true]
            item.draftSegmentGroups = [
                .recap: [SegmentRange(startMs: 120_000, endMs: 180_000)]
            ]
            item.draftSegments = [
                .recap: SegmentRange(startMs: 120_000, endMs: 180_000)
            ]

            model.reviewListItems = [item]
            return model
        }

        await model.submitReviewListItem(itemID)

        let submissions = lock.withLock { capturedSubmissions }
        XCTAssertEqual(submissions.count, 2)

        let intro = submissions.first(where: { $0.segment == "intro" })
        XCTAssertEqual(intro?.season, 1)
        XCTAssertEqual(intro?.episode, 1)
        XCTAssertEqual(intro?.keys, Set([
            "tmdb_id", "type", "segment", "season", "episode",
            "start_ms", "end_ms", "video_duration_ms", "imdb_id"
        ]))
        XCTAssertEqual(intro?.startMs, 0)
        XCTAssertEqual(intro?.endMs, 0)

        let recap = submissions.first(where: { $0.segment == "recap" })
        XCTAssertEqual(recap?.season, 1)
        XCTAssertEqual(recap?.episode, 1)
        XCTAssertEqual(recap?.keys, Set([
            "tmdb_id", "type", "segment", "season", "episode",
            "start_ms", "end_ms", "video_duration_ms", "imdb_id"
        ]))
        XCTAssertEqual(recap?.startMs, 120_000)
        XCTAssertEqual(recap?.endMs, 180_000)
    }

    @MainActor
    func testImportReviewFiles_ZeroStartAndEndMsImportsAsNoSegment() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zero-segment-import-")
            .appendingPathExtension("json")
        let importPayload = """
        {"ok":true,"submissions":[
            {"id":"sub-1","tmdbId":196950,"type":"tv","segment":"intro","season":1,"episode":1,"videoDurationMs":1420083,"startMs":0,"endMs":0,"status":"pending"},
            {"id":"sub-2","tmdbId":196950,"type":"tv","segment":"credits","season":1,"episode":1,"videoDurationMs":1420083,"startMs":0,"endMs":0,"status":"pending"},
            {"id":"sub-3","tmdbId":196950,"type":"tv","segment":"preview","season":1,"episode":1,"videoDurationMs":1420083,"startMs":1415083,"endMs":null,"status":"pending"}
        ]}
        """
        try Data(importPayload.utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let model = AppModel(shouldAccessKeychain: false)
        model.appMode = .listReview

        await model.importReviewFiles(urls: [tempURL])

        XCTAssertEqual(model.reviewListItems.count, 1)
        guard let item = model.reviewListItems.first else {
            XCTFail("Expected 1 review list item")
            return
        }

        XCTAssertEqual(item.noSegmentFlags[.intro], true)
        XCTAssertEqual(item.noSegmentFlags[.credits], true)
        XCTAssertEqual(item.noSegmentFlags[.preview], false)

        XCTAssertEqual(item.draftSegmentGroups[.intro]?.isEmpty ?? true, true)
        XCTAssertEqual(item.draftSegmentGroups[.credits]?.isEmpty ?? true, true)
        XCTAssertEqual(item.draftSegmentGroups[.preview]?.first?.startMs, 1415083)

        model.selectReviewListItem(item.id)
        XCTAssertEqual(model.noSegmentFlags[.intro], true)
        XCTAssertEqual(model.noSegmentFlags[.credits], true)
        XCTAssertEqual(model.noSegmentFlags[.preview], false)
    }

    private static func makeReviewItem(tmdbId: Int, season: Int, episode: Int) -> ListReviewItem {
        ListReviewItem(
            identityKey: "tv|\(tmdbId)|tt-demo|\(season)|\(episode)",
            title: "Series \(tmdbId)",
            mediaType: .tv,
            tmdbId: tmdbId,
            imdbId: "tt-demo",
            season: season,
            episode: episode,
            posterURL: nil,
            videoDurationMs: 1_800_000,
            sourceLabel: "Test",
            segments: [:],
            segmentGroups: [:],
            draftSegments: [:],
            draftSegmentGroups: [:],
            noSegmentFlags: [:],
            submitMessage: nil,
            isSubmitting: false
        )
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func requestBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                return nil
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data.isEmpty ? nil : data
    }

    private static func intQueryItem(named name: String, in components: URLComponents?) -> Int? {
        guard let value = stringQueryItem(named: name, in: components) else { return nil }
        return Int(value)
    }

    private static func stringQueryItem(named name: String, in components: URLComponents?) -> String? {
        components?.queryItems?.first(where: { $0.name == name })?.value
    }
}

private final class ReviewMockURLProtocol: URLProtocol {
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
