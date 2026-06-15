# ClaudeBar

A lightweight macOS menu-bar app that shows your **Claude (Claude Code) usage** at a
glance — inspired by [CodexBar](https://github.com/steipete/CodexBar), but Claude-only
and intentionally minimal.

By default it reads **local data** (no network) for token/cost stats:

- `~/.claude/stats-cache.json` — all-time sessions/messages + daily token history
- `~/.claude/projects/**/*.jsonl` — per-request token usage with timestamps

Plus an **optional live fetch** of your real plan limits (see
[Live plan limits](#live-plan-limits)). Honors `CLAUDE_CONFIG_DIR`.

## What it shows

- **Menu-bar label** — a sparkle + one at-a-glance number. Defaults to your **Session
  (5h) limit %**; switchable to weekly %, both (`S 60% · W 88%`), 5h tokens/cost, or
  today's tokens/cost. Turns into an orange ⚠︎ when a limit crosses your warning
  threshold, with an optional macOS notification.
- **Plan limits** (live) — your real **Session (5h)** and **Weekly (7d)** usage as
  percentages with reset countdowns, exactly like Claude Code's `/usage`. Falls back to
  a cached value (flagged) if a refresh fails.
- **Burn-rate projection** — tracks your usage over time and tells you whether you'll
  hit the cap *before* the window resets: `▲ 22%/h · full in 1h32m — 2h22m before reset`
  when you're on track to run dry, or `▲ 8%/h · lasts past reset` when you're fine. Lets
  you slow down or switch to a lighter model before getting blocked.
- **5-hour window** — tokens used in the rolling 5h session window, an estimated cost,
  a usage meter against a configurable soft budget, and a countdown to when the window
  first starts to free up.
- **Per-model burn** (5h) — compares each model by share, per-turn weight, a burn
  multiplier vs the lightest model, and "~N turns left if you used only this model."
  Switch the basis in Settings between **total tokens** (rate-limit pressure; default),
  **fresh tokens** (new work, no cache reads), or **cost** — total tokens makes models
  look similar (cache reads dominate), while cost exposes the real gap (e.g. Opus ~2.8×).
- **Today** — tokens, estimated cost, request count, sessions, and tool calls (computed
  live from the session logs).
- **14-day trend** — a sparkline of daily token totals plus a **daily cost** bar chart
  (estimated, with a 14-day total and daily average; per-bar tooltips).
- **All time** — total sessions, total messages, and your first-session date.

> Costs are **estimates** from public list prices. Override per-model rates by creating
> `~/.claudebar/pricing.json` (see [Pricing](#pricing)).

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain / Xcode 16+ (only to build)

## Build & run

```bash
# Quick run during development (debug build, launches the menu-bar app)
./Scripts/run.sh

# Build a distributable, ad-hoc-signed ClaudeBar.app
./Scripts/package_app.sh
open build/ClaudeBar.app          # or: cp -r build/ClaudeBar.app /Applications/
```

The packaged app is menu-bar-only (`LSUIElement`) — no Dock icon. Quit it from the
popover's **Quit** button.

Enable **Settings → General → Launch at login** to start it automatically (uses
`SMAppService`; works once the app is packaged, ideally in `/Applications`).

## Tests

```bash
swift test
```

Covers the pure logic: token/cost formatting, model-name display, pricing, and the
`/api/oauth/usage` response parser.

CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on macOS on every
push to `main` and on pull requests.

## CLI

The same binary doubles as a no-GUI reporter — handy for scripts or a quick check:

```bash
ClaudeBar --print          # human-readable snapshot
ClaudeBar --print --json   # machine-readable
ClaudeBar --help
```

Use `--no-limits` to skip the network call. Example:

```
Plan limits:
  Session 5h       42%  (resets in 4h 21m)
  Weekly 7d        86%  (resets in 106h 11m)

5-hour window:
  Tokens           71.2M  (71,158,491)
  Est. cost        ~$140
  Frees up in      3h 47m

Today:
  Tokens           71.2M
  Requests         423
  Sessions         8
  Tool calls       184
    Fable 5        55.4M  ~$63.82
    Opus 4.8       15.8M  ~$76.41
```

## Live plan limits

The **Plan limits** section shows your real Session (5h) and Weekly (7d) usage — the
same numbers as Claude Code's `/usage`. This is the one feature that uses the network:

- Calls `GET https://api.anthropic.com/api/oauth/usage` with your Claude Code OAuth
  token, `anthropic-beta: oauth-2025-04-20`, and a `claude-code/<version>` User-Agent.
- The token is read from `~/.claude/.credentials.json` if present, otherwise from the
  macOS login Keychain (`Claude Code-credentials`). The **first** fetch may ask your
  permission to read that Keychain item — click *Always Allow* to silence it.
- Responses are cached to `~/.claudebar/usage-cache.json` for 3 minutes (the endpoint
  is rate-limited / 429-prone). On a failed refresh, the last good value is shown and
  flagged with a ⚠︎.

Turn it off in **Settings → Plan limits** to make ClaudeBar fully offline. Note: this
endpoint is **undocumented** and may change without notice.

## Pricing

Cost figures use built-in public list prices per model family (Opus / Sonnet / Haiku /
Fable). To override, create `~/.claudebar/pricing.json` with USD-per-1M-token rates:

```json
{
  "opus":   { "input": 15, "output": 75, "cacheWrite": 18.75, "cacheRead": 1.5 },
  "sonnet": { "input": 3,  "output": 15, "cacheWrite": 3.75,  "cacheRead": 0.3 },
  "default":{ "input": 5,  "output": 20, "cacheWrite": 6.25,  "cacheRead": 0.5 }
}
```

Keys are matched as a substring of the model id (`opus` matches `claude-opus-4-8`);
`default` is the fallback for unmatched models.

## Notes on the "5-hour window"

Claude's plans use a rolling ~5-hour session limit, but Anthropic doesn't publish an
exact token cap and it isn't stored locally. ClaudeBar therefore sums the tokens from
the trailing 5 hours of your session logs and shows them against a **soft budget you
set** in Settings — so the meter reflects *your* sense of "a lot," not a hard limit.
The token totals and the reset countdown are exact; the meter percentage is relative.

## Project layout

```
Package.swift
Sources/ClaudeBar/
  main.swift               # entry: GUI vs --print CLI
  ClaudeBarApp.swift       # MenuBarExtra + accessory app
  CLI.swift                # --print / --json reporter
  Models/   Usage.swift, Pricing.swift, Limits.swift, Projection.swift, ModelBurn.swift, CostEstimator.swift
  Services/ ClaudeDataReader.swift, OAuthUsageClient.swift, UsageStore.swift, LoginItem.swift, Notifier.swift, UsageHistory.swift
  Views/    MenuContentView.swift, SettingsView.swift, Components.swift
  Util/     Formatters.swift
Tests/ClaudeBarTests/   unit tests
Resources/AppIcon.icns  app icon (regenerate with Scripts/make_icon.swift)
Scripts/  run.sh, package_app.sh, make_icon.swift
```
