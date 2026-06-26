import Foundation

/// One piece of dynamic, situational guidance shown in the popover.
struct AdviceTip: Identifiable, Equatable {
    enum Kind { case sessionPacing, resetImminent, headroom, contextHeavy, weeklyDefer, costModel, watch, healthy }
    enum Level { case good, info, warn, critical }

    let kind: Kind
    let level: Level
    let icon: String
    let text: String
    var id: String { "\(kind)" }   // at most one tip per kind
}

/// Turns the live projections + per-model burn into actionable advice.
///
/// Tone: the limit data is real (token-based, from the usage API), so the advice
/// is deliberately direct and quantified — concrete minutes, *turns*, a target
/// rate, dollars — rather than vague ("천천히 쓰세요"). The only soft number is
/// cost, which is an estimate. Both sides of "limit awareness" are covered:
/// over-pace (you'll be blocked) and under-use (you'll waste the allowance).
enum Advice {
    static func compute(session: Projection?, weekly: Projection?,
                        sessionUtil: Double?, weeklyUtil: Double?,
                        models: [ModelWindowUsage], contextTokens: Int = 0,
                        warnThreshold: Int, now: Date) -> [AdviceTip] {
        var tips: [AdviceTip] = []
        let t = Double(warnThreshold)
        func dur(_ s: TimeInterval?) -> String {
            s.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
        }
        func rate(_ r: Double) -> String { r >= 10 ? "\(Int(r.rounded()))%/h" : String(format: "%.1f%%/h", r) }
        // Rough turn estimate from this window's realized burn (requests per util%).
        let totalRequests = models.reduce(0) { $0 + $1.requests }
        func turns(_ pct: Double) -> Int? {
            guard let u = sessionUtil, u > 1, totalRequests > 0, pct > 0 else { return nil }
            let n = Int((pct * Double(totalRequests) / u).rounded())
            return n > 0 ? n : nil
        }

        // 1) Session over-pace — quantified: when you hit the wall, roughly how many
        //    turns that is, and the exact rate you'd need to drop to to survive.
        if let s = session, s.verdict == .atRisk, let u = sessionUtil {
            let turnPart = turns(100 - u).map { " (≈\($0)턴)" } ?? ""
            var lever = ""
            if let toReset = s.secondsToReset, toReset > 0 {
                let target = max(0, (100 - u) / (toReset / 3600))
                lever = target < 1
                    ? " 리셋까지 버티려면 지금은 멈추는 게 좋아요."
                    : " 리셋까지 버티려면 시간당 \(rate(target))까지 낮추세요(지금 \(rate(s.ratePerHour)))."
            }
            if (s.blockedBy ?? 0) < 600 {   // barely blocked → don't over-alarm
                tips.append(AdviceTip(kind: .sessionPacing, level: .warn, icon: "speedometer",
                    text: "이 속도면 약 \(dur(s.timeToFull))\(turnPart) 뒤 한도가 차요. "
                        + "리셋이 가까워 \(dur(s.blockedBy)) 정도만 막히니 크게 걱정은 마세요."))
            } else {
                tips.append(AdviceTip(kind: .sessionPacing, level: .critical, icon: "exclamationmark.triangle.fill",
                    text: "이 속도면 약 \(dur(s.timeToFull))\(turnPart) 뒤 한도가 차고 \(dur(s.blockedBy)) 동안 막혀요.\(lever)"))
            }
        }

        // 2) Almost there — high, but coasting to a near reset (not at risk). Encourage.
        if let s = session, s.verdict != .atRisk, let u = sessionUtil, u >= t,
           let toReset = s.secondsToReset, toReset > 0, toReset <= 20 * 60 {
            tips.append(AdviceTip(kind: .resetImminent, level: .good, icon: "hourglass.bottomhalf.filled",
                text: "리셋 \(dur(toReset)) 전 — 조금만 버티면 한도가 새로 채워져요. 큰 작업은 그때 돌리세요."))
        }

        // 3) Under-use — you'll leave the allowance on the table (it doesn't roll over).
        if let s = session, s.verdict == .safe, let left = s.headroomAtReset, left >= 25,
           let toReset = s.secondsToReset, toReset >= 3600 {
            let turnPart = turns(left).map { "남은 한도로 약 \($0)턴 더 쓸 수 있어요. " } ?? ""
            tips.append(AdviceTip(kind: .headroom, level: .info, icon: "gauge.medium",
                text: "이 속도면 리셋 때 한도의 약 \(Int(left.rounded()))%가 그냥 날아가요. "
                    + "\(turnPart)미뤘던 무거운 작업을 지금 돌리세요."))
        }

        // 3.5) Heavy context — a concrete way to cut per-turn burn (the only real
        //      limit lever besides slowing down; model choice barely moves it). Shown
        //      whenever the conversation is large and the window is actively in use,
        //      so it pairs with the over-pace tip as the "here's how to fix it" lever.
        if contextTokens >= SessionCoach.heavyContextTokens, (sessionUtil ?? 0) >= 1 {
            let k = contextTokens / 1000
            tips.append(AdviceTip(kind: .contextHeavy, level: .info, icon: "rectangle.compress.vertical",
                text: "이번 대화 컨텍스트가 큼(~\(k)k토큰) — 턴마다 한도를 많이 먹어요. "
                    + "/compact 하거나 새 대화로 시작하면 같은 한도로 더 오래 갈 수 있어요."))
        }

        // 4) Weekly — defer big work; sharper when the pace will blow the week.
        if let wu = weeklyUtil, wu >= t {
            if weekly?.verdict == .atRisk {
                tips.append(AdviceTip(kind: .weeklyDefer, level: .warn, icon: "calendar.badge.exclamationmark",
                    text: "주간 한도 \(Int(wu.rounded()))% — 지금 추세면 리셋(\(dur(weekly?.secondsToReset)) 뒤) 전에 바닥나요. "
                        + "큰 작업은 리셋 후로 미루세요."))
            } else {
                tips.append(AdviceTip(kind: .weeklyDefer, level: .warn, icon: "calendar",
                    text: "주간 한도 \(Int(wu.rounded()))% — \(dur(weekly?.secondsToReset)) 후 리셋. 큰 작업은 리셋 후가 안전해요."))
            }
        }

        // 5) Cost-heavy model — concrete dollars + the exact multiplier.
        let active = models.filter { $0.requests > 0 && $0.cost > 0 }
        let totalCost = active.reduce(0.0) { $0 + $1.cost }
        if active.count >= 2, totalCost > 0.01 {
            func costPerTurn(_ m: ModelWindowUsage) -> Double { m.cost / Double(m.requests) }
            if let top = active.max(by: { $0.cost < $1.cost }),
               let light = active.min(by: { costPerTurn($0) < costPerTurn($1) }),
               top.model != light.model, costPerTurn(light) > 0 {
                let share = top.cost / totalCost
                let mult = costPerTurn(top) / costPerTurn(light)
                if share >= 0.55, mult >= 1.8 {
                    let multText = mult >= 100 ? "100배 넘게" : "약 \(Int(mult.rounded()))배"
                    tips.append(AdviceTip(kind: .costModel, level: .info, icon: "arrow.left.arrow.right",
                        text: "비용의 \(Int((share * 100).rounded()))%가 \(top.model)(\(Fmt.usd(top.cost)))에서 나와요. "
                            + "가벼운 작업만 \(light.model)로 옮기면 턴당 \(multText) 아낍니다."))
                }
            }
        }

        // 6) Nothing urgent → a watch note or reassurance.
        if tips.isEmpty {
            if let su = sessionUtil, su >= t {
                var trend = ""
                if let s = session, s.verdict == .safe, s.ratePerHour > 0 {
                    trend = " (\(rate(s.ratePerHour))로 오르는 중)"
                }
                tips.append(AdviceTip(kind: .watch, level: .info, icon: "eye",
                    text: "세션 \(Int(su.rounded()))% 사용 중\(trend) — 추세를 잠시 지켜보세요."))
            } else if let s = session, s.verdict == .safe || s.verdict == .idle {
                let text = (s.projectedAtReset ?? 0) >= 90
                    ? "거의 다 쓰는 페이스 — 리셋까지 한도를 알뜰하게 쓰고 있어요."
                    : "지금 페이스 여유 있어요 — 리셋 전에 더 써도 됩니다."
                tips.append(AdviceTip(kind: .healthy, level: .good, icon: "checkmark.circle.fill", text: text))
            }
        }

        return Array(tips.prefix(3))
    }
}
