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

    private static func printText(_ s: UsageSnapshot, _ limits: LimitsSnapshot?) {
        func line(_ l: String, _ v: String) { print("  \(l.padding(toLength: 16, withPad: " ", startingAt: 0)) \(v)") }

        print("ClaudeBar — \(Fmt.time(s.generatedAt))\n")

        if let l = limits {
            print("Plan limits\(l.stale ? " (cached)" : ""):")
            func limit(_ name: String, _ w: LimitWindow?) {
                guard let w else { return }
                var v = String(format: "%.0f%%", w.utilization)
                if let r = w.resetsAt { v += "  (resets in \(Fmt.countdown(to: r, from: s.generatedAt)))" }
                line(name, v)
            }
            if l.hasData {
                limit("Session 5h", l.session5h)
                limit("Weekly 7d", l.weekly7d)
                limit("Weekly Opus", l.weeklyOpus)
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

        print("\nToday:")
        line("Tokens", Fmt.tokens(s.todayTokens.total))
        line("Est. cost", "~" + Fmt.usd(s.todayCost))
        line("Requests", Fmt.int(s.todayRequests))
        line("Sessions", Fmt.int(s.todaySessions))
        line("Tool calls", Fmt.int(s.todayToolCalls))
        for m in s.todayByModel {
            line("  " + m.model, Fmt.tokens(m.tokens.total) + "  ~" + Fmt.usd(m.cost))
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
