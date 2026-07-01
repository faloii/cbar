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

    func testShortCountdown() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Fmt.shortCountdown(to: t.addingTimeInterval(6 * 86400 + 100), from: t), "6d")
        XCTAssertEqual(Fmt.shortCountdown(to: t.addingTimeInterval(2 * 3600 + 100), from: t), "2h")
        XCTAssertEqual(Fmt.shortCountdown(to: t.addingTimeInterval(13 * 60), from: t), "13m")
        XCTAssertEqual(Fmt.shortCountdown(to: t.addingTimeInterval(30), from: t), "<1m")
    }

    func testCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(2 * 3600 + 13 * 60), from: now), "2h 13m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(45 * 60), from: now), "45m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(10), from: now), "<1m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(-100), from: now), "<1m") // past
    }

    func testClockFormat() {
        // Timezone-independent shape check: "HH:mm".
        let s = Fmt.clock(Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(Array(s)[2], ":")
    }

    func testMediumCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Fmt.mediumCountdown(to: now.addingTimeInterval(2 * 3600 + 13 * 60), from: now), "2h 13m")
        XCTAssertEqual(Fmt.mediumCountdown(to: now.addingTimeInterval(3600), from: now), "1h 0m")
        XCTAssertEqual(Fmt.mediumCountdown(to: now.addingTimeInterval(13 * 60), from: now), "13m")
        XCTAssertEqual(Fmt.mediumCountdown(to: now.addingTimeInterval(30), from: now), "<1m")
        XCTAssertEqual(Fmt.mediumCountdown(to: now.addingTimeInterval(86400 + 4 * 3600), from: now), "1d 4h")
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

final class CacheEfficiencyTests: XCTestCase {
    func testFreshAndCacheReadSharesSumToOne() {
        let t = TokenCounts(input: 10, output: 10, cacheWrite: 10, cacheRead: 70)
        let v = CacheEfficiency.verdict(t)
        XCTAssertEqual(v?.freshShare ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(v?.cacheReadShare ?? 0, 0.7, accuracy: 0.001)
    }

    func testAllFreshWhenNoCacheRead() {
        let t = TokenCounts(input: 50, output: 50, cacheWrite: 0, cacheRead: 0)
        let v = CacheEfficiency.verdict(t)
        XCTAssertEqual(v?.freshShare ?? 0, 1.0, accuracy: 0.001)
    }

    func testNilWhenEmpty() {
        XCTAssertNil(CacheEfficiency.verdict(TokenCounts()))
    }
}

final class NotificationBundlerTests: XCTestCase {
    func alert(_ id: String) -> LimitAlert { LimitAlert(id: id, title: "제목-\(id)", body: "본문-\(id)") }

    func testPassesThroughZeroOrOne() {
        XCTAssertEqual(NotificationBundler.bundle([]), [])
        XCTAssertEqual(NotificationBundler.bundle([alert("a")]), [alert("a")])
    }

    func testBundlesMultipleIntoOne() {
        let out = NotificationBundler.bundle([alert("a"), alert("b")])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].title.contains("2"))
        XCTAssertTrue(out[0].body.contains("제목-a"))
        XCTAssertTrue(out[0].body.contains("제목-b"))
    }

    func testBundledIdIsDeterministic() {
        let out1 = NotificationBundler.bundle([alert("b"), alert("a")])
        let out2 = NotificationBundler.bundle([alert("a"), alert("b")])
        XCTAssertEqual(out1[0].id, out2[0].id)
    }
}

final class QuietHoursTests: XCTestCase {
    func testSameDayWindow() {
        XCTAssertTrue(QuietHours.isQuiet(hour: 13, start: 12, end: 14))
        XCTAssertFalse(QuietHours.isQuiet(hour: 15, start: 12, end: 14))
        XCTAssertFalse(QuietHours.isQuiet(hour: 12, start: 12, end: 12))   // zero-length = never
    }

    func testOvernightWraparound() {
        XCTAssertTrue(QuietHours.isQuiet(hour: 23, start: 22, end: 8))
        XCTAssertTrue(QuietHours.isQuiet(hour: 3, start: 22, end: 8))
        XCTAssertTrue(QuietHours.isQuiet(hour: 22, start: 22, end: 8))    // start inclusive
        XCTAssertFalse(QuietHours.isQuiet(hour: 8, start: 22, end: 8))    // end exclusive
        XCTAssertFalse(QuietHours.isQuiet(hour: 12, start: 22, end: 8))
    }
}

