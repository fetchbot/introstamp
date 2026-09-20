#!/usr/bin/env swift
import Foundation

struct Row {
    let values: [String: String]

    subscript(_ key: String) -> String {
        values[key, default: ""]
    }
}

func parseCSV(_ text: String) -> [Row] {
    let lines = text.split(whereSeparator: \ .isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard let headerLine = lines.first else { return [] }

    func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" {
                if inQuotes {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" {
                        current.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if c == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i = line.index(after: i)
        }
        result.append(current)
        return result
    }

    let headers = splitCSVLine(headerLine)
    return lines.dropFirst().map { line in
        let fields = splitCSVLine(line)
        var dict: [String: String] = [:]
        for (idx, key) in headers.enumerated() {
            dict[key] = idx < fields.count ? fields[idx] : ""
        }
        return Row(values: dict)
    }
}

func swiftOptionalInt(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "nil" { return "nil" }
    return trimmed
}

func parseDraftSpec(_ spec: String) -> [String: [(String, String)]] {
    // intro=10000-20000|40000-50000;preview=3000-4000
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    var result: [String: [(String, String)]] = [:]
    for part in trimmed.split(separator: ";") {
        let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { continue }
        let seg = pair[0]
        let ranges = pair[1].split(separator: "|").map(String.init)
        var parsedRanges: [(String, String)] = []
        for range in ranges {
            let bounds = range.split(separator: "-", maxSplits: 1).map(String.init)
            guard bounds.count == 2 else { continue }
            parsedRanges.append((bounds[0], bounds[1]))
        }
        result[seg] = parsedRanges
    }
    return result
}

func makeDraftsLiteral(_ spec: String) -> String {
    let parsed = parseDraftSpec(spec)
    if parsed.isEmpty { return "[:]" }

    let keys = parsed.keys.sorted()
    let entries = keys.map { key -> String in
        let drafts = (parsed[key] ?? []).map { start, end in
            "SegmentDraft(startMs: \(swiftOptionalInt(start)), endMs: \(swiftOptionalInt(end)))"
        }.joined(separator: ", ")
        return ".\(key): [\(drafts)]"
    }
    return "[\(entries.joined(separator: ", "))]"
}

func parseAssertions(_ spec: String) -> [String: [String]] {
    var result: [String: [String]] = [:]
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return result }
    for token in trimmed.split(separator: ";").map(String.init) {
        let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { continue }
        result[pair[0], default: []].append(pair[1])
    }
    return result
}

