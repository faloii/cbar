import Foundation

/// The proactive-notification pipeline: limit alerts, the weekly recap, the model
/// downshift nudge, and the "that advice actually helped" follow-through — plus
/// the shared snooze/quiet-hours gate they all check before posting.
extension UsageStore {
    var lastSeenWeeklyResetsAt: Date? {
        get { lastSeenWeeklyResetsAtEpoch > 0 ? Date(timeIntervalSince1970: lastSeenWeeklyResetsAtEpoch) : nil }
        set { lastSeenWeeklyResetsAtEpoch = newValue?.timeIntervalSince1970 ?? 0 }
    }

    /// Fire a weekly usage recap notification: once per real weekly-limit reset
    /// when live limits are on (so the recap lands right when last week wraps up),
    /// falling back to a rolling ~7-day timer when they're off (no reset to observe).
    func maybeWeeklySummary() {
        guard weeklySummaryEnabled, let r = snapshot.weeklyReview else { return }
        let newResetsAt = limits?.weekly7d?.resetsAt
        if enableLiveLimits, newResetsAt != nil {
            guard WeeklyResetRecap.justReset(old: lastSeenWeeklyResetsAt, new: newResetsAt) else {
                lastSeenWeeklyResetsAt = newResetsAt
                return
            }
        } else {
            guard Date().timeIntervalSince1970 - lastWeeklySummaryAt >= 7 * 86400 else { return }
        }
        // Quiet hours/snooze: leave the reset "unconsumed" so this is retried (not
        // lost) on the next non-quiet tick, rather than silently skipping the week.
        guard !isQuietNow(Date()) else { return }
        lastSeenWeeklyResetsAt = newResetsAt
        lastWeeklySummaryAt = Date().timeIntervalSince1970

        var body = "지난 7일 ~\(Fmt.usd(r.thisCost))"
        if let d = r.costDeltaPct {
            body += d >= 0 ? " · 전주 ▲\(Int(d.rounded()))%" : " · 전주 ▼\(Int(abs(d).rounded()))%"
        }
        body += " · Opus 비중 \(Int((r.opusShareThis * 100).rounded()))%"
        if let ce = CacheEfficiency.verdict(snapshot.weeklyTokens) {
            body += " · 재읽기 \(Int((ce.cacheReadShare * 100).rounded()))%"
        }
        if let top = snapshot.weeklyProjectUsage.first {
            body += " · 최다 사용 \(top.project)"
        }
        if let coaching = r.coaching { body += "\n\(coaching)" }
        Notifier.notify(title: "주간 마감 리캡", body: body, id: "weekly-summary", urgency: .fyi)
    }

    /// Notify once when the dominant model in the 5h window newly looks
    /// downshift-worthy — see `ModelDownshiftSuggestion`. Independent of the
    /// limit-alert system: this is a cost-efficiency nudge, not a quota warning,
    /// so it has its own opt-in toggle.
    func processModelDownshiftSuggestion() {
        guard notifyModelDownshift, enableLiveLimits else { return }
        // Quiet check FIRST: shouldNotify consumes the one-shot, so checking it
        // during a snooze silently discarded the suggestion instead of deferring it.
        let now = Date()
        guard !isQuietNow(now),
              now.timeIntervalSince1970 - modelDownshiftNotifiedAt >= Self.modelDownshiftCooldown else { return }
        guard ModelDownshiftSuggestion.shouldNotify(modelRecap, state: &modelDownshiftState) else { return }
        guard let v = modelRecap, let to = v.downshiftTo else { return }
        modelDownshiftNotifiedAt = now.timeIntervalSince1970
        let savingPct = Int(((v.downshiftSaving ?? 0) * 100).rounded())
        Notifier.notify(
            title: "\(v.model) 대신 \(to) 정도면 충분해 보여요",
            body: "최근 턴 출력이 가벼운 편이에요 — 모델을 \(to) 쪽으로 바꾸면 이 창에서 비용 \(savingPct)% 절감돼요 (한도 소모량은 동일).",
            id: "model-downshift-\(v.model)", urgency: .nudge, category: .limit)
    }

