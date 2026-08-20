import Foundation

/// Situational advice and the longer-horizon analytics that feed it: the personal
/// burn-anomaly/hour-of-day/project baselines, cache-efficiency trend, plan-fit
/// signal, and the retrospective model recap.
extension UsageStore {
    /// Dynamic, situational advice from the current projections + per-model burn.
    ///
    /// Beyond the independent per-signal tips from `Advice.compute`, this layer
    /// looks for a shared ROOT CAUSE across signals and tells one coherent story
    /// instead of a stack of parallel observations — e.g. "burning 10× your usual
    /// day" and "this conversation is 300k tokens, mostly re-read" are very likely
    /// the same event, not two unrelated facts, so they're merged into one tip
    /// with a causal link ("...아마 이 무거운 대화 때문일 거예요") instead of both
    /// separately repeating the /compact suggestion.
    var adviceTips: [AdviceTip] {
        var tips = Advice.compute(session: sessionProjection, weekly: weeklyProjection,
                       sessionUtil: liveSession?.utilization,
                       weeklyUtil: liveWeekly?.utilization,
                       models: snapshot.windowByModel,
                       contextTokens: snapshot.currentContextTokens,
                       warnThreshold: warnThreshold,
                       now: snapshot.generatedAt,
                       typicalHourRate: typicalHourRate,
                       topWeeklyProject: topWeeklyProject)

        // A rare, positive one-off: reinforce that a past nudge (context/compact)
        // actually helped, rather than only ever warning. See `processAdviceFollowThrough`.
        // Appended last so it naturally yields to anything more urgent under the cap.
        if let worked = adviceWorkedTip { tips.append(worked) }

        let heavyContext = snapshot.currentContextTokens >= SessionCoach.heavyContextTokens
        // Once a merge below explains "why", the standalone .contextHeavy tip (same
        // /compact suggestion, just without the causal link) would be redundant.
        var contextStoryTold = false

        if let a = burnAnomaly {
            // The burn-anomaly warning ("you're on track to spend ~10× your usual
            // day") and the healthy fallback ("plenty of headroom — feel free to
            // use more") read as directly contradictory side by side, even though
            // one is about daily cost and the other about session-limit pacing.
            // Drop the reassuring fallback when the anomaly is showing — a "slow
            // down and check" nudge shouldn't sit next to "go ahead and use more".
            tips.removeAll { $0.kind == .healthy }
            let multText = a.multiplier >= 10 ? "10배 넘게" : String(format: "%.1f배", a.multiplier)
            let baseline = a.isWeekdaySpecific ? "이 요일 하루" : "하루"
            var text = "오늘 이 페이스면 평소(\(baseline) ~\(Fmt.usd(a.typicalDailyCost))) 대비 \(multText) 쓰게 돼요"
                + "(예상 ~\(Fmt.usd(a.projectedToday)))."
            if isHeavyContextWithReuse {
                // Root-cause link instead of leaving "왜 이렇게 빠르지?" unanswered.
                let k = snapshot.currentContextTokens / 1000
                text += " 지금 대화가 무겁고(~\(k)k토큰) 대부분 재읽기라 그런 걸 수도 있어요 — /compact 해보세요."
                contextStoryTold = true
            } else {
                text += " 계획한 작업이면 괜찮지만, 아니라면 한번 확인해보세요."
            }
            tips.insert(AdviceTip(kind: .burnAnomaly, level: .warn, icon: "flame", text: text), at: 0)
        }

        // Advice.compute already caps itself at 3, so simply appending here would
        // almost always get sliced off by a naive prefix(3) below — this tip would
        // silently never show in the common case. Widen the cap to 4 instead of
        // dropping it: it's real but lower-urgency (.info) than an active
        // risk/pacing warning, so it still yields to those when things are tight.
        if let t = cacheEfficiencyTrend {
            if heavyContext, !contextStoryTold, let idx = tips.firstIndex(where: { $0.kind == .contextHeavy }) {
                // Same underlying story as the heavy-context tip (re-reading a big
                // conversation) — fold the multi-day trend into it rather than
                // repeating the /compact suggestion in a second, separate tip.
                let old = tips[idx]
                tips[idx] = AdviceTip(kind: .contextHeavy, level: old.level, icon: old.icon,
                    text: old.text + " 최근 며칠 재읽기 비율도 늘고 있어요(예전 \(Int((t.baselineFreshShare * 100).rounded()))% → 최근 \(Int((t.recentFreshShare * 100).rounded()))%).")
                contextStoryTold = true
            } else if !contextStoryTold {
                tips.append(AdviceTip(kind: .cacheEfficiencyTrend, level: .info, icon: "arrow.trianglehead.2.clockwise",
                    text: "최근 재읽기 비율이 늘고 있어요(예전 평균 \(Int((t.baselineFreshShare * 100).rounded()))% 새 작업 → 최근 \(Int((t.recentFreshShare * 100).rounded()))%). "
                        + "/compact를 더 자주 쓰거나 새 대화로 자주 시작해보세요."))
            }
        }

        // The burn-anomaly tip above already told the heavy-context story with a
        // causal link — drop the plain .contextHeavy repeat of the same /compact
        // suggestion so the card doesn't say it twice.
        if contextStoryTold, tips.contains(where: { $0.kind == .burnAnomaly }) {
            tips.removeAll { $0.kind == .contextHeavy }
        }

        return Array(tips.prefix(4))
    }

