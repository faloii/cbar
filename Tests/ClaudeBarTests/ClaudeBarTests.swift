import XCTest
@testable import ClaudeBar

final class FormatterTests: XCTestCase {
    func testTokenCompaction() {
        XCTAssertEqual(Fmt.tokens(999), "999")
        XCTAssertEqual(Fmt.tokens(1_000), "1.0K")
        XCTAssertEqual(Fmt.tokens(1_234), "1.2K")
        XCTAssertEqual(Fmt.tokens(120_000), "120K")
        XCTAssertEqual(Fmt.tokens(8_700_000), "8.7M")
        XCTAssertEqual(Fmt.tokens(1_500_000_000), "1.5B")
    }

    func testUSD() {
        XCTAssertEqual(Fmt.usd(12.5), "$12.50")
        XCTAssertEqual(Fmt.usd(0), "$0.00")
        XCTAssertEqual(Fmt.usd(150), "$150")
    }

    func testCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(2 * 3600 + 13 * 60), from: now), "2h 13m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(45 * 60), from: now), "45m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(10), from: now), "<1m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(-100), from: now), "<1m") // past
    }
}

final class ModelNameTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(ModelName.display("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelName.display("claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertEqual(ModelName.display("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelName.display("claude-fable-5"), "Fable 5")
        XCTAssertEqual(ModelName.display("some-unknown-model"), "some-unknown-model")
    }
}

final class PricingTests: XCTestCase {
    func testFamilyMatching() {
        XCTAssertEqual(Pricing.price(for: "claude-opus-4-8").input, 15)
        XCTAssertEqual(Pricing.price(for: "claude-sonnet-4-6").output, 15)
        XCTAssertEqual(Pricing.price(for: "claude-haiku-4-5").input, 1)
    }

    func testCostComputation() {
        // 1M input tokens of Opus = $15 exactly.
        let opus = TokenCounts(input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0)
        XCTAssertEqual(Pricing.cost(for: opus, model: "claude-opus-4-8"), 15, accuracy: 0.0001)

        // 1M output of Opus = $75.
        let out = TokenCounts(input: 0, output: 1_000_000, cacheWrite: 0, cacheRead: 0)
        XCTAssertEqual(Pricing.cost(for: out, model: "claude-opus-4-8"), 75, accuracy: 0.0001)

        // Unknown model uses the fallback (input $5/M).
        let unknown = TokenCounts(input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0)
        XCTAssertEqual(Pricing.cost(for: unknown, model: "mystery"), 5, accuracy: 0.0001)
    }
}

final class TokenCountsTests: XCTestCase {
    func testTotalAndAddition() {
        let a = TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)
        XCTAssertEqual(a.total, 10)
        let b = a + a
        XCTAssertEqual(b.input, 2)
        XCTAssertEqual(b.total, 20)
    }
}

final class OAuthUsageParseTests: XCTestCase {
    func testParsesISOWindows() {
        let json = """
        {"status":"allowed",
         "five_hour":{"utilization":42,"resets_at":"2026-06-12T05:09:59Z"},
         "seven_day":{"utilization":86.5,"resets_at":"2026-06-16T10:59:59Z"}}
        """.data(using: .utf8)!
        let snap = OAuthUsageClient.parse(json)
        XCTAssertNil(snap.error)
        XCTAssertTrue(snap.hasData)
        XCTAssertEqual(snap.status, "allowed")
        XCTAssertEqual(snap.session5h?.utilization, 42)
        XCTAssertEqual(snap.session5h?.fraction ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertNotNil(snap.session5h?.resetsAt)
        XCTAssertEqual(snap.weekly7d?.utilization ?? 0, 86.5, accuracy: 0.0001)
        XCTAssertNil(snap.weeklyOpus)
    }

    func testParsesOpusAndEpochReset() {
        let json = """
        {"five_hour":{"utilization":10,"resets_at":1781157378},
         "seven_day":{"utilization":20,"resets_at":"2026-06-16T10:59:59Z"},
         "seven_day_opus":{"utilization":33,"resets_at":"2026-06-16T10:59:59Z"}}
        """.data(using: .utf8)!
        let snap = OAuthUsageClient.parse(json)
        XCTAssertEqual(snap.weeklyOpus?.utilization, 33)
        XCTAssertNotNil(snap.session5h?.resetsAt) // epoch number parsed
    }

    func testFractionClampsAtFull() {
        let w = LimitWindow(utilization: 130, resetsAt: nil)
        XCTAssertEqual(w.fraction, 1.0, accuracy: 0.0001)
    }

    func testEmptyResponseIsError() {
        let snap = OAuthUsageClient.parse("{}".data(using: .utf8)!)
        XCTAssertFalse(snap.hasData)
        XCTAssertNotNil(snap.error)
    }
}
