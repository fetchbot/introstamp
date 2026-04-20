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

func swiftMediaType(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines) == "tv" ? ".tv" : ".movie"
}

func swiftSegmentType(_ raw: String) -> String {
    "." + raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
    case "setPlayhead":
        guard parts.count == 2 else { return "" }
        return "model.timeline.currentTimeMs = \(parts[1])"
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
    case "undo":
        return "model.undoSegmentChange()"
    case "redo":
        return "model.redoSegmentChange()"
    default:
        return ""
    }
}

func sanitizeTestName(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    return String(cleaned)
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
        let kind = row["kind"].trimmingCharacters(in: .whitespacesAndNewlines)

        if kind == "validator" {
            out.append("    func \(testName)() throws {")
            out.append("        let draft = SubmissionDraft(")
            out.append("            tmdbId: 123,")
            out.append("            imdbId: nil,")
            out.append("            mediaType: \(swiftMediaType(row["media_type"])),")
            out.append("            segment: \(swiftSegmentType(row["segment"])),")
            out.append("            season: \(swiftOptionalInt(row["season"])),")
            out.append("            episode: \(swiftOptionalInt(row["episode"])),")
            out.append("            startMs: \(swiftOptionalInt(row["start_ms"])),")
            out.append("            endMs: \(swiftOptionalInt(row["end_ms"]))")
            out.append("        )")
            if row["should_throw"].trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                out.append("        XCTAssertThrowsError(try SegmentValidator.makeSubmissionRequest(from: draft))")
            } else {
                out.append("        let request = try SegmentValidator.makeSubmissionRequest(from: draft)")
                let assertions = parseAssertions(row["assertions"])
                if let value = assertions["request_start"]?.first {
                    out.append("        XCTAssertEqual(request.startMs, \(swiftOptionalInt(value)))")
                }
                if let value = assertions["request_end"]?.first {
                    if value == "nil" {
                        out.append("        XCTAssertNil(request.endMs)")
                    } else {
                        out.append("        XCTAssertEqual(request.endMs, \(value))")
                    }
                }
            }
            out.append("    }")
            out.append("")
            continue
        }

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