final class UpcomingResetsTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_000_000)

    func testWalksForwardEvery5Hours() {
        let next = t.addingTimeInterval(1800)
        let out = UpcomingResets.compute(nextReset: next, now: t, count: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1].timeIntervalSince(out[0]), 5 * 3600, accuracy: 0.01)
        XCTAssertEqual(out[2].timeIntervalSince(out[1]), 5 * 3600, accuracy: 0.01)
    }

    func testEmptyWhenResetIsPastOrCountZero() {
        XCTAssertEqual(UpcomingResets.compute(nextReset: t.addingTimeInterval(-10), now: t), [])
        XCTAssertEqual(UpcomingResets.compute(nextReset: t.addingTimeInterval(100), now: t, count: 0), [])
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
        let p = Projection.paced(util: 10, resetsAt: t.addingTimeInterval(5 * 24 * 3600),
                                 windowSeconds: week, now: t)
        XCTAssertEqual(p.verdict, .safe)
        XCTAssertLessThan(p.ratePerHour, 1)   // realized pace is small, not a burst
    }

    func testPacedAtRiskWhenAheadOfPace() {
        // 60% used only 2 days in → on track to blow the week → at risk.
        let week: TimeInterval = 7 * 24 * 3600
        let p = Projection.paced(util: 60, resetsAt: t.addingTimeInterval(5 * 24 * 3600),
                                 windowSeconds: week, now: t)
        XCTAssertEqual(p.verdict, .atRisk)
    }

    func testPacedTooEarlyStaysSafe() {
        // Only 3h into the week — too early to project a pace.
        let week: TimeInterval = 7 * 24 * 3600
        let p = Projection.paced(util: 40, resetsAt: t.addingTimeInterval(week - 3 * 3600),
                                 windowSeconds: week, now: t)
        XCTAssertEqual(p.verdict, .safe)
    }

    func testProjectedAtResetShowsHeadroom() {
        // 50→56 over 30m = 12%/h; reset in 2h → projected 56 + 12*2 = 80% (20% headroom).
        let p = Projection.compute(points: [(mins(-30), 50), (t, 56)], resetsAt: t.addingTimeInterval(2 * 3600), now: t)
        XCTAssertEqual(p.verdict, .safe)
        XCTAssertEqual(p.projectedAtReset ?? 0, 80, accuracy: 0.5)
        XCTAssertEqual(p.headroomAtReset ?? 0, 20, accuracy: 0.5)
    }

    func testPacedProjectedAtReset() {
        // 10% used 1 day into a 7-day week → pace ~0.417%/h; 6 days to reset → ~70%.
        let week: TimeInterval = 7 * 24 * 3600
        let p = Projection.paced(util: 10, resetsAt: t.addingTimeInterval(6 * 24 * 3600),
                                 windowSeconds: week, now: t)
        XCTAssertEqual(p.projectedAtReset ?? 0, 70, accuracy: 1.0)
    }

    func testResetBoundaryIgnoresPreDropSamples() {
        // A reset (95→10) means the slope must come from the post-reset rise (10→20),
        // not the overall negative trend — i.e. a positive burn, not idle.
        let pts: [(Date, Double)] = [(mins(-40), 90), (mins(-20), 95), (mins(-15), 10), (mins(-5), 20)]
        let p = Projection.compute(points: pts, resetsAt: t.addingTimeInterval(5 * 3600), now: t)
        XCTAssertEqual(p.verdict, .atRisk)
        XCTAssertGreaterThan(p.ratePerHour, 30)
    }

    // MARK: - combinedWeekly (closes the "burned the week in the first 6h" blind spot)

    func testCombinedWeeklyCatchesEarlyBurstPacedWouldMiss() {
        // 3h into the week (< 6h paced cutoff), already at 70% from a burst in the
        // last 30m. `paced` alone would stay .safe (too early to judge); the burst
        // trajectory must catch this immediately.
        let week: TimeInterval = 7 * 24 * 3600
        let resetsAt = t.addingTimeInterval(week - 3 * 3600)
        let pts: [(Date, Double)] = [(mins(-30), 40), (t, 70)]
        let paced = Projection.paced(util: 70, resetsAt: resetsAt, windowSeconds: week, now: t)
        XCTAssertEqual(paced.verdict, .safe)   // confirms the blind spot exists without the fix
        let combined = Projection.combinedWeekly(points: pts, util: 70, resetsAt: resetsAt,
                                                  windowSeconds: week, now: t)
        XCTAssertEqual(combined.verdict, .atRisk)
    }

    func testCombinedWeeklyPrefersMoreUrgentSignal() {
        // Both signals at-risk; the sooner time-to-full should win.
        let week: TimeInterval = 7 * 24 * 3600
        let resetsAt = t.addingTimeInterval(5 * 24 * 3600)
        // Paced: 60% two days in → atRisk with a multi-day timeToFull.
        // Burst: a sharp recent spike → atRisk with a much sooner timeToFull.
        let pts: [(Date, Double)] = [(mins(-30), 55), (t, 60)]
        let combined = Projection.combinedWeekly(points: pts, util: 60, resetsAt: resetsAt,
                                                  windowSeconds: week, now: t)
        let paced = Projection.paced(util: 60, resetsAt: resetsAt, windowSeconds: week, now: t)
        XCTAssertEqual(combined.verdict, .atRisk)
        XCTAssertLessThanOrEqual(combined.timeToFull ?? .infinity, paced.timeToFull ?? .infinity)
    }

    func testCombinedWeeklyFallsBackToPacedWhenNoBurst() {
        // No burst signal (flat/insufficient data) → behaves exactly like `paced`.
        let week: TimeInterval = 7 * 24 * 3600
        let resetsAt = t.addingTimeInterval(5 * 24 * 3600)
        let combined = Projection.combinedWeekly(points: [], util: 10, resetsAt: resetsAt,
                                                  windowSeconds: week, now: t)
        let paced = Projection.paced(util: 10, resetsAt: resetsAt, windowSeconds: week, now: t)
        XCTAssertEqual(combined, paced)
    }
}

