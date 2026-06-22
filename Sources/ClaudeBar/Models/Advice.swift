import Foundation

/// One piece of dynamic, situational guidance shown in the popover.
struct AdviceTip: Identifiable, Equatable {
    enum Kind { case sessionPacing, weeklyDefer, costModel, watch, healthy }
    enum Level { case good, info, warn, critical }

    let kind: Kind
    let level: Level
    let icon: String
    let text: String
    var id: String { "\(kind)" }   // at most one tip per kind
}

/// Turns the live projections + per-model burn into actionable advice.
///
/// Honest about levers: the session/weekly limit is token-based, so when you're
/// about to run out the fix is to *slow down or pause* (model choice barely moves
/// the token total — cache reads dominate). Switching a pricey model only changes
/// *cost*, so that advice is framed as a cost saving.
enum Advice {
    static func compute(session: Projection?, weekly: Projection?,
                        sessionUtil: Double?, weeklyUtil: Double?,
                        models: [ModelWindowUsage], warnThreshold: Int, now: Date) -> [AdviceTip] {
        var tips: [AdviceTip] = []
        func dur(_ t: TimeInterval?) -> String {
            t.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
        }

        // 1) Session pacing — the limit lever.
        if let s = session, s.verdict == .atRisk {
            tips.append(AdviceTip(
                kind: .sessionPacing, level: .critical, icon: "speedometer",
                text: "이 속도면 약 \(dur(s.timeToFull)) 뒤 한도가 차고, 그 뒤 \(dur(s.blockedBy)) 동안은 더 못 써요. "
                    + "잠깐 쉬거나 천천히 쓰는 게 좋아요."))
        }

        // 2) Weekly — defer big work.
        if let wu = weeklyUtil, wu >= Double(warnThreshold) {
            tips.append(AdviceTip(
                kind: .weeklyDefer, level: .warn, icon: "calendar",
                text: "주간 한도 \(Int(wu.rounded()))% — \(dur(weekly?.secondsToReset)) 후 리셋. "
                    + "큰 작업은 리셋 후로 미루면 안전합니다."))
        }

        // 3) Cost-heavy model — the cost lever.
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
                    tips.append(AdviceTip(
                        kind: .costModel, level: .info, icon: "arrow.left.arrow.right",
                        text: "비용의 \(Int((share * 100).rounded()))%가 \(top.model)에서 나와요. "
                            + "\(top.model)은 \(light.model)보다 턴당 \(multText) 비싸니, 가벼운 작업은 \(light.model)로 돌리면 크게 아껴요."))
                }
            }
        }

        // 4) Nothing urgent → a watch note or reassurance.
        if tips.isEmpty {
            if let su = sessionUtil, su >= Double(warnThreshold) {
                tips.append(AdviceTip(kind: .watch, level: .info, icon: "eye",
                    text: "세션 \(Int(su.rounded()))% 사용 중 — 추세를 잠시 지켜보세요."))
            } else if let s = session, s.verdict == .safe || s.verdict == .idle {
                tips.append(AdviceTip(kind: .healthy, level: .good, icon: "checkmark.circle.fill",
                    text: "지금 페이스 괜찮아요 — 리셋까지 여유 있습니다."))
            }
        }

        return Array(tips.prefix(3))
    }
}
