import Foundation

/// Refresh lifecycle: the timer, the reset-boundary watcher, the actual network/disk
/// fetch, and the resume/diagnostics actions that hang off a completed cycle.
extension UsageStore {
    /// Live-limit windows filtered through their reset boundary: once `resetsAt`
    /// passes, the cached reading describes the PREVIOUS window (possibly "blocked
    /// at 100%" held all night through sleep) — treat it as unknown until the next
    /// fetch instead of displaying it as current truth.
    var liveSession: LimitWindow? {
        limits?.session5h.flatMap { $0.expired(asOf: Date()) ? nil : $0 }
    }
    var liveWeekly: LimitWindow? {
        limits?.weekly7d.flatMap { $0.expired(asOf: Date()) ? nil : $0 }
    }

    func scheduleResetBoundaryRefresh() {
        resetBoundaryTimer?.invalidate()
        resetBoundaryTimer = nil
        let now = Date()

        let sessionStillStale = limits?.session5h.map { $0.expired(asOf: now) } ?? false
        let weeklyStillStale = limits?.weekly7d.map { $0.expired(asOf: now) } ?? false
        if sessionStillStale || weeklyStillStale, resetConfirmAttempts < Self.maxResetConfirmAttempts {
            resetConfirmAttempts += 1
            let timer = Timer(fire: now.addingTimeInterval(Self.resetConfirmRetryInterval), interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh(force: true) }
            }
            RunLoop.main.add(timer, forMode: .common)
            resetBoundaryTimer = timer
            return
        }
        resetConfirmAttempts = 0