final class DailyAllowanceTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_000_000)

    func testRecommendedPctPerDaySpreadsRemainingEvenly() {
        // 40% used, 4 days left → 60% remaining / 4 days = 15%/day.
        let v = DailyAllowance.verdict(util: 40, resetsAt: t.addingTimeInterval(4 * 86400),
                                       now: t, todayStartUtil: nil)
        XCTAssertEqual(v?.daysRemaining ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(v?.recommendedPctPerDay ?? 0, 15, accuracy: 0.01)
        XCTAssertNil(v?.usedTodayPct)
    }

    func testUsedTodayIsDeltaFromMidnight() {
        let v = DailyAllowance.verdict(util: 55, resetsAt: t.addingTimeInterval(3 * 86400),
                                       now: t, todayStartUtil: 40)
        XCTAssertEqual(v?.usedTodayPct ?? 0, 15, accuracy: 0.01)
    }

    func testNilWhenNoResetOrAlreadyFull() {
        XCTAssertNil(DailyAllowance.verdict(util: 50, resetsAt: nil, now: t, todayStartUtil: nil))
        XCTAssertNil(DailyAllowance.verdict(util: 100, resetsAt: t.addingTimeInterval(86400),
                                            now: t, todayStartUtil: nil))
    }

    func testDaysRemainingFloorsNearReset() {
        // 5 minutes to reset shouldn't blow up the recommended rate to something absurd.
        let v = DailyAllowance.verdict(util: 90, resetsAt: t.addingTimeInterval(300),
                                       now: t, todayStartUtil: nil)
        XCTAssertNotNil(v)
        XCTAssertGreaterThanOrEqual(v?.daysRemaining ?? 0, 1.0 / 24)
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

        // util 50% maps to the 1M total → Opus 100k/turn = 5% of limit/turn; Fable 2.5%.
        XCTAssertEqual(opus.limitSharePerTurn ?? 0, 5.0, accuracy: 0.05)
        XCTAssertEqual(fable.limitSharePerTurn ?? 0, 2.5, accuracy: 0.05)
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

    func testNoLimitShareWithoutUtilization() {
        let rows = ModelBurn.rows(window: [model("Opus", total: 100, requests: 1)],
                                  sessionUtil: nil, basis: .totalTokens)
        XCTAssertNil(rows.first?.limitSharePerTurn)
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

final class WeeklyReviewTests: XCTestCase {
    func testThisVsLastWeek() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries: [(date: Date, byModel: [String: Int])] = [
            (now.addingTimeInterval(-1 * 86400), ["claude-opus-4-8": 1_000_000]),    // this week
            (now.addingTimeInterval(-8 * 86400), ["claude-sonnet-4-6": 1_000_000]),  // last week
        ]
        let rates = ["claude-opus-4-8": 0.0001, "claude-sonnet-4-6": 0.00001]
        let r = WeeklyReview.compute(entries: entries, rates: rates, fallback: 0, now: now)!
        XCTAssertEqual(r.thisCost, 100, accuracy: 0.001)
        XCTAssertEqual(r.lastCost, 10, accuracy: 0.001)
        XCTAssertEqual(r.opusShareThis, 1.0, accuracy: 0.001)   // this week was all Opus
        XCTAssertEqual(r.opusShareLast, 0.0, accuracy: 0.001)
        XCTAssertEqual(r.costDeltaPct ?? 0, 900, accuracy: 0.1)
    }

    func testOpusSharesPerWeek() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rates = ["claude-opus-4-8": 0.0001, "claude-sonnet-4-6": 0.0001]
        let entries: [(date: Date, byModel: [String: Int])] = [
            // this week (w0): 80% Opus
            (now.addingTimeInterval(-1 * 86400), ["claude-opus-4-8": 800_000, "claude-sonnet-4-6": 200_000]),
            // last week (w1): 20% Opus
            (now.addingTimeInterval(-8 * 86400), ["claude-opus-4-8": 200_000, "claude-sonnet-4-6": 800_000]),
        ]
        let shares = WeeklyReview.opusShares(entries: entries, rates: rates, fallback: 0, now: now, weeks: 4)
        XCTAssertEqual(shares.count, 4)
        XCTAssertEqual(shares[0].opusShare, 0.8, accuracy: 0.001)
        XCTAssertTrue(shares[0].hasUsage)
        XCTAssertEqual(shares[1].opusShare, 0.2, accuracy: 0.001)
        XCTAssertFalse(shares[2].hasUsage)   // no data 2-3 weeks ago
        XCTAssertFalse(shares[3].hasUsage)
    }

    func testNilWhenNoRecentData() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries: [(date: Date, byModel: [String: Int])] = [
            (now.addingTimeInterval(-40 * 86400), ["claude-opus-4-8": 1_000_000]),   // too old
        ]
        XCTAssertNil(WeeklyReview.compute(entries: entries, rates: [:], fallback: 0.0001, now: now))
    }
}

