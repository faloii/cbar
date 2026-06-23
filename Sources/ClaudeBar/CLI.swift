import Foundation

enum CLI {
    static func printHelp() {
        print("""
        ClaudeBar — lightweight Claude usage in your menu bar.

        Usage:
          ClaudeBar              Launch the menu-bar app
          ClaudeBar --print      Print the current usage snapshot and exit
          ClaudeBar --print --json   Same, as JSON
          ClaudeBar --print --no-limits   Skip the live session/weekly limit fetch
          ClaudeBar --help       Show this help

        Reads Claude Code's local data only (no network):
          stats-cache.json + projects/**/*.jsonl under $CLAUDE_CONFIG_DIR (~/.claude).
        """)
    }

    static func printSnapshot(json: Bool) {
        let snap = ClaudeDataReader().load()
        let limits = CommandLine.arguments.contains("--no-limits") ? nil : fetchLimitsBlocking()
        if json {
            printJSON(snap, limits)
        } else {
            printText(snap, limits)
        }
    }

    /// Run the async limits fetch to completion from the synchronous CLI path.
    private static func fetchLimitsBlocking() -> LimitsSnapshot {
        let sem = DispatchSemaphore(value: 0)
        let box = LimitsBox()
        Task {
            box.value = await OAuthUsageClient().loadLimits()
            sem.signal()
        }
        sem.wait()
        return box.value ?? LimitsSnapshot(fetchedAt: Date(), error: "fetch failed")
    }

    private final class LimitsBox: @unchecked Sendable { var value: LimitsSnapshot? }

    /// The per-model burn basis saved by the GUI (defaults to total tokens).
    private static func savedBurnBasis() -> BurnBasis {
        BurnBasis(rawValue: UserDefaults.standard.string(forKey: "burnBasis") ?? "") ?? .totalTokens
    }

    /// Short human-readable burn-rate note for the CLI, or nil to print nothing.
    private static func projectionNote(_ p: Projection, now: Date) -> String? {
        func rate() -> String { p.ratePerHour >= 10 ? "\(Int(p.ratePerHour.rounded()))%/h" : String(format: "%.1f%%/h", p.ratePerHour) }
        switch p.verdict {
        case .measuring: return "↗ measuring rate…"
        case .idle:      return "↗ not burning"
        case .safe:      return "↗ \(rate()) · lasts past reset"
        case .atRisk:
            let full = p.timeToFull.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
            let gap = p.blockedBy.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
            return "↗ \(rate()) · full in \(full) — \(gap) before reset ⚠"
        }
    }

