import Foundation

/// How loudly one alert should be delivered — the quiet-coach rule: coaching
/// whispers, only limit danger speaks.
///  • fyi    — notification list only, no banner, no sound (recaps)
///  • nudge  — banner, no sound (pace/efficiency coaching)
///  • danger — banner + sound (about to be, or actually, blocked)
enum AlertUrgency: Int, Comparable {
    case fyi, nudge, danger
    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// One notification the app should post.
struct LimitAlert: Equatable {
    let id: String
    let title: String
    let body: String
    var urgency: AlertUrgency = .danger
}

/// Rising-edge state so each alert fires once per episode (not every refresh).
/// `UsageStore` owns one of these and threads it through `LimitAlerts.evaluate`.
struct LimitAlertState: Equatable {
    var session = false       // session threshold notified
    var sessionRisk = false   // session projected-to-exhaust notified
    var weeklyRisk = false    // weekly projected-to-exhaust notified
    var blocked = false       // currently-blocked notified
    var wasBlocked = false    // hit the wall since the last reset (→ stronger "freed" alert)
    var resetSoon = false     // session "resets soon" notified
    var paceSlow = false      // under-pace ("you could use more") notified
    var blockImminent = false // session block within the lead time notified
    var weeklyTier = 0        // highest weekly severity tier notified (0 = none)
    var prevSessionUtil: Double?
}

/// Pure decision logic for the proactive limit notifications — "warn before you're
/// blocked". Side-effect-free (returns the alerts to post + mutates rising-edge
/// state) so it can be unit-tested; `UsageStore` performs the actual posting.
///
/// Layers, earliest-warning first:
///  1. trajectory — at this rate you'll hit 100% *before* the window resets
///  2. static threshold — crossed the warn % (e.g. 80%)
///  3. blocked — `rejected` status or a window at 100%
///  4. reset timing — "곧 리셋" (high + <15m) and "리셋됨" (sharp drop from high)
enum LimitAlerts {
    static let resetSoonWindow: TimeInterval = 15 * 60
    static let resetWasHigh = 50.0    // "리셋됨" only matters if you'd been using it
    static let resetNowLow = 20.0     // window resets drop utilization to ~0

