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

final class ProjectionTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_000_000)
    func mins(_ m: Double) -> Date { t.addingTimeInterval(m * 60) }

    func testMeasuringWithOnePoint() {
        let p = Projection.compute(points: [(t, 50)], resetsAt: t.addingTimeInterval(4 * 3600), now: t)
        XCTAssertEqual(p.verdict, .measuring)
    }

    func testIdleWhenFlat() {
        let p = Projection.compute(points: [(mins(-30), 50), (t, 50)], resetsAt: t.addingTimeInterval(4 * 3600), now: t)
        XCTAssertEqual(p.verdict, .idle)
        XCTAssertNil(p.timeToFull)
    }

    func testSafeWhenResetBeatsExhaustion() {
        // 52→56 over 30m = 8%/h; 44 remaining → ~5.5h to full > 4h reset → safe.
        let p = Projection.compute(points: [(mins(-30), 52), (t, 56)], resetsAt: t.addingTimeInterval(4 * 3600), now: t)
        XCTAssertEqual(p.verdict, .safe)
        XCTAssertEqual(p.ratePerHour, 8, accuracy: 0.01)
        XCTAssertNil(p.blockedBy)
    }

    func testAtRiskWhenBurningFast() {
        // 60→78 over 30m = 36%/h; 22 remaining → ~37m to full ≪ 4h reset → at risk.
        let p = Projection.compute(points: [(mins(-30), 60), (t, 78)], resetsAt: t.addingTimeInterval(4 * 3600), now: t)
        XCTAssertEqual(p.verdict, .atRisk)
        XCTAssertEqual(p.ratePerHour, 36, accuracy: 0.01)
        XCTAssertNotNil(p.timeToFull)
        XCTAssertGreaterThan(p.blockedBy ?? 0, 0)
    }

    func testPacedSafeWhenUnderPace() {
        // 10% used, 2 days into a 7-day week → ~432h to full ≫ 5d reset → safe.
        let week: TimeInterval = 7 * 24 * 3600
        let p = Projection.paced(util: 10, resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                                 windowSeconds: week, now: now)
        XCTAssertEqual(p.verdict, .safe)
        XCTAssertLessThan(p.ratePerHour, 1)   // realized pace is small, not a burst
    }

    func testPacedAtRiskWhenAheadOfPace() {
        // 60% used only 2 days in → on track to blow the week → at risk.
        let week: TimeInterval = 7 * 24 * 3600
        let p = Projection.paced(util: 60, resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                                 windowSeconds: week, now: now)
        XCTAssertEqual(p.verdict, .atRisk)
    }

    func testPacedTooEarlyStaysSafe() {
        // Only 3h into the week — too early to project a pace.
        let week: TimeInterval = 7 * 24 * 3600
        let p = Projection.paced(util: 40, resetsAt: now.addingTimeInterval(week - 3 * 3600),
                                 windowSeconds: week, now: now)
        XCTAssertEqual(p.verdict, .safe)
    }

    func testResetBoundaryIgnoresPreDropSamples() {
        // A reset (95→10) means the slope must come from the post-reset rise (10→20),
        // not the overall negative trend — i.e. a positive burn, not idle.
        let pts: [(Date, Double)] = [(mins(-40), 90), (mins(-20), 95), (mins(-15), 10), (mins(-5), 20)]
        let p = Projection.compute(points: pts, resetsAt: t.addingTimeInterval(5 * 3600), now: t)
        XCTAssertEqual(p.verdict, .atRisk)
        XCTAssertGreaterThan(p.ratePerHour, 30)
    }
}

final class ModelBurnTests: XCTestCase {
    private func model(_ name: String, total: Int, requests: Int, cost: Double = 0) -> ModelWindowUsage {
        ModelWindowUsage(model: name, tokens: TokenCounts(cacheRead: total), cost: cost, requests: requests)
    }