final class AdviceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    private func model(_ name: String, total: Int, requests: Int, cost: Double) -> ModelWindowUsage {
        ModelWindowUsage(model: name, tokens: TokenCounts(cacheRead: total), cost: cost, requests: requests)
    }

    func testAtRiskGivesCriticalPacingTip() {
        let p = Projection(ratePerHour: 40, timeToFull: 1800, secondsToReset: 7200, verdict: .atRisk)
        let tips = Advice.compute(session: p, weekly: nil, sessionUtil: 70, weeklyUtil: nil,
                                  models: [], warnThreshold: 80, now: now)
        XCTAssertEqual(tips.first?.kind, .sessionPacing)
        XCTAssertEqual(tips.first?.level, .critical)
    }

    func testPacingTipIsConcreteWithTurnsAndLever() {
        let p = Projection(ratePerHour: 40, timeToFull: 1800, secondsToReset: 7200, verdict: .atRisk)
        let models = [model("Opus 4.8", total: 100, requests: 40, cost: 10)]   // 40 turns at 80% util
        let tips = Advice.compute(session: p, weekly: nil, sessionUtil: 80, weeklyUtil: nil,
                                  models: models, warnThreshold: 80, now: now)
        let pacing = tips.first { $0.kind == .sessionPacing }
        XCTAssertEqual(pacing?.level, .critical)
        XCTAssertTrue(pacing?.text.contains("턴") ?? false)        // turn estimate present
        XCTAssertTrue(pacing?.text.contains("시간당") ?? false)    // concrete target-rate lever
    }

    func testNearMissPacingIsCalmer() {
        // Hits full ~5m before reset → barely blocked → warn, not critical.
        let p = Projection(ratePerHour: 30, timeToFull: 6900, secondsToReset: 7200, verdict: .atRisk)
        let tips = Advice.compute(session: p, weekly: nil, sessionUtil: 70, weeklyUtil: nil,
                                  models: [], warnThreshold: 80, now: now)
        XCTAssertEqual(tips.first { $0.kind == .sessionPacing }?.level, .warn)
    }

    func testResetImminentTip() {
        let p = Projection(ratePerHour: 3, timeToFull: 99999, secondsToReset: 600,
                           verdict: .safe, projectedAtReset: 92)
        let tips = Advice.compute(session: p, weekly: nil, sessionUtil: 90, weeklyUtil: nil,
                                  models: [], warnThreshold: 80, now: now)
        XCTAssertTrue(tips.contains { $0.kind == .resetImminent })
    }

    func testWeeklyAtRiskWordingIsDirect() {
        let wk = Projection(ratePerHour: 2, timeToFull: 1000, secondsToReset: 3 * 24 * 3600, verdict: .atRisk)
        let tips = Advice.compute(session: nil, weekly: wk, sessionUtil: nil, weeklyUtil: 85,
                                  models: [], warnThreshold: 80, now: now)
        let weekly = tips.first { $0.kind == .weeklyDefer }
        XCTAssertTrue(weekly?.text.contains("바닥") ?? false)
    }

    func testHeadroomTipWhenUnderUsing() {
        // Burning steadily but only on track to reach ~50% by reset → 50% headroom.
        let safe = Projection(ratePerHour: 5, timeToFull: 36000, secondsToReset: 7200,
                              verdict: .safe, projectedAtReset: 50)
        let tips = Advice.compute(session: safe, weekly: nil, sessionUtil: 40, weeklyUtil: 20,
                                  models: [], warnThreshold: 80, now: now)
        XCTAssertTrue(tips.contains { $0.kind == .headroom })
    }

    func testNoHeadroomTipWhenOnTrackToFill() {
        let safe = Projection(ratePerHour: 12, timeToFull: 4000, secondsToReset: 3600,
                              verdict: .safe, projectedAtReset: 95)
        let tips = Advice.compute(session: safe, weekly: nil, sessionUtil: 80, weeklyUtil: 20,
                                  models: [], warnThreshold: 80, now: now)
        XCTAssertFalse(tips.contains { $0.kind == .headroom })
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

    func testContextHeavyTipFiresWhenLargeAndActive() {
        let safe = Projection(ratePerHour: 8, timeToFull: 20000, secondsToReset: 7200, verdict: .safe)
        let tips = Advice.compute(session: safe, weekly: nil, sessionUtil: 40, weeklyUtil: 20,
                                  models: [], contextTokens: 150_000, warnThreshold: 80, now: now)
        let ctx = tips.first { $0.kind == .contextHeavy }
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx?.text.contains("compact") ?? false)
        XCTAssertTrue(ctx?.text.contains("새 대화") ?? false)
    }

    func testNoContextTipWhenSmallOrIdle() {
        let safe = Projection(ratePerHour: 8, timeToFull: 20000, secondsToReset: 7200, verdict: .safe)
        // Small context → no tip.
        XCTAssertFalse(Advice.compute(session: safe, weekly: nil, sessionUtil: 40, weeklyUtil: 20,
                                      models: [], contextTokens: 40_000, warnThreshold: 80, now: now)
            .contains { $0.kind == .contextHeavy })
        // Large context but no session usage → not relevant.
        XCTAssertFalse(Advice.compute(session: safe, weekly: nil, sessionUtil: 0, weeklyUtil: 20,
                                      models: [], contextTokens: 150_000, warnThreshold: 80, now: now)
            .contains { $0.kind == .contextHeavy })
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

    /// Security invariant: the refresh token lives in memory only and must never be
    /// encoded to disk (token.json). Only the access token + expiry are persisted.
    func testRefreshTokenNeverEncoded() throws {
        let creds = ClaudeCredentials(accessToken: "sk-ant-access",
                                      expiresAt: Date(timeIntervalSince1970: 1_781_157_378),
                                      refreshToken: "sk-ant-refresh-SECRET")
        let data = try JSONEncoder().encode(creds)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("sk-ant-access"))
        XCTAssertFalse(json.contains("sk-ant-refresh-SECRET"))
        XCTAssertFalse(json.lowercased().contains("refresh"))
    }
}

