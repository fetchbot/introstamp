import XCTest
@testable import IntroStamp

final class FilenameMediaParserTests: XCTestCase {
    func testParsesTVEpisodePattern() {
        let parsed = FilenameMediaParser.parse(rawName: "The.Last.of.Us.S01E10.2023.WEBRip.mkv")

        XCTAssertEqual(parsed.title, "The Last of Us")
        XCTAssertEqual(parsed.season, 1)
        XCTAssertEqual(parsed.episode, 10)
        XCTAssertEqual(parsed.year, 2023)
        XCTAssertEqual(parsed.mediaTypeHint, .tv)
    }

    func testParsesMovieAndStripsCommonNoiseTokens() {
        let parsed = FilenameMediaParser.parse(rawName: "Dune.Part.Two.2024.2160p.x265")

        XCTAssertEqual(parsed.title, "Dune Part Two")
        XCTAssertNil(parsed.season)
        XCTAssertNil(parsed.episode)
        XCTAssertEqual(parsed.year, 2024)
        XCTAssertEqual(parsed.mediaTypeHint, .movie)
    }
}