        guard let next = [limits?.session5h?.resetsAt, limits?.weekly7d?.resetsAt]
            .compactMap({ $0 }).filter({ $0 > now }).min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        resetBoundaryTimer = timer
    }

    /// Refresh local usage and (if enabled) the live limits. `force` bypasses the
    /// limits cache TTL — used when the user explicitly hits Refresh.
    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshAttemptAt = Date()
        let reader = self.reader
        let client = self.limitsClient
        let live = enableLiveLimits
        // Always parse the cheap stats cache (for the menu-bar/weekly summary); skip
        // only the heavy session-log scan when the popover is closed and the bar metric
        // is a limit % (driven by `limits` alone). Exception: the "current conversation
        // got heavy" nudge needs `currentSessionId` to stay fresh to be worth anything,
        // so keep scanning every tick while that's on (the per-file parse cache makes
        // repeat scans cheap — only the most recently modified log actually reparses).
        let full = popoverVisible || !barMetric.needsLiveLimits
        let previous = snapshot
        // Near a limit, fetch fresher data (shorter cache TTL) so the warning is
        // timely; when safe, stay gentle on the rate-limited endpoint.
        let ttl: TimeInterval = isAtLimitRisk ? 60 : OAuthUsageClient.cacheTTL
        Task {
            // Timeout-wrapped too (not just the live-limits fetch below): this is
            // plain file I/O and shouldn't hang, but "shouldn't" is exactly what we
            // assumed about the Keychain call before finding out otherwise — nothing
            // in this Task may block `isRefreshing` from resetting indefinitely.
            if let loaded = await withTimeout(seconds: 20, operation: {
                await Task.detached(priority: .utility) { reader.load(includeSessionLogs: full) }.value
            }) {
                var snap = loaded
                if !full { snap = snap.mergingSession(from: previous) }
                self.snapshot = snap
                // Feeds CacheEfficiencyTrend's multi-week "재읽기 비율이 늘고 있어요"
                // read — a single 5h-window snapshot in isolation can't show a trend.
                if let ce = CacheEfficiency.verdict(snap.windowTokens) {
                    CacheEfficiencyHistory.append(freshShare: ce.freshShare, at: snap.generatedAt)
                }
            }
            if live {
                // 20s: comfortably past the network layer's own 15s timeout, so this
                // only ever kicks in for the un-timeoutable case (a blocked Keychain
                // prompt). On timeout, deliberately leave `self.limits` untouched
                // (not nil'd) — this cycle produced nothing new, not "no data."
                if let fresh = await withTimeout(seconds: 20, operation: { await client.loadLimits(force: force, ttl: ttl) }) {
                    self.limits = fresh
                    self.lastRefreshTimedOut = false
                } else {
                    self.lastRefreshTimedOut = true
                }
            } else {
                self.limits = nil
                self.lastRefreshTimedOut = false
            }
            self.scheduleResetBoundaryRefresh()
            self.recomputeProjections()
            self.processLimitAlerts()
            self.processModelDownshiftSuggestion()
            self.processAdviceFollowThrough()
            self.maybeWeeklySummary()
            // If the risk level changed, re-arm the timer at the matching cadence.
            if self.isAtLimitRisk != self.lastUrgent {
                self.lastUrgent = self.isAtLimitRisk
                self.restartTimer()
            }
            self.isRefreshing = false
        }
    }

    func recomputeProjections() {
        guard enableLiveLimits else {
            sessionProjection = nil; weeklyProjection = nil; sessionTrend = []; weeklyTrend = []
            sessionRecapsToday = []; weeklyAllowance = nil; return
        }
        let now = Date()
        let samples = UsageHistory.load()
        // Session-window trend: samples with a session reading from the last 5h, oldest→newest.
        let cutoff = now.addingTimeInterval(-5 * 3600)
        sessionTrend = samples.filter { $0.session != nil && $0.at >= cutoff }.sorted { $0.at < $1.at }
        // Weekly trend: from the coarser, longer-retention store (8 days), not the
        // short-lived `UsageHistory` ring buffer.
        weeklyTrend = WeeklyHistory.load().filter { $0.weekly != nil }.sorted { $0.at < $1.at }
        sessionRecapsToday = SessionCoach.recentSessionRecaps(samples: samples, now: now)
        // Session = rolling 5h window → recent burst rate.
        sessionProjection = Projection.compute(points: samples.compactMap { s in s.session.map { (s.at, $0) } },
                                               resetsAt: liveSession?.resetsAt, now: now)
        // Feeds the personal "usual speed at this hour" baseline (see `HourlyBurnHistory`).
        // Idle/near-zero rates are skipped inside `append` so they don't drag every
        // hour's median toward zero.
        if let rate = sessionProjection?.ratePerHour { HourlyBurnHistory.append(rate: rate, at: now) }
        if let w = liveWeekly {
            // Weekly = fixed 7-day bucket → realized average pace since the week started,
            // blended with a short-burst trajectory so a fast start doesn't go unnoticed
            // for the first 6h (see `Projection.combinedWeekly`).
            let weeklyPoints = samples.compactMap { s in s.weekly.map { (s.at, $0) } }
            weeklyProjection = Projection.combinedWeekly(points: weeklyPoints, util: w.utilization,
                                                          resetsAt: w.resetsAt,
                                                          windowSeconds: 7 * 24 * 3600, now: now)
            let midnight = Calendar.current.startOfDay(for: now)
            // Baseline from the 8-day WeeklyHistory, not the ~12h UsageHistory ring
            // buffer — by afternoon that buffer has evicted every pre-midnight sample
            // and "오늘 사용" silently vanished exactly when it mattered most.
            let todayStartUtil = DailyAllowance.todayBaseline(
                points: weeklyTrend.compactMap { s in s.weekly.map { (at: s.at, util: $0) } },
                midnight: midnight)
            weeklyAllowance = DailyAllowance.verdict(util: w.utilization, resetsAt: w.resetsAt, now: now,
                                                     todayStartUtil: todayStartUtil)
        } else {
            weeklyProjection = nil
            weeklyAllowance = nil
        }
    }

    /// Runs the configured resume command (or the built-in "continue last
    /// conversation" default) right now — the auto-resume toggle's action, also
    /// triggered manually via the "지금 이어가기" notification button. Off the main
    /// actor since resolving the binary/dir spawns a short-lived process.
    func resumeNow() {
        let now = Date()
        guard now.timeIntervalSince(lastAutoResumeAt ?? .distantPast) >= Self.autoResumeCooldown else { return }
        lastAutoResumeAt = now
        let custom = resumeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached(priority: .utility) {
            // Empty → safe built-in (argv, no shell injection). Filled → the user's
            // own shell command (their responsibility), run via the login shell.
            if custom.isEmpty { ResumeCommand.runContinueLast() }
            else { CommandRunner.run(custom) }
        }
    }

    /// Driven by the popover's onAppear/onDisappear: refresh on open and use the
    /// user's interval while visible; back off to the idle cadence when closed.
    func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        if visible { refresh() }
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        guard refreshInterval > 0 else { return }
        let idle = isAtLimitRisk ? Self.urgentIdleInterval : Self.idleInterval
        let interval = popoverVisible ? refreshInterval : max(refreshInterval, idle)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Diagnostics panel's manual fix: clears the cached access token (forcing a
    /// fresh Keychain read next time) and any exponential backoff, then retries
    /// immediately — for when the automatic recovery (timeout + next tick) isn't
    /// enough and the user just wants to force a clean attempt right now.
    func resetCredentialsAndRetry() {
        ClaudeCredentials.invalidate()
        OAuthUsageClient.resetBackoff()
        // Force-clear a possibly-stuck in-flight cycle: this button exists
        // specifically for when the automatic recovery hasn't kicked in, so it
        // must not be silently swallowed by refresh()'s own `!isRefreshing` guard
        // the way every other caller correctly is. Safe — the abandoned old Task,
        // if one is still running, simply has its result discarded when it
        // eventually (if ever) finishes, same as any other timed-out cycle.
        isRefreshing = false
        refresh(force: true)
    }

    /// Whether the live-limits endpoint is currently being backed off from after
    /// consecutive failures, and when the next attempt is allowed — see
    /// `OAuthUsageClient.backoffStatus()`.
    var liveLimitsBackoff: (isBackingOff: Bool, retryAt: Date?) { OAuthUsageClient.backoffStatus() }
}