final class PaceTests: XCTestCase {
    func testSustainableRate() {
        // 40% used, 2h to reset → need 60%/2h = 30%/h to land at 100%.
        XCTAssertEqual(Pace.sustainableRate(util: 40, secondsToReset: 2 * 3600) ?? 0, 30, accuracy: 0.01)
        // Full or no reset → nil.
        XCTAssertNil(Pace.sustainableRate(util: 100, secondsToReset: 3600))
        XCTAssertNil(Pace.sustainableRate(util: 50, secondsToReset: nil))
        XCTAssertNil(Pace.sustainableRate(util: 50, secondsToReset: 30))   // reset imminent
    }

    func testElapsedFraction() {
        let week: TimeInterval = 7 * 24 * 3600
        // 2 days into a 7-day window → ~0.286 elapsed.
        XCTAssertEqual(Pace.elapsedFraction(windowSeconds: week, secondsToReset: 5 * 24 * 3600) ?? -1, 2.0 / 7.0, accuracy: 0.001)
        XCTAssertNil(Pace.elapsedFraction(windowSeconds: week, secondsToReset: nil))
    }
}

final class SessionCoachTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testAtRiskWorkBudgetIsTimeToFull() {
        let p = Projection(ratePerHour: 40, timeToFull: 1800, secondsToReset: 7200, verdict: .atRisk)
        let b = SessionCoach.workBudget(session: p, util: 70,
                                        resetsAt: now.addingTimeInterval(7200), now: now)
        XCTAssertEqual(b?.workableSeconds, 1800)
        XCTAssertTrue(b?.willBlock ?? false)
        XCTAssertEqual(b?.blockAt, now.addingTimeInterval(1800))
    }

    func testSafeWorkBudgetIsUntilReset() {
        let p = Projection(ratePerHour: 5, timeToFull: 36000, secondsToReset: 7200, verdict: .safe)
        let b = SessionCoach.workBudget(session: p, util: 40,
                                        resetsAt: now.addingTimeInterval(7200), now: now)
        XCTAssertEqual(b?.workableSeconds, 7200)
        XCTAssertFalse(b?.willBlock ?? true)
        XCTAssertNil(b?.blockAt)
    }

    func testBlockedNowWhenFull() {
        let b = SessionCoach.workBudget(session: nil, util: 100,
                                        resetsAt: now.addingTimeInterval(3600), now: now)
        XCTAssertTrue(b?.blockedNow ?? false)
    }

    func testMeasuringHasNoBudget() {
        XCTAssertNil(SessionCoach.workBudget(session: .measuring, util: 30,
                                             resetsAt: now.addingTimeInterval(3600), now: now))
    }

    func testPerExchangeLimitPct() {
        // 62% used over a 3.1M-token window; a 150k-token next turn ≈ 150k/3.1M of the
        // implied limit → ~3%.
        let p = SessionCoach.perExchangeLimitPct(contextTokens: 150_000, windowTokens: 3_100_000, sessionUtil: 62)
        XCTAssertEqual(p ?? 0, 3.0, accuracy: 0.05)
        XCTAssertNil(SessionCoach.perExchangeLimitPct(contextTokens: 0, windowTokens: 100, sessionUtil: 50))
        XCTAssertNil(SessionCoach.perExchangeLimitPct(contextTokens: 100, windowTokens: 100, sessionUtil: 0))
    }

    func testLastSessionRecapFindsSegmentBeforeReset() {
        let s: [UsageSample] = [
            UsageSample(at: now.addingTimeInterval(-4 * 3600), session: 30, weekly: nil),
            UsageSample(at: now.addingTimeInterval(-3 * 3600), session: 88, weekly: nil),  // peak of prev session
            UsageSample(at: now.addingTimeInterval(-2.5 * 3600), session: 70, weekly: nil),// ended here
            UsageSample(at: now.addingTimeInterval(-2 * 3600), session: 5, weekly: nil),   // reset (drop)
            UsageSample(at: now.addingTimeInterval(-1 * 3600), session: 20, weekly: nil),
        ]
        let r = SessionCoach.lastSessionRecap(samples: s, now: now)
        XCTAssertEqual(r?.peak, 88)
        XCTAssertEqual(r?.endedAt, 70)
        XCTAssertFalse(r?.blocked ?? true)
        XCTAssertEqual(r?.leftover ?? 0, 30, accuracy: 0.001)
    }

    func testNoRecapWithoutAReset() {
        let s: [UsageSample] = [
            UsageSample(at: now.addingTimeInterval(-2 * 3600), session: 10, weekly: nil),
            UsageSample(at: now.addingTimeInterval(-1 * 3600), session: 40, weekly: nil),
        ]
        XCTAssertNil(SessionCoach.lastSessionRecap(samples: s, now: now))
    }

    func testEfficiencyVerdict() {
        let atRisk = Projection(ratePerHour: 40, timeToFull: 600, secondsToReset: 7200, verdict: .atRisk)
        XCTAssertEqual(SessionCoach.efficiency(util: 70, projection: atRisk), .overpacing)
        let full = Projection(ratePerHour: 10, timeToFull: 9000, secondsToReset: 7200, verdict: .safe, projectedAtReset: 95)
        XCTAssertEqual(SessionCoach.efficiency(util: 60, projection: full), .optimal)
        let waste = Projection(ratePerHour: 2, timeToFull: 99999, secondsToReset: 7200, verdict: .safe, projectedAtReset: 40)
        XCTAssertEqual(SessionCoach.efficiency(util: 30, projection: waste), .underusing)
        XCTAssertEqual(SessionCoach.efficiency(util: nil, projection: nil), .measuring)
    }
}