    private static func printText(_ s: UsageSnapshot, _ limits: LimitsSnapshot?) {
        func line(_ l: String, _ v: String) { print("  \(l.padding(toLength: 16, withPad: " ", startingAt: 0)) \(v)") }

        print("ClaudeBar — \(Fmt.time(s.generatedAt))\n")

        if let l = limits {
            print("Plan limits\(l.stale ? " (cached)" : ""):")
            let now = s.generatedAt
            func limit(_ name: String, _ w: LimitWindow?, _ proj: Projection?) {
                guard let w else { return }
                var v = String(format: "%.0f%%", w.utilization)
                if let r = w.resetsAt { v += "  (resets in \(Fmt.countdown(to: r, from: now)))" }
                line(name, v)
                if let p = proj, let note = projectionNote(p, now: now) { line("", note) }
            }
            if l.hasData {
                let sp = Projection.compute(points: UsageHistory.sessionPoints(), resetsAt: l.session5h?.resetsAt, now: now)
                let wp = l.weekly7d.map { Projection.paced(util: $0.utilization, resetsAt: $0.resetsAt,
                                                           windowSeconds: 7 * 24 * 3600, now: now) }
                limit("Session 5h", l.session5h, sp)
                limit("Weekly 7d", l.weekly7d, wp)
                limit("Weekly Opus", l.weeklyOpus, nil)
            } else {
                line("(unavailable)", l.error ?? "no data")
            }
            print("")
        }

        print("5-hour window:")
        line("Tokens", Fmt.tokens(s.windowTokens.total) + "  (\(Fmt.int(s.windowTokens.total)))")
        line("Est. cost", "~" + Fmt.usd(s.windowCost))
        if let reset = s.windowResetAt {
            line("Frees up in", Fmt.countdown(to: reset, from: s.generatedAt))
        }

        let basis = savedBurnBasis()
        let burn = ModelBurn.rows(window: s.windowByModel,
                                  sessionUtil: limits?.session5h?.utilization,
                                  basis: basis)
        if !burn.isEmpty {
            print("\nPer-model burn (last 5h, by \(basis.shortLabel)):")
            for r in burn {
                var v = String(format: "%3d%%  %@  %.1f×",
                               Int((r.shareFraction * 100).rounded()),
                               basis.formatPerTurn(r.perTurnWeight),
                               r.burnMultiplier)
                if basis != .cost { v += "  ~\(Fmt.usd(r.cost))" }
                if let s = r.limitSharePerTurn { v += String(format: "  %.2f%%/turn of limit", s) }
                line(r.model, v)
            }
        }

        print("\nToday:")
        line("Tokens", Fmt.tokens(s.todayTokens.total))
        line("Est. cost", "~" + Fmt.usd(s.todayCost))
        line("Requests", Fmt.int(s.todayRequests))
        line("Sessions", Fmt.int(s.todaySessions))
        line("Tool calls", Fmt.int(s.todayToolCalls))
        for m in s.todayByModel {
            line("  " + m.model, Fmt.tokens(m.tokens.total) + "  ~" + Fmt.usd(m.cost))
        }

        let recent = s.dailyCostHistory.suffix(7)
        if !recent.isEmpty {
            let total = recent.reduce(0) { $0 + $1.cost }
            print("\nDaily cost (est., last \(recent.count)):")
            for d in recent {
                line(d.date, "~\(Fmt.usd(d.cost))  \(Fmt.tokens(d.tokens))")
            }
            line("total", "~" + Fmt.usd(total))
        }

        print("\nAll time:")
        line("Sessions", Fmt.int(s.totalSessions))
        line("Messages", Fmt.int(s.totalMessages))
        if let first = s.firstSessionDate { line("Since", Fmt.shortDate(first)) }
    }

    private static func printJSON(_ s: UsageSnapshot, _ limits: LimitsSnapshot?) {
        func windowObj(_ w: LimitWindow?) -> Any {
            guard let w else { return NSNull() }
            return [
                "utilization": w.utilization,
                "resetsAt": w.resetsAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
            ]
        }
        var obj: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: s.generatedAt),
            "window": [
                "tokens": s.windowTokens.total,
                "input": s.windowTokens.input,
                "output": s.windowTokens.output,
                "cacheWrite": s.windowTokens.cacheWrite,
                "cacheRead": s.windowTokens.cacheRead,
                "costEstimate": s.windowCost,
                "resetAt": s.windowResetAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
            ],
            "today": [
                "tokens": s.todayTokens.total,
                "costEstimate": s.todayCost,
                "requests": s.todayRequests,
                "sessions": s.todaySessions,
                "toolCalls": s.todayToolCalls,
                "byModel": s.todayByModel.map { ["model": $0.model, "tokens": $0.tokens.total, "costEstimate": $0.cost] },
            ],
            "allTime": [
                "sessions": s.totalSessions,
                "messages": s.totalMessages,
            ],
            "dailyCost": s.dailyCostHistory.map { ["date": $0.date, "tokens": $0.tokens, "costEstimate": $0.cost] },
            "perModelBurn": ModelBurn.rows(window: s.windowByModel,
                                           sessionUtil: limits?.session5h?.utilization,
                                           basis: savedBurnBasis()).map { r in
                [
                    "model": r.model,
                    "tokens": r.tokens,
                    "share": r.shareFraction,
                    "perTurnWeight": r.perTurnWeight,
                    "burnMultiplier": r.burnMultiplier,
                    "costEstimate": r.cost,
                    "limitSharePerTurn": r.limitSharePerTurn as Any,
                ]
            },
            "burnBasis": savedBurnBasis().rawValue,
        ]
        if let l = limits {
            obj["planLimits"] = [
                "fetchedAt": ISO8601DateFormatter().string(from: l.fetchedAt),
                "stale": l.stale,
                "error": l.error as Any,
                "session5h": windowObj(l.session5h),
                "weekly7d": windowObj(l.weekly7d),
                "weeklyOpus": windowObj(l.weeklyOpus),
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