func emitStep(_ step: String) -> String {
    let parts = step.split(separator: ":").map(String.init)
    guard let op = parts.first else { return "" }
    switch op {
    case "setTMDBID":
        guard parts.count == 2 else { return "" }
        return "model.tmdbIdText = \"\(parts[1])\""
    case "setMediaType":
        guard parts.count == 2 else { return "" }
        return "model.selectedMediaType = .\(parts[1])"
    case "setTMDBGenres":
        guard parts.count == 2 else { return "" }
        let genres = parts[1]
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        return "model.tmdbGenreNames = [\(genres)]"
    case "setPlayhead":
        guard parts.count == 2 else { return "" }
        return "model.timeline.currentTimeMs = \(parts[1])"
    case "setDetectedScenes":
        guard parts.count == 2 else { return "" }
        let timestamps = parts[1]
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let scenes = timestamps.enumerated().map { index, value in
            "SceneChange(index: \(index + 1), timestampMs: \(value), endTimestampMs: nil, score: 1.0, type: .hardCut)"
        }.joined(separator: ", ")
        return "model.detectedScenes = [\(scenes)]"
    case "setTemplateDuration":
        guard parts.count == 3 else { return "" }
        return "model.setTemplateDurationMs(\(parts[2]), for: .\(parts[1]))"
    case "setDraftStart":
        guard parts.count == 2 else { return "" }
        return "model.setDraftStart(.\(parts[1]))"
    case "setDraftEnd":
        guard parts.count == 2 else { return "" }
        return "model.setDraftEnd(.\(parts[1]))"
    case "setDraftRange":
        guard parts.count == 4 else { return "" }
        return "model.setDraftRange(.\(parts[1]), startMs: \(parts[2]), endMs: \(parts[3]))"
    case "moveDraft":
        guard parts.count == 6 else { return "" }
        return "model.moveDraft(.\(parts[1]), index: \(parts[2]), to: .\(parts[3]), startMs: \(parts[4]), endMs: \(parts[5]))"
    case "clearDraft":
        guard parts.count == 2 else { return "" }
        return "model.clearDraft(.\(parts[1]))"
    case "moveNearestSegmentEnd":
        return "model.moveNearestSegmentEndToPlayhead()"
    case "jumpToNextStart":
        guard parts.count == 2 else { return "" }
        return "model.jumpToNextStart(.\(parts[1]))"
    case "jumpToNextEnd":
        guard parts.count == 2 else { return "" }
        return "model.jumpToNextEnd(.\(parts[1]))"
    case "jumpToNextScene":
        return "model.jumpToNextScene()"
    case "jumpToPreviousScene":
        return "model.jumpToPreviousScene()"
    case "nudgeBoundary":
        guard parts.count == 2 else { return "" }
        return "model.nudgeNearestBoundary(by: \(parts[1]))"
    case "undo":
        return "model.undoSegmentChange()"
    case "redo":
        return "model.redoSegmentChange()"
    case "setAutoRecapKeys":
        guard parts.count == 2 else { return "" }
        let keys = parts[1]
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        return "model.autoRecapDraftKeys = [\(keys)]"
    case "setAutoRecapDrafts":
        guard parts.count == 2 else { return "" }
        let ranges = parts[1]
            .split(separator: "|")
            .map(String.init)
        let tuples = ranges.compactMap { range -> String? in
            let bounds = range.split(separator: "-", maxSplits: 1).map(String.init)
            guard bounds.count == 2 else { return nil }
            return "(startMs: \(bounds[0]), endMs: \(bounds[1]))"
        }.joined(separator: ", ")
        return "model.localDrafts[.recap] = model.autoRecapDrafts(from: [\(tuples)])"
    default:
        return ""
    }
}

func sanitizeTestName(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    return String(cleaned)
}

func scenePresetExpression(from rawValue: String) -> String {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "anime":
        return ".anime"
    case "liveaction":
        return ".liveAction"
    case "dark-liveaction":
        return ".darkLiveAction"
    case "sports":
        return ".sports"
    default:
        return ".standard"
    }
}