final class ModelRecapTests: XCTestCase {
    private func win(_ model: String, output: Int, cacheRead: Int, requests: Int, cost: Double) -> ModelWindowUsage {
        ModelWindowUsage(model: model, tokens: TokenCounts(input: 0, output: output, cacheWrite: 0, cacheRead: cacheRead),
                         cost: cost, requests: requests)
    }

    func testIntensityBands() {
        XCTAssertEqual(ModelRecap.intensity(outputPerTurn: 599), .light)
        XCTAssertEqual(ModelRecap.intensity(outputPerTurn: 600), .moderate)
        XCTAssertEqual(ModelRecap.intensity(outputPerTurn: 1499), .moderate)
        XCTAssertEqual(ModelRecap.intensity(outputPerTurn: 1500), .heavy)
    }

    func testLightOpusSuggestsSonnetDownshift() {
        // 400 output / 5 turns = 80/turn → light. Price the tokens at Opus so the saving
        // is the real Opus→Sonnet delta (Sonnet is exactly 1/5 across the board).
        let tokens = TokenCounts(input: 0, output: 400, cacheWrite: 0, cacheRead: 100_000)
        let opusCost = Pricing.cost(for: tokens, model: "opus")
        let v = ModelRecap.verdict(window: [
            ModelWindowUsage(model: "claude-opus-4-8", tokens: tokens, cost: opusCost, requests: 5)
        ])
        XCTAssertEqual(v?.intensity, .light)
        XCTAssertEqual(v?.downshiftTo, "Sonnet")
        XCTAssertEqual(v?.downshiftSaving ?? 0, 0.8, accuracy: 0.001)  // Sonnet = 1/5 of Opus
        XCTAssertEqual(v?.outputPerTurn, 80)
    }

    func testHeavyOpusIsJustifiedNoDownshift() {
        // 8000 output / 5 turns = 1600/turn → heavy → no downshift even though Opus.
        let v = ModelRecap.verdict(window: [win("claude-opus-4-8", output: 8000, cacheRead: 100_000, requests: 5, cost: 9)])
        XCTAssertEqual(v?.intensity, .heavy)
        XCTAssertTrue(v?.isTopTier == true)
        XCTAssertNil(v?.downshiftTo)
    }

    func testSonnetDominantHasNoDownshift() {
        let v = ModelRecap.verdict(window: [win("claude-sonnet-4-6", output: 300, cacheRead: 50_000, requests: 5, cost: 2)])
        XCTAssertEqual(v?.isTopTier, false)
        XCTAssertNil(v?.downshiftTo)
    }

