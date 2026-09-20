import XCTest
@testable import IntroStamp

/// Integration tests that run the full recap detection pipeline against real SRT files.
/// SRT files are loaded from the Tests/ directory relative to this source file.
final class RecapDetectionIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func loadSRT(named filename: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let url = testsDir.appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func detectAndTighten(
        currentSRT: String,
        previousSRT: String
    ) -> [(startMs: Int, endMs: Int)] {
        let current = SRTParser.parse(currentSRT)
        let previous = SRTParser.parse(previousSRT)
        let raw = RecapDetector.detect(current: current, previous: previous)
        return RecapDetector.tighten(ranges: raw, current: current, previous: previous)
    }

    // MARK: - tt30146725 (S01E05 → S01E06)

    func testRecapDetection_S01E06_StartsAt2040msEndsAt27830ms() throws {
        let e5 = try loadSRT(named: "tt30146725_s1e5_en.srt")
        let e6 = try loadSRT(named: "tt30146725_s1e6_en.srt")

        let tightened = detectAndTighten(currentSRT: e6, previousSRT: e5)

        XCTAssertFalse(tightened.isEmpty, "Expected at least one recap range to be detected")

        // The opening dialogue (2040–27830 ms) is a direct replay of the previous episode's
        // closing scene — verify the tightened range covers that window exactly.
        let first = tightened[0]
        XCTAssertLessThanOrEqual(first.startMs, 2_040,
            "Recap should start at or before the first matching subtitle (2040 ms), got \(first.startMs)")
        XCTAssertGreaterThanOrEqual(first.endMs, 27_830,
            "Recap should end at or after the last matching subtitle (27830 ms), got \(first.endMs)")
    }

    func testRecapDetectorFindsEarlyRecapFromEpisode5ToEpisode6() throws {
        let previousContent = try loadSRT(named: "My.Instant.Death.Ability.is.Overpowered.S01E05.WEB.H264-KAWAII.en.srt")
        let currentContent = try loadSRT(named: "My Instant Death Ability Is Overpowered (2024) - s01e06.eng.srt")

        let previousEntries = SRTParser.parse(previousContent)
        let currentEntries = SRTParser.parse(currentContent)
        let matches = RecapDetector.detect(current: currentEntries, previous: previousEntries)

        XCTAssertFalse(matches.isEmpty, "Expected at least one recap match between E05 and E06")

        let hasEarlyMatch = matches.contains { range in
            range.startMs < 120_000 && range.endMs > 60_000
        }
        XCTAssertTrue(hasEarlyMatch, "Expected a recap match in the early part of episode 6")
    }

    func testRecapDetection_S01E06_DoesNotOverextendAround198s() throws {
        let e5 = try loadSRT(named: "tt30146725_s1e5_en.srt")
        let e6 = try loadSRT(named: "tt30146725_s1e6_en.srt")

        let tightened = detectAndTighten(currentSRT: e6, previousSRT: e5)
        XCTAssertFalse(tightened.isEmpty)

        // A short callback around 01:58 exists in both episodes, but it should not be
        // stretched into the subsequent non-recap dialogue up to 02:11.
        guard let around198 = tightened.first(where: { $0.startMs <= 118_160 && $0.endMs >= 118_160 }) else {
            XCTFail("Expected a tightened recap range covering 01:58.160")
            return
        }

        XCTAssertLessThanOrEqual(
            around198.endMs,
            124_500,
            "The 01:58 callback range should stay tight and not extend into the 02:11 dialogue"
        )
    }
}