    /// Tracks whether a "this conversation got heavy, try /compact" moment was
    /// actually followed by a real drop in context size (same session compacted,
    /// or you moved to a fresh one) — and if so, surfaces a one-time "that
    /// helped" tip via `adviceWorkedTip`. Deliberately asymmetric: a nudge that
    /// WASN'T followed just expires quietly after a few hours (no shaming, no
    /// repeat nagging) — only the positive outcome is worth surfacing.
    func processAdviceFollowThrough() {
        let now = Date()
        if isHeavyContextWithReuse {
            followThroughState = AdviceFollowThroughState(
                sessionId: snapshot.currentSessionId, contextTokens: snapshot.currentContextTokens, at: now)
            adviceWorkedTip = nil
            return
        }
        guard let pendingAt = followThroughState.at, followThroughState.contextTokens > 0,
              now.timeIntervalSince(pendingAt) <= 3 * 3600 else {
            followThroughState = AdviceFollowThroughState()
            adviceWorkedTip = nil
            return
        }
        guard snapshot.currentContextTokens <= followThroughState.contextTokens / 2 else { return }
        adviceWorkedTip = AdviceTip(kind: .adviceWorked, level: .good, icon: "sparkles",
            text: "최근 컨텍스트를 정리하신 뒤로 훨씬 가벼워졌어요 — 그 조언 효과가 있었어요.")
        followThroughState = AdviceFollowThroughState()
    }

    /// Evaluate the proactive limit alerts (threshold, trajectory, blocked, reset
    /// timing) once, then act: post notifications (if enabled) and run the optional
    /// auto-resume command when the limit frees up after a block.
    func processLimitAlerts() {
        let now = Date()
        // Always evaluate so rising-edge state advances even when notifications are off.
        let alerts = LimitAlerts.evaluate(
            session: limits?.session5h, weekly: limits?.weekly7d,
            sessionProjection: sessionProjection, weeklyProjection: weeklyProjection,
            status: limits?.status, warnThreshold: warnThreshold,
            blockWarnLeadMinutes: blockWarnLeadMinutes,
            state: &alertState, now: now)

        let toPost = notifyOnWarning ? alerts : []
        if !isQuietNow(now) {
            // Bundle same-tick alerts into one notification so a stack of separate
            // triggers (e.g. skipping two weekly tiers at once) doesn't post a stack
            // of separate banners.
            for a in NotificationBundler.bundle(toPost) {
                // "한도 풀렸어요" gets a one-tap resume action; every other limit
                // nudge/danger gets a one-tap snooze — fyi (the weekly recap, posted
                // separately) carries neither, nothing to act on right now.
                let category: Notifier.Category? =
                    a.id.contains("reset-after-block") ? .freed : (a.urgency != .fyi ? .limit : nil)
                Notifier.notify(title: a.title, body: a.body, id: a.id, urgency: a.urgency, category: category)
            }
        }
        // Auto-resume on the "freed after being blocked" reset (opt-in). With no
        // custom command, default to continuing the last conversation — so just
        // flipping the toggle is enough; no button press needed.
        if autoResumeEnabled, alerts.contains(where: { $0.id == "reset-after-block" }) {
            resumeNow()
        }
    }

    /// Whether proactive notifications should be suppressed right now (ad-hoc
    /// snooze) — the in-app UI keeps reflecting real state regardless.
    func isQuietNow(_ now: Date) -> Bool {
        isSnoozed
    }

    var snoozeUntil: Date? { snoozeUntilEpoch > 0 ? Date(timeIntervalSince1970: snoozeUntilEpoch) : nil }
    var isSnoozed: Bool { snoozeUntil.map { Date() < $0 } ?? false }

    /// One-tap toggle for the header button: snooze for `snoozeDuration`, or cancel
    /// early if already snoozed.
    func toggleSnooze() {
        snoozeUntilEpoch = isSnoozed ? 0 : Date().addingTimeInterval(Self.snoozeDuration).timeIntervalSince1970
    }
}