    func testPicksDominantModelByCost() {
        let v = ModelRecap.verdict(window: [
            win("claude-opus-4-8", output: 400, cacheRead: 10_000, requests: 5, cost: 3),
            win("claude-sonnet-4-6", output: 9000, cacheRead: 500_000, requests: 5, cost: 40),
        ])
        XCTAssertEqual(v?.model, "claude-sonnet-4-6")  // highest cost wins
    }

    func testNilWhenNoCompletedTurns() {
        XCTAssertNil(ModelRecap.verdict(window: []))
        XCTAssertNil(ModelRecap.verdict(window: [win("claude-opus-4-8", output: 0, cacheRead: 0, requests: 0, cost: 0)]))
    }
}

final class ResumeCommandTests: XCTestCase {
    func testShellQuoteWrapsAndEscapes() {
        XCTAssertEqual(ResumeCommand.shellQuote("plain"), "'plain'")
        XCTAssertEqual(ResumeCommand.shellQuote("a b"), "'a b'")
        XCTAssertEqual(ResumeCommand.shellQuote("a'b"), "'a'\\''b'")   // ' → '\''
    }

    func testPreviewNeutralizesDangerousPath() {
        // A project dir crafted to break out of double quotes must stay fully quoted.
        let cmd = ResumeCommand.buildPreview(dir: "/x\"; rm -rf ~ #", bin: "claude")
        XCTAssertTrue(cmd.hasPrefix("cd '"))
        XCTAssertTrue(cmd.contains("'/x\"; rm -rf ~ #'"))   // single-quoted as one word
        XCTAssertTrue(cmd.contains("--continue -p '계속 진행해줘' --model haiku"))
    }

    func testPreviewEscapesEmbeddedSingleQuote() {
        let cmd = ResumeCommand.buildPreview(dir: "/a'b", bin: "claude")
        XCTAssertTrue(cmd.contains("'/a'\\''b'"))
    }
}