    func testTotalTokenBasis() {
        // Opus 800k/8 = 100k/turn; Fable 200k/4 = 50k/turn → Opus is 2× the lightest.
        let window = [model("Opus", total: 800_000, requests: 8),
                      model("Fable", total: 200_000, requests: 4)]
        let rows = ModelBurn.rows(window: window, sessionUtil: 50, basis: .totalTokens)

        let opus = rows.first { $0.model == "Opus" }!
        let fable = rows.first { $0.model == "Fable" }!

        XCTAssertEqual(rows.first?.model, "Opus") // sorted by weight desc
        XCTAssertEqual(opus.shareFraction, 0.8, accuracy: 0.001)
        XCTAssertEqual(opus.perTurnWeight, 100_000, accuracy: 1)
        XCTAssertEqual(opus.burnMultiplier, 2.0, accuracy: 0.001)
        XCTAssertEqual(fable.burnMultiplier, 1.0, accuracy: 0.001)

        // util 50% → remaining ≈ total (1M). Opus: 1M/100k = 10 turns; Fable: 1M/50k = 20.
        XCTAssertEqual(opus.headroomTurns ?? 0, 10, accuracy: 0.1)
        XCTAssertEqual(fable.headroomTurns ?? 0, 20, accuracy: 0.1)
    }

    func testCostBasisChangesShareAndMultiplier() {
        // Equal tokens, but Opus costs far more → cost basis reorders & re-weights.
        let window = [model("Opus", total: 500_000, requests: 5, cost: 300),
                      model("Fable", total: 500_000, requests: 5, cost: 60)]
        let rows = ModelBurn.rows(window: window, sessionUtil: nil, basis: .cost)

        let opus = rows.first { $0.model == "Opus" }!
        let fable = rows.first { $0.model == "Fable" }!
        XCTAssertEqual(rows.first?.model, "Opus")                 // higher cost share first
        XCTAssertEqual(opus.shareFraction, 300.0 / 360.0, accuracy: 0.001)
        XCTAssertEqual(opus.perTurnWeight, 60, accuracy: 0.001)   // $300 / 5 turns
        XCTAssertEqual(opus.burnMultiplier, 5.0, accuracy: 0.001) // $60/turn vs $12/turn
    }

    func testFreshTokenBasisExcludesCacheReads() {
        let m = ModelWindowUsage(model: "Opus",
                                 tokens: TokenCounts(input: 10, output: 20, cacheWrite: 30, cacheRead: 940),
                                 cost: 0, requests: 1)
        let rows = ModelBurn.rows(window: [m], sessionUtil: nil, basis: .freshTokens)
        XCTAssertEqual(rows.first!.perTurnWeight, 60, accuracy: 0.001) // 10+20+30, cacheRead excluded
    }

    func testNoHeadroomWithoutUtilization() {
        let rows = ModelBurn.rows(window: [model("Opus", total: 100, requests: 1)],
                                  sessionUtil: nil, basis: .totalTokens)
        XCTAssertNil(rows.first?.headroomTurns)
    }

    func testEmptyWindow() {
        XCTAssertTrue(ModelBurn.rows(window: [], sessionUtil: 50, basis: .totalTokens).isEmpty)
    }
}

final class CostEstimatorTests: XCTestCase {
    func testBlendedRateMatchesPricing() {
        // 1M Opus output → $75 → blended $75/1M = 0.000075 $/token.
        let usage = ["claude-opus-4-8": TokenCounts(output: 1_000_000)]
        let (rates, fallback) = CostEstimator.blendedRates(usage)
        XCTAssertEqual(rates["claude-opus-4-8"] ?? 0, 75.0 / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(fallback, 75.0 / 1_000_000, accuracy: 1e-12)
    }

    func testDailyCostUsesPerModelRatesAndFallback() {
        let rates = ["claude-opus-4-8": 0.00007, "claude-sonnet-4-6": 0.00001]
        // Opus 1M*0.00007=70 + Sonnet 2M*0.00001=20 + unknown 1M*fallback(0.0001)=100 → 190.
        let day = ["claude-opus-4-8": 1_000_000, "claude-sonnet-4-6": 2_000_000, "mystery": 1_000_000]
        let cost = CostEstimator.dailyCost(tokensByModel: day, rates: rates, fallback: 0.0001)
        XCTAssertEqual(cost, 190, accuracy: 1e-6)
    }

    func testEmptyUsageGivesZeroFallback() {
        let (rates, fallback) = CostEstimator.blendedRates([:])
        XCTAssertTrue(rates.isEmpty)
        XCTAssertEqual(fallback, 0)
    }
}

final class BudgetTests: XCTestCase {
    func testMonthToDateAndProjection() {
        // now = 2026-06-15 (day 15 of a 30-day month).
        var comps = DateComponents(); comps.year = 2026; comps.month = 6; comps.day = 15
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: comps)!
        let history = [
            DailyCost(date: "2026-05-31", tokens: 0, cost: 99),   // previous month — excluded
            DailyCost(date: "2026-06-05", tokens: 0, cost: 30),
            DailyCost(date: "2026-06-10", tokens: 0, cost: 30),
        ]
        let s = Budget.status(history: history, now: now, budget: 200, calendar: cal)
        XCTAssertEqual(s.monthToDate, 60, accuracy: 0.001)        // 30 + 30, May excluded
        XCTAssertEqual(s.projected, 60.0 / 15 * 30, accuracy: 0.001)  // = 120
        XCTAssertEqual(s.fraction, 60.0 / 200, accuracy: 0.001)
        XCTAssertFalse(s.projectedOver)                          // 120 < 200
    }

