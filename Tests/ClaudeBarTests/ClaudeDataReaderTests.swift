import XCTest
@testable import ClaudeBar

/// Exercises the real data path end-to-end against a throwaway CLAUDE_CONFIG_DIR
/// containing a crafted stats-cache + session log.
final class ClaudeDataReaderTests: XCTestCase {
    private var configDir: URL!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private func ts(_ offset: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(offset)) }

    override func setUpWithError() throws {
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudebartest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let stats: [String: Any] = [
            "version": 4,
            "totalSessions": 42,
            "totalMessages": 1000,
            "firstSessionDate": "2026-02-07T00:00:00.000Z",
            "modelUsage": ["claude-opus-4-8": ["inputTokens": 0, "outputTokens": 1_000_000,
                                               "cacheCreationInputTokens": 0, "cacheReadInputTokens": 0]],
            "dailyModelTokens": [["date": "2026-06-10", "tokensByModel": ["claude-opus-4-8": 1_000_000]]],
        ]
        try JSONSerialization.data(withJSONObject: stats)
            .write(to: configDir.appendingPathComponent("stats-cache.json"))

        let proj = configDir.appendingPathComponent("projects/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)

        func assistant(_ offset: TimeInterval, _ model: String, in input: Int, out output: Int, cacheRead: Int) -> Data {
            let obj: [String: Any] = [
                "type": "assistant", "timestamp": ts(offset), "sessionId": "s1",
                "message": ["model": model, "usage": [
                    "input_tokens": input, "output_tokens": output,
                    "cache_creation_input_tokens": 0, "cache_read_input_tokens": cacheRead]],
            ]
            return try! JSONSerialization.data(withJSONObject: obj)
        }
        var lines: [Data] = [
            assistant(-3600, "claude-opus-4-8", in: 100, out: 200, cacheRead: 1000),   // 1h ago, in window
            assistant(-7200, "claude-sonnet-4-6", in: 50, out: 50, cacheRead: 500),    // 2h ago, in window
            assistant(-20 * 3600, "claude-opus-4-8", in: 9_000_000, out: 0, cacheRead: 0), // 20h ago, OUT of window
        ]
        let userObj: [String: Any] = ["type": "user", "timestamp": ts(-3600), "sessionId": "s1"]
        lines.append(try! JSONSerialization.data(withJSONObject: userObj))

        let blob = lines.map { String(data: $0, encoding: .utf8)! }.joined(separator: "\n")
        try blob.write(to: proj.appendingPathComponent("sess.jsonl"), atomically: true, encoding: .utf8)

        setenv("CLAUDE_CONFIG_DIR", configDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CLAUDE_CONFIG_DIR")
        try? FileManager.default.removeItem(at: configDir)
    }

    func testWindowAggregationFromLogs() {
        let snap = ClaudeDataReader().load(now: now)
        // Only the two in-window assistant turns count: (100+200+1000) + (50+50+500) = 1900.
        XCTAssertEqual(snap.windowTokens.total, 1900)
        XCTAssertEqual(snap.windowByModel.count, 2)
        XCTAssertEqual(snap.windowByModel.first?.model, "Opus 4.8")   // sorted by tokens desc
        XCTAssertEqual(snap.windowByModel.first?.tokens.total, 1300)
        XCTAssertGreaterThan(snap.windowCost, 0)
    }

    func testStatsCacheParsed() {
        let snap = ClaudeDataReader().load(now: now)
        XCTAssertEqual(snap.totalSessions, 42)
        XCTAssertEqual(snap.totalMessages, 1000)
        XCTAssertNotNil(snap.firstSessionDate)
    }

    func testDailyCostEstimated() {
        let snap = ClaudeDataReader().load(now: now)
        XCTAssertEqual(snap.dailyCostHistory.count, 1)
        // 1M opus tokens at the blended lifetime rate ($75 / 1M output) ≈ $75.
        XCTAssertEqual(snap.dailyCostHistory.first?.tokens, 1_000_000)
        XCTAssertEqual(snap.dailyCostHistory.first?.cost ?? 0, 75, accuracy: 0.5)
    }
}