    static func evaluate(session: LimitWindow?, weekly: LimitWindow?,
                         sessionProjection: Projection?, weeklyProjection: Projection?,
                         status: String?, warnThreshold: Int,
                         blockWarnLeadMinutes: Int = 30,
                         state: inout LimitAlertState, now: Date) -> [LimitAlert] {
        var out: [LimitAlert] = []
        let t = Double(warnThreshold)
        func countdown(_ secs: TimeInterval) -> String {
            Fmt.countdown(to: now.addingTimeInterval(secs), from: now)
        }
        // A window whose reset boundary has passed describes the PREVIOUS window —
        // its stale utilization must not drive thresholds/tiers/blocked. (The
        // expired-while-blocked case is handled explicitly in section 4: freed by
        // the clock, without waiting for the next successful fetch.)
        let liveSession = session.flatMap { $0.expired(asOf: now) ? nil : $0 }
        let liveWeekly = weekly.flatMap { $0.expired(asOf: now) ? nil : $0 }

        // 1) Trajectory — fires earlier than a static %: you can be at 60% but
        //    burning so fast you'll hit 100% before the reset.
        func risk(_ p: Projection?, name: String, key: String, flag: inout Bool) {
            guard let p = p else { return }
            if p.verdict == .atRisk, !flag {
                flag = true
                let full = p.timeToFull.map(countdown) ?? "곧"
                out.append(LimitAlert(id: "risk-\(key)", title: "\(name) 한도 곧 소진",
                    body: "이 속도면 약 \(full) 뒤 \(name) 한도가 찹니다. 잠깐 쉬거나 천천히 쓰세요."))
            } else if p.verdict != .atRisk { flag = false }
        }
        risk(weeklyProjection, name: "주간", key: "weekly", flag: &state.weeklyRisk)

        // 1b) Session trajectory, split by urgency around the user's lead time:
        //     • beyond the lead time → an early heads-up ("곧 소진")
        //     • within the lead time → the sharp "act now" warning ("곧 막힘 · ~N분 후")
        //     Mutually exclusive by time-to-full, so you get the early note then the
        //     imminent one — never both at once. Both clear when the risk passes.
        if let p = sessionProjection, p.verdict == .atRisk, let ttf = p.timeToFull, ttf > 0 {
            let lead = TimeInterval(max(1, blockWarnLeadMinutes) * 60)
            if ttf <= lead {
                if !state.blockImminent {
                    state.blockImminent = true
                    out.append(LimitAlert(id: "block-imminent", title: "세션 한도 곧 막힘",
                        body: "이 속도면 약 \(countdown(ttf)) 뒤 막혀요. 지금 마무리하거나 속도를 늦추세요(/compact도 도움)."))
                }
            } else if !state.sessionRisk {
                state.sessionRisk = true
                out.append(LimitAlert(id: "risk-session", title: "세션 한도 곧 소진",
                    body: "이 속도면 약 \(countdown(ttf)) 뒤 세션 한도가 찹니다. 잠깐 쉬거나 천천히 쓰세요.",
                    urgency: .nudge))   // early heads-up; the imminent one is the loud one
            }
        } else {
            state.sessionRisk = false
            state.blockImminent = false
        }

        // 2) Static threshold crossing.
        func threshold(_ w: LimitWindow?, name: String, key: String, flag: inout Bool) {
            guard let u = w?.utilization else { return }
            if u >= t, !flag {
                flag = true
                out.append(LimitAlert(id: "limit-\(key)", title: "\(name) 한도 \(Int(u.rounded()))%",
                    body: "\(name) 한도의 \(warnThreshold)%를 넘었습니다."))
            } else if u < t { flag = false }
        }
        threshold(liveSession, name: "세션", key: "session", flag: &state.session)

        // 2b) Weekly severity tiers — a weekly block costs days (not hours, like the
        //     session), so escalate earlier and more granularly than the shared
        //     warnThreshold: 50/75/90%, each firing once as it's crossed upward.
        //     Resetting to 0% (a new week) naturally re-arms every tier.
        let weeklyTiers: [(pct: Double, label: String)] = [(50, "절반"), (75, "3/4"), (90, "거의 다")]
        if let u = liveWeekly?.utilization {
            let crossed = weeklyTiers.lastIndex(where: { u >= $0.pct }).map { $0 + 1 } ?? 0
            // Emit every tier skipped since the last check (a big single jump shouldn't
            // silently swallow the lower tiers), not just the highest one now crossed.
            if crossed > state.weeklyTier {
                for i in (state.weeklyTier + 1)...crossed {
                    let tier = weeklyTiers[i - 1]
                    out.append(LimitAlert(id: "weekly-tier-\(Int(tier.pct))",
                        title: "주간 한도 \(Int(tier.pct))% — \(tier.label) 사용",
                        body: "주간 한도의 \(Int(tier.pct))%를 썼어요. 남은 기간에 맞춰 페이스를 조절하세요.",
                        urgency: tier.pct >= 90 ? .danger : .nudge))   // 50/75 = pace info, 90 = danger
                }
            }
            state.weeklyTier = crossed
        } else if weekly?.expired(asOf: now) == true {
            // Boundary passed → a new week began. Zero the tier now so last week's
            // high-water mark can't swallow the new week's early crossings when the
            // first fresh reading arrives already past 50% (e.g. after days offline).
            state.weeklyTier = 0
        }

        // 3) Actually blocked right now. Trust a cached `rejected` only while some
        //    un-expired window still backs it — after every boundary has passed,
        //    "blocked" is exactly the stale reading expiry exists to neutralize.
        let allExpired = (session != nil || weekly != nil) && liveSession == nil && liveWeekly == nil
        let maxUtil = max(liveSession?.utilization ?? 0, liveWeekly?.utilization ?? 0)
        let blocked = (status == "rejected" && !allExpired) || maxUtil >= 100
        if blocked {
            state.wasBlocked = true   // remembered until the next reset, for a punchier "freed" alert
            if !state.blocked {
                state.blocked = true
                // Live windows only: an expired session's past resetsAt would render
                // as "곧 리셋" when the actual wait is the weekly window, days away.
                let reset = liveSession?.resetsAt ?? liveWeekly?.resetsAt
                let when = reset.map { "\(Fmt.countdown(to: $0, from: now)) 후 리셋" } ?? "곧 리셋"
                out.append(LimitAlert(id: "blocked", title: "한도 도달 — 지금 막힘",
                    body: "지금은 한도에 막혔습니다. \(when)."))
            }
        } else {
            state.blocked = false
        }

        // 3b) Under-pace: actively burning but on track to leave a lot of the window
        // unused (it doesn't roll over). Opt-in; gated in UsageStore by its own toggle.
        // Hysteresis (fire ≤55%, clear ≥70%) avoids flapping; idle verdict won't fire,
        // so simply stepping away doesn't nag.
        // Don't tell the user to "run heavy work now" (session headroom) while the
        // WEEKLY limit is the binding constraint — that's the same contradiction the
        // advice card guards against, just in notification form. Weekly at/over the
        // warn threshold or at risk suppresses the under-pace nudge.
        let weeklyBinding = (liveWeekly?.utilization ?? 0) >= t || weeklyProjection?.verdict == .atRisk
        if let sp = sessionProjection, sp.verdict == .safe,
           let proj = sp.projectedAtReset,
           let toReset = sp.secondsToReset, toReset >= 3600,
           (liveSession?.utilization ?? 0) >= 10, proj <= 55, !weeklyBinding, !state.paceSlow {
            state.paceSlow = true
            out.append(LimitAlert(id: "pace-slow", title: "한도 여유 많아요",
                body: "이 페이스면 리셋 때 한도의 약 \(Int((100 - proj).rounded()))%가 남아요. 무거운 작업을 지금 돌려도 좋아요.",
                urgency: .nudge))
        } else if weeklyBinding || (sessionProjection?.projectedAtReset ?? 100) >= 70 || sessionProjection?.verdict != .safe {
            state.paceSlow = false
        }

        // 4) Session reset timing — the 5h cycle is what active work bumps into.
        if let s = session {
            if s.expired(asOf: now) {
                // Boundary passed but no fresh fetch yet (offline / just woke from
                // sleep): freed by the clock. Fire the reset alerts NOW instead of
                // waiting for a successful refetch to reveal the drop — but only if
                // nothing ELSE still blocks: with the weekly window at 100%, "다시
                // 시작하세요" (and its auto-resume command) would be wrong, and would
                // refire every tick as section 3 re-arms wasBlocked.
                if !blocked, state.wasBlocked {
                    // Distinct id: also the trigger for optional auto-resume (see UsageStore).
                    out.append(LimitAlert(id: "reset-after-block", title: "한도 풀렸어요 — 다시 시작하세요",
                        body: "막혔던 세션 한도가 초기화됐어요. 지금 바로 이어서 작업하세요."))
                    state.wasBlocked = false
                } else if !blocked, let prev = state.prevSessionUtil, prev >= resetWasHigh {
                    out.append(LimitAlert(id: "reset-done", title: "세션 한도 리셋됨",
                        body: "세션 한도가 초기화됐어요 — 다시 쓸 수 있습니다.", urgency: .nudge))
                }
            } else {
                if let reset = s.resetsAt {
                    let secs = reset.timeIntervalSince(now)
                    if s.utilization >= t, secs > 0, secs <= resetSoonWindow, !state.resetSoon {
                        state.resetSoon = true
                        out.append(LimitAlert(id: "reset-soon", title: "세션 한도 곧 리셋",
                            body: "\(Fmt.countdown(to: reset, from: now)) 뒤 풀립니다. 큰 작업은 잠깐 기다리면 돼요.",
                            urgency: .nudge))
                    } else if secs > resetSoonWindow {
                        state.resetSoon = false
                    }
                }
                // Sharp drop from a high level → the window just reset. Naturally
                // one-shot: next tick `prevSessionUtil` is already low. If we'd hit the
                // wall, make it an action prompt to resume right away (the dead time is over).
                if let prev = state.prevSessionUtil, prev >= resetWasHigh, s.utilization < resetNowLow {
                    if state.wasBlocked {
                        // Distinct id: also the trigger for optional auto-resume (see UsageStore).
                        out.append(LimitAlert(id: "reset-after-block", title: "한도 풀렸어요 — 다시 시작하세요",
                            body: "막혔던 세션 한도가 초기화됐어요. 지금 바로 이어서 작업하세요."))
                    } else {
                        out.append(LimitAlert(id: "reset-done", title: "세션 한도 리셋됨",
                            body: "세션 한도가 초기화됐어요 — 다시 쓸 수 있습니다.", urgency: .nudge))
                    }
                    state.wasBlocked = false
                }
            }
        }
        // nil while expired, so the eventual fresh low reading doesn't look like a
        // "sharp drop" and re-fire the reset alerts a second time.
        state.prevSessionUtil = liveSession?.utilization

        return out
    }
}