func generate(rows: [Row]) -> String {
    var out: [String] = []
    out.append("import XCTest")
    out.append("@testable import IntroStamp")
    out.append("")
    out.append("// Generated from Tests/segment_scenarios.csv via scripts/generate_segment_tests.swift")
    out.append("final class GeneratedSegmentScenarioTests: XCTestCase {")

    for row in rows {
        let testName = sanitizeTestName(row["test_name"])

        out.append("    @MainActor")
        out.append("    func \(testName)() {")
        out.append("        let model = makeModel(drafts: \(makeDraftsLiteral(row["initial_drafts"])))")

        let steps = row["steps"].split(separator: ">").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for step in steps {
            let line = emitStep(step)
            if !line.isEmpty {
                out.append("        \(line)")
            }
        }

        let assertions = parseAssertions(row["assertions"])
        if let containsEntries = assertions["contains"] {
            for entry in containsEntries {
                for chunk in entry.split(separator: "|").map(String.init) {
                    let pair = chunk.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { continue }
                    let bounds = pair[1].split(separator: "-", maxSplits: 1).map(String.init)
                    guard bounds.count == 2 else { continue }
                    out.append("        assertDraftExists(in: model.drafts(for: .\(pair[0])), start: \(swiftOptionalInt(bounds[0])), end: \(swiftOptionalInt(bounds[1])))")
                }
            }
        }

        if let notContainsEntries = assertions["not_contains"] {
            for entry in notContainsEntries {
                for chunk in entry.split(separator: "|").map(String.init) {
                    let pair = chunk.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { continue }
                    let bounds = pair[1].split(separator: "-", maxSplits: 1).map(String.init)
                    guard bounds.count == 2 else { continue }
                    out.append("        XCTAssertFalse(model.drafts(for: .\(pair[0])).contains(where: { $0.startMs == \(swiftOptionalInt(bounds[0])) && $0.endMs == \(swiftOptionalInt(bounds[1])) }))")
                }
            }
        }

        if let countEntries = assertions["count"] {
            for entry in countEntries {
                let pair = entry.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                out.append("        XCTAssertEqual(model.drafts(for: .\(pair[0])).count, \(pair[1]))")
            }
        }

        if let emptyEntries = assertions["empty"] {
            for entry in emptyEntries {
                for seg in entry.split(separator: "|").map(String.init) {
                    out.append("        XCTAssertTrue(model.drafts(for: .\(seg)).isEmpty)")
                }
            }
        }

        if let values = assertions["error_non_empty"], values.first == "true" {
            out.append("        XCTAssertFalse(model.errorMessage.isEmpty)")
        }
        if let values = assertions["can_undo"], let first = values.first {
            out.append("        XCTAssertEqual(model.canUndoSegmentChange, \(first))")
        }
        if let values = assertions["can_redo"], let first = values.first {
            out.append("        XCTAssertEqual(model.canRedoSegmentChange, \(first))")
        }
        if let values = assertions["playhead"], let first = values.first {
            out.append("        XCTAssertEqual(model.timeline.currentTimeMs, \(first))")
        }

        if let values = assertions["scene_preset"], let first = values.first {
            out.append("        XCTAssertEqual(SceneDetector.Config.inferredPreset(from: model.tmdbGenreNames, mediaType: model.selectedMediaType), \(scenePresetExpression(from: first)))")
        }

        if let values = assertions["scene_count"], let first = values.first {
            out.append("        XCTAssertEqual(model.detectedScenes.count, \(first))")
        }

        if let containsEntries = assertions["uploadable_contains"] {
            for entry in containsEntries {
                for chunk in entry.split(separator: "|").map(String.init) {
                    let pair = chunk.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { continue }
                    let bounds = pair[1].split(separator: "-", maxSplits: 1).map(String.init)
                    guard bounds.count == 2 else { continue }
                    out.append("        assertDraftExists(in: model.uploadableDrafts(for: .\(pair[0])), start: \(swiftOptionalInt(bounds[0])), end: \(swiftOptionalInt(bounds[1])))")
                }
            }
        }

        if let notContainsEntries = assertions["uploadable_not_contains"] {
            for entry in notContainsEntries {
                for chunk in entry.split(separator: "|").map(String.init) {
                    let pair = chunk.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { continue }
                    let bounds = pair[1].split(separator: "-", maxSplits: 1).map(String.init)
                    guard bounds.count == 2 else { continue }
                    out.append("        XCTAssertFalse(model.uploadableDrafts(for: .\(pair[0])).contains(where: { $0.startMs == \(swiftOptionalInt(bounds[0])) && $0.endMs == \(swiftOptionalInt(bounds[1])) }))")
                }
            }
        }

        if let countEntries = assertions["uploadable_count"] {
            for entry in countEntries {
                let pair = entry.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                out.append("        XCTAssertEqual(model.uploadableDrafts(for: .\(pair[0])).count, \(pair[1]))")
            }
        }

        out.append("    }")
        out.append("")
    }

    out.append("    // MARK: - Helpers")
    out.append("")
    out.append("    @MainActor")
    out.append("    private func makeModel(drafts: [SegmentType: [SegmentDraft]]) -> AppModel {")
    out.append("        let model = AppModel()")
    out.append("        for (segment, segmentDrafts) in drafts {")
    out.append("            model.localDrafts[segment] = segmentDrafts")
    out.append("        }")
    out.append("        return model")
    out.append("    }")
    out.append("")
    out.append("    private func assertDraftExists(in drafts: [SegmentDraft], start: Int?, end: Int?) {")
    out.append("        XCTAssertTrue(drafts.contains(where: { $0.startMs == start && $0.endMs == end }))")
    out.append("    }")
    out.append("}")

    return out.joined(separator: "\n")
}

let fileManager = FileManager.default
let repoRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let csvURL = repoRoot.appendingPathComponent("Tests/segment_scenarios.csv")
let outputURL = repoRoot.appendingPathComponent("Tests/GeneratedSegmentScenarioTests.swift")

let csvText = try String(contentsOf: csvURL, encoding: .utf8)
let rows = parseCSV(csvText)
let generated = generate(rows: rows)
try generated.write(to: outputURL, atomically: true, encoding: .utf8)
print("Generated \(outputURL.path) from \(csvURL.path) with \(rows.count) scenario(s).")