    /// Multi-week "is your plan tier a good fit" read — see `PlanFitSignal`. Needs
    /// several completed weeks of live-limit history, so this stays nil for a
    /// while after a fresh install (nothing dishonest to say yet).
    var planFitSignal: PlanFitSignal.Result? {
        let peaks = PlanFitSignal.weeklyPeaks(samples: weeklyTrend, now: Date(), weeks: 5)
        return PlanFitSignal.evaluate(weeklyPeaks: peaks)
    }

    /// Per-project forward-looking share of the weekly limit — see `ProjectWeeklyForecast`.
    var projectWeeklyForecast: [ProjectWeeklyForecast.Item] {
        guard let w = liveWeekly, let allowance = weeklyAllowance else { return [] }
        return ProjectWeeklyForecast.forecast(projects: snapshot.weeklyProjectUsage,
                                              weeklyUtilPct: w.utilization,
                                              daysRemaining: allowance.daysRemaining)
    }

    /// "You're burning unusually fast today, FOR YOU" — a personal-baseline nudge
    /// (see `BurnAnomaly`), distinct from the fixed-threshold advice above.
    var burnAnomaly: BurnAnomaly.Verdict? {
        let now = snapshot.generatedAt
        let todayStr = DateParse.dayString(now)
        let hoursElapsed = now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 3600
        let dated = snapshot.dailyCostHistory.compactMap { dc -> (date: Date, cost: Double)? in
            guard dc.date != todayStr, let d = DateParse.day(dc.date) else { return nil }
            return (d, dc.cost)
        }
        let (past, isWeekdaySpecific) = BurnAnomaly.personalBaseline(dailyCosts: dated, today: now)
        return BurnAnomaly.verdict(todayCost: snapshot.todayCost, hoursElapsedToday: hoursElapsed,
                                   pastDailyCosts: past, isWeekdaySpecific: isWeekdaySpecific)
    }

    /// "Re-read share has been creeping up lately" — see `CacheEfficiencyTrend`.
    var cacheEfficiencyTrend: CacheEfficiencyTrend.Verdict? {
        let now = Date()
        let samples = CacheEfficiencyHistory.load()
        let recentCutoff = now.addingTimeInterval(-3 * 86400)      // last 3 days
        let baselineCutoff = now.addingTimeInterval(-28 * 86400)   // the 4 weeks before that
        let recent = samples.filter { $0.at >= recentCutoff }.map(\.freshShare)
        let baseline = samples.filter { $0.at >= baselineCutoff && $0.at < recentCutoff }.map(\.freshShare)
        return CacheEfficiencyTrend.verdict(recentShares: recent, baselineShares: baseline)
    }

    /// Your personal "usual speed at this hour" — see `HourlyBurnHistory`. nil
    /// until enough same-hour history has accumulated (no false personalization
    /// from day one).
    var typicalHourRate: Double? {
        let hour = Calendar.current.component(.hour, from: snapshot.generatedAt)
        return HourlyBurnHistory.typicalRate(forHour: hour, in: HourlyBurnHistory.load())
    }

    /// The project driving most of this week's spend, when one clearly dominates —
    /// feeds the weekly-defer tip's "왜" context. nil when usage is spread out or
    /// there's no weekly data yet.
    var topWeeklyProject: (name: String, sharePct: Double)? {
        let projects = snapshot.weeklyProjectUsage
        let totalCost = projects.reduce(0.0) { $0 + $1.cost }
        guard totalCost > 0.01, let top = projects.first else { return nil }
        return (top.project, top.cost / totalCost * 100)
    }

    /// Retrospective right-sizing read on the dominant model in the 5h window.
    var modelRecap: ModelRecap.Verdict? {
        ModelRecap.verdict(window: snapshot.windowByModel)
    }
}
