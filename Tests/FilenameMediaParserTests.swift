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

    func testParsesThreeDigitEpisodePattern() {
        let parsed = FilenameMediaParser.parse(rawName: "Dragon Ball - S01E001.mp4")

        XCTAssertEqual(parsed.title, "Dragon Ball")
        XCTAssertEqual(parsed.season, 1)
        XCTAssertEqual(parsed.episode, 1)
        XCTAssertEqual(parsed.mediaTypeHint, .tv)
    }

    func testParsesFourDigitEpisodePattern() {
        let parsed = FilenameMediaParser.parse(rawName: "One Piece - S01E1000.mp4")

        XCTAssertEqual(parsed.title, "One Piece")
        XCTAssertEqual(parsed.season, 1)
        XCTAssertEqual(parsed.episode, 1000)
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

    func testParsesLowercasePatternWithUnderscoresAndNoise() {
        let parsed = FilenameMediaParser.parse(rawName: "naruto_shippuden_s02e0007_1080p_x264.mkv")

        XCTAssertEqual(parsed.title, "naruto shippuden")
        XCTAssertEqual(parsed.season, 2)
        XCTAssertEqual(parsed.episode, 7)
        XCTAssertNil(parsed.year)
        XCTAssertEqual(parsed.mediaTypeHint, .tv)
    }

    func testParsesAlternateXPatternWithThreeDigitEpisode() {
        let parsed = FilenameMediaParser.parse(rawName: "Bleach.12x034.WEBDL")

        XCTAssertEqual(parsed.title, "Bleach")
        XCTAssertEqual(parsed.season, 12)
        XCTAssertEqual(parsed.episode, 34)
        XCTAssertNil(parsed.year)
        XCTAssertEqual(parsed.mediaTypeHint, .tv)
    }

    func testParsesTVAndRemovesBracketNoiseTokens() {
        let parsed = FilenameMediaParser.parse(rawName: "Attack.on.Titan.S03E22.[BluRay].mkv")

        XCTAssertEqual(parsed.title, "Attack on Titan")
        XCTAssertEqual(parsed.season, 3)
        XCTAssertEqual(parsed.episode, 22)
        XCTAssertNil(parsed.year)
        XCTAssertEqual(parsed.mediaTypeHint, .tv)
    }

    func testParsesTVWithYearAndReleaseTokens() {
        let parsed = FilenameMediaParser.parse(rawName: "Mr.Robot.S01E01.REPACK.2015.1080p")

        XCTAssertEqual(parsed.title, "Mr Robot")
        XCTAssertEqual(parsed.season, 1)
        XCTAssertEqual(parsed.episode, 1)
        XCTAssertEqual(parsed.year, 2015)
        XCTAssertEqual(parsed.mediaTypeHint, .tv)
    }

    func testParsesMovieWithManyReleaseTokens() {
        let parsed = FilenameMediaParser.parse(rawName: "Spirited.Away.2001.REMUX.2160p.HEVC")

        XCTAssertEqual(parsed.title, "Spirited Away")
        XCTAssertNil(parsed.season)
        XCTAssertNil(parsed.episode)
        XCTAssertEqual(parsed.year, 2001)
        XCTAssertEqual(parsed.mediaTypeHint, .movie)
    }
}