    func testProjectedOver() {
        var comps = DateComponents(); comps.year = 2026; comps.month = 6; comps.day = 10
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: comps)!
        let history = [DailyCost(date: "2026-06-09", tokens: 0, cost: 100)]
        let s = Budget.status(history: history, now: now, budget: 150, calendar: cal)
        XCTAssertTrue(s.projectedOver)   // 100/10*30 = 300 > 150
    }
}

final class AdviceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    private func model(_ name: String, total: Int, requests: Int, cost: Double) -> ModelWindowUsage {
        ModelWindowUsage(model: name, tokens: TokenCounts(cacheRead: total), cost: cost, requests: requests)
    }

    func testReductionPercent() {
        // full in 900s, reset in 3600s → cut 75% to last to reset.
        let p = Projection(ratePerHour: 40, timeToFull: 900, secondsToReset: 3600, verdict: .atRisk)
        XCTAssertEqual(Advice.reductionPercent(p), 75)
    }

    func testAtRiskGivesCriticalPacingTip() {
        let p = Projection(ratePerHour: 40, timeToFull: 1800, secondsToReset: 7200, verdict: .atRisk)
        let tips = Advice.compute(session: p, weekly: nil, sessionUtil: 70, weeklyUtil: nil,
                                  models: [], warnThreshold: 80, now: now)
        XCTAssertEqual(tips.first?.kind, .sessionPacing)
        XCTAssertEqual(tips.first?.level, .critical)
    }

    func testCostHeavyModelTip() {
        let models = [model("Opus 4.8", total: 500_000, requests: 5, cost: 300),
                      model("Sonnet 4.6", total: 500_000, requests: 5, cost: 30)]
        let tips = Advice.compute(session: nil, weekly: nil, sessionUtil: 20, weeklyUtil: 20,
                                  models: models, warnThreshold: 80, now: now)
        XCTAssertTrue(tips.contains { $0.kind == .costModel })
    }

    func testHealthyWhenAllCalm() {
        let safe = Projection(ratePerHour: 5, timeToFull: 36000, secondsToReset: 3600, verdict: .safe)
        let tips = Advice.compute(session: safe, weekly: nil, sessionUtil: 20, weeklyUtil: 20,
                                  models: [], warnThreshold: 80, now: now)
        XCTAssertEqual(tips.map(\.kind), [.healthy])
    }

    func testCapsAtThreeTips() {
        let atRisk = Projection(ratePerHour: 40, timeToFull: 600, secondsToReset: 7200, verdict: .atRisk)
        let models = [model("Opus 4.8", total: 500_000, requests: 5, cost: 300),
                      model("Sonnet 4.6", total: 500_000, requests: 5, cost: 30)]
        let tips = Advice.compute(session: atRisk, weekly: nil, sessionUtil: 95, weeklyUtil: 92,
                                  models: models, warnThreshold: 80, now: now)
        XCTAssertLessThanOrEqual(tips.count, 3)
        XCTAssertEqual(tips.first?.kind, .sessionPacing)   // critical first
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