final class LimitAlertsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func win(_ util: Double, resetIn: TimeInterval? = nil) -> LimitWindow {
        LimitWindow(utilization: util, resetsAt: resetIn.map { now.addingTimeInterval($0) })
    }
    func eval(session: LimitWindow? = nil, weekly: LimitWindow? = nil,
              sp: Projection? = nil, wp: Projection? = nil, status: String? = nil,
              warn: Int = 80, state: inout LimitAlertState) -> [LimitAlert] {
        LimitAlerts.evaluate(session: session, weekly: weekly,
                             sessionProjection: sp, weeklyProjection: wp,
                             status: status, warnThreshold: warn, state: &state, now: now)
    }

    func testThresholdFiresOnceThenResetsAfterDrop() {
        var s = LimitAlertState()
        XCTAssertTrue(eval(session: win(85), state: &s).contains { $0.id == "limit-session" })
        XCTAssertFalse(eval(session: win(88), state: &s).contains { $0.id == "limit-session" }) // still high → silent
        _ = eval(session: win(40), state: &s)                                                   // dropped → re-arm
        XCTAssertTrue(eval(session: win(85), state: &s).contains { $0.id == "limit-session" })  // fires again
    }

    func testTrajectoryWarnsBelowThreshold() {
        var s = LimitAlertState()
        // Beyond the 30m lead time (1h to full) → the early "곧 소진" heads-up, not imminent.
        let atRisk = Projection(ratePerHour: 40, timeToFull: 3600, secondsToReset: 7200, verdict: .atRisk)
        let out = eval(session: win(60), sp: atRisk, state: &s)
        XCTAssertTrue(out.contains { $0.id == "risk-session" })
        XCTAssertFalse(out.contains { $0.id == "block-imminent" })
        XCTAssertFalse(out.contains { $0.id == "limit-session" })
        // Fires once per episode.
        XCTAssertFalse(eval(session: win(62), sp: atRisk, state: &s).contains { $0.id == "risk-session" })
    }

    func testImminentBlockWithinLeadTime() {
        var s = LimitAlertState()
        // 10m to full ≤ 30m lead → the sharp "곧 막힘" warning, not the early heads-up.
        let atRisk = Projection(ratePerHour: 40, timeToFull: 600, secondsToReset: 7200, verdict: .atRisk)
        let out = eval(session: win(70), sp: atRisk, state: &s)
        XCTAssertTrue(out.contains { $0.id == "block-imminent" })
        XCTAssertFalse(out.contains { $0.id == "risk-session" })
        // Once per episode.
        XCTAssertFalse(eval(session: win(72), sp: atRisk, state: &s).contains { $0.id == "block-imminent" })
    }

    func testLeadTimeIsConfigurable() {
        var s = LimitAlertState()
        // 40m to full with a 60m lead → imminent (within lead).
        let atRisk = Projection(ratePerHour: 40, timeToFull: 2400, secondsToReset: 7200, verdict: .atRisk)
        let out = LimitAlerts.evaluate(session: win(70), weekly: nil, sessionProjection: atRisk,
                                       weeklyProjection: nil, status: nil, warnThreshold: 80,
                                       blockWarnLeadMinutes: 60, state: &s, now: now)
        XCTAssertTrue(out.contains { $0.id == "block-imminent" })
    }

    func testBlockedFiresOnRejectedAndOnFull() {
        var s = LimitAlertState()
        XCTAssertTrue(eval(session: win(70), status: "rejected", state: &s).contains { $0.id == "blocked" })
        var s2 = LimitAlertState()
        XCTAssertTrue(eval(session: win(100, resetIn: 3600), state: &s2).contains { $0.id == "blocked" })
        XCTAssertFalse(eval(session: win(100, resetIn: 3500), state: &s2).contains { $0.id == "blocked" }) // once
    }

    func testWeeklyTiersEscalateAndFireOncePerCrossing() {
        var s = LimitAlertState()
        // Crossing 50% fires the 50 tier only.
        let out1 = eval(weekly: win(55), state: &s)
        XCTAssertTrue(out1.contains { $0.id == "weekly-tier-50" })
        XCTAssertFalse(out1.contains { $0.id == "weekly-tier-75" })
        // Staying within the same tier stays silent.
        XCTAssertTrue(eval(weekly: win(60), state: &s).isEmpty)
        // Jumping straight to 92% fires 75 AND 90 in the same pass (skipped tiers matter too).
        let out2 = eval(weekly: win(92), state: &s)
        XCTAssertTrue(out2.contains { $0.id == "weekly-tier-90" })
    }

    func testWeeklyTierResetsAfterReset() {
        var s = LimitAlertState()
        _ = eval(weekly: win(92), state: &s)
        XCTAssertEqual(s.weeklyTier, 3)
        _ = eval(weekly: win(1), state: &s)   // weekly window reset
        XCTAssertEqual(s.weeklyTier, 0)
        // Re-arms: 50% fires again after the reset.
        XCTAssertTrue(eval(weekly: win(55), state: &s).contains { $0.id == "weekly-tier-50" })
    }

    func testResetDoneOnSharpDrop() {
        var s = LimitAlertState(); s.prevSessionUtil = 80
        let out = eval(session: win(2), state: &s)
        let done = out.first { $0.id == "reset-done" }
        XCTAssertNotNil(done)
        XCTAssertTrue(done!.title.contains("리셋됨"))        // plain reset (wasn't blocked)
        XCTAssertEqual(s.prevSessionUtil, 2)
    }

    func testResetAfterBlockedIsAnActionPrompt() {
        var s = LimitAlertState()
        _ = eval(session: win(100, resetIn: 300), state: &s)   // blocked → remembers wasBlocked
        XCTAssertTrue(s.wasBlocked)
        let out = eval(session: win(1, resetIn: 5 * 3600), state: &s) // window reset
        let done = out.first { $0.id == "reset-after-block" }
        XCTAssertNotNil(done)                                 // distinct id triggers auto-resume
        XCTAssertTrue(done!.title.contains("다시 시작"))     // stronger CTA after a block
        XCTAssertFalse(s.wasBlocked)                          // consumed
    }

    func testResetSoonWhenHighAndClose() {
        var s = LimitAlertState()
        let out = eval(session: win(90, resetIn: 10 * 60), state: &s)
        XCTAssertTrue(out.contains { $0.id == "reset-soon" })
        XCTAssertFalse(eval(session: win(90, resetIn: 9 * 60), state: &s).contains { $0.id == "reset-soon" }) // once
    }

    func testNoAlertsWhenSafe() {
        var s = LimitAlertState()
        let safe = Projection(ratePerHour: 5, timeToFull: 36000, secondsToReset: 3600, verdict: .safe)
        XCTAssertTrue(eval(session: win(30, resetIn: 3600), sp: safe, state: &s).isEmpty)
    }

    func testUnderpaceFiresWhenLeavingHeadroom() {
        var s = LimitAlertState()
        let safe = Projection(ratePerHour: 3, timeToFull: 99999, secondsToReset: 4 * 3600,
                              verdict: .safe, projectedAtReset: 40)
        let out = eval(session: win(30, resetIn: 4 * 3600), sp: safe, state: &s)
        XCTAssertTrue(out.contains { $0.id == "pace-slow" })
        XCTAssertTrue(s.paceSlow)
        // Fires once per episode.
        XCTAssertFalse(eval(session: win(31, resetIn: 4 * 3600), sp: safe, state: &s).contains { $0.id == "pace-slow" })
    }

    func testNoUnderpaceWhenOnTrack() {
        var s = LimitAlertState()
        let safe = Projection(ratePerHour: 10, timeToFull: 5000, secondsToReset: 4 * 3600,
                              verdict: .safe, projectedAtReset: 85)
        XCTAssertFalse(eval(session: win(60, resetIn: 4 * 3600), sp: safe, state: &s).contains { $0.id == "pace-slow" })
    }
}
