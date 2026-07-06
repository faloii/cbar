# CBar

A lightweight macOS menu-bar app that shows your **Claude (Claude Code) usage** at a
glance — inspired by [CodexBar](https://github.com/steipete/CodexBar), but Claude-only
and intentionally minimal. Philosophy: a quiet coach that helps you use Claude without
getting blocked by limits, without waste, and honestly about what it can and can't see.

By default it reads **local data** (no network) for token/cost stats:

- `~/.claude/stats-cache.json` — all-time sessions/messages + daily token history
- `~/.claude/projects/**/*.jsonl` — per-request token usage with timestamps

Plus an **optional live fetch** of your real plan limits (see
[Live plan limits](#live-plan-limits)). Honors `CLAUDE_CONFIG_DIR`.

> The app UI is in **Korean**; the `--print`/`--json` CLI output stays in English.

## ⚠️ Disclaimer (please read before using)

- **Unofficial.** CBar is a community tool — **not affiliated with, endorsed by, or
  supported by Anthropic**. "Claude" is a trademark of Anthropic, used here only to
  describe what the tool works with.
- **Undocumented endpoint.** Live plan limits come from an **undocumented** Anthropic
  usage endpoint, called with your own OAuth token and a Claude-Code-style `User-Agent`.
  This may be contrary to Anthropic's Terms of Service, may rate-limit you, and **can
  break at any time without notice**. The local-data stats work without it.
- **Optional auto-resume runs a shell command.** The "auto-resume on reset" feature
  (off by default) runs a command you configure when your session limit frees up. Only
  what you configure runs.
- **Use at your own risk.** Cost figures are estimates based on public list prices.

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
- **Menu-bar mini gauge** — when safely under your warning threshold, the idle icon is a
  tiny ring showing the worse of session/weekly utilization instead of a static glyph.
- **Daily allowance / weekly recap** — "how much can I safely use *today*" turns the
  abstract weekly % into a concrete daily budget, and a notification fires right when the
  weekly window actually resets (not an arbitrary timer) summarizing the week that ended.
- **Per-session /compact hints** — flags which conversation is heavy (big context +
  mostly re-reading old turns) and, opt-in, nudges you once when the conversation you're
  *currently* in crosses that line.
- **Model downshift nudge** (opt-in) — when Opus is doing light work in the current 5h
  window, suggests Sonnet would likely be enough — a cost lever, not a limit lever (token
  usage against your session cap is identical either way).
- **Quiet coach delivery** — only real limit danger makes a sound; coaching nudges are
  silent banners, and the weekly recap goes straight to Notification Center. Notification
  actions ("2시간 조용히" / "지금 이어가기") let you snooze or resume without opening the
  popover. Quiet hours + an ad-hoc 2h snooze suppress notifications on demand (the
  menu-bar icon and popover still show real state).
- **최근 알림 (Notification history)** — opt-in card listing the last few notifications
  CBar posted, a safety net for passive ones you might not have seen banner for.

> Costs are **estimates** from public list prices. Override per-model rates by creating
> `~/.claudebar/pricing.json` (see [Pricing](#pricing)).

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain / Xcode 16+ (only to build — prebuilt DMGs need no toolchain)
- Currently built **Apple Silicon (arm64) only**; ping the maintainer if you need an
  Intel/universal build

## Install a prebuilt DMG

Grab the latest `CBar-<version>.dmg` from whoever shared it with you (or build one
yourself, see below) and:

1. Drag `CBar.app` into `/Applications`.
2. **Right-click → Open** the first time (not a double-click) — macOS Gatekeeper blocks
   an unnotarized app on first launch; this one-time step clears it permanently. If you
   see "damaged, can't be opened" instead, run `xattr -cr /Applications/CBar.app` once.
3. Look for the icon in the menu bar.

CBar only reads **your own** local Claude Code data/credentials — nothing is shared
between machines or users.

## Build & run

```bash
# Quick run during development (debug build, launches the menu-bar app)
./Scripts/run.sh

# Install into /Applications and launch (build + copy + open)
./Scripts/install.sh

# Or just build a distributable CBar.app without installing
./Scripts/package_app.sh
open build/CBar.app          # or: cp -r build/CBar.app /Applications/

# Package a .dmg (build/CBar-<version>.dmg) — version comes from the VERSION file
./Scripts/make_dmg.sh

# Cut a release: bump VERSION, commit, tag, and build the DMG in one step
./Scripts/release.sh 1.2.0
```

### Distribution / notarization

`package_app.sh` signs with a stable identity (Developer ID preferred, else Apple
Development; override via `CLAUDEBAR_SIGN_IDENTITY`). To share the `.dmg` to other Macs
without a Gatekeeper warning it must be **notarized**, which needs a paid Apple Developer
account (a *Developer ID Application* certificate):

```bash
CLAUDEBAR_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./Scripts/make_dmg.sh
xcrun notarytool store-credentials claudebar-notary --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
./Scripts/notarize.sh
```

For personal use this isn't needed — the stable Apple Development signature is enough to
run locally (approve the Keychain prompt once with *Always Allow*). If you hand an
**un-notarized** build to someone else, macOS Gatekeeper will block it; they can run it
once via **right-click → Open** (or *System Settings → Privacy & Security → Open Anyway*)
— see [Install a prebuilt DMG](#install-a-prebuilt-dmg).

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
push to `main` and on pull requests. Pushing a `v*` tag (e.g. via `Scripts/release.sh`)
additionally builds a DMG and attaches it to a GitHub Release
(`.github/workflows/release.yml`).

## CLI

The same binary doubles as a no-GUI reporter — handy for scripts or a quick check:

```bash
CBar --print          # human-readable snapshot
CBar --print --json   # machine-readable
CBar --help
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

Turn it off in **Settings → Plan limits** to make CBar fully offline. Note: this
endpoint is **undocumented** and may change without notice.

Session/weekly limit % come from Anthropic's server and reflect your **whole account**
(all machines). Everything else — context size, per-model burn, per-project/per-session
stats — is derived from **this Mac's** Claude Code logs only; if you also work from
another machine, that usage isn't included in those numbers.

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
exact token cap and it isn't stored locally. CBar therefore sums the tokens from
the trailing 5 hours of your session logs and shows them against a **soft budget you
set** in Settings — so the meter reflects *your* sense of "a lot," not a hard limit.
The token totals and the reset countdown are exact; the meter percentage is relative.

## Project layout

```
Package.swift
Sources/ClaudeBar/
  main.swift               # entry: GUI vs --print CLI
  ClaudeBarApp.swift       # MenuBarExtra + accessory app + notification delegate
  CLI.swift                # --print / --json reporter
  Models/                  # pure, unit-tested logic — no I/O
    Usage.swift, Limits.swift, Projection.swift, Pricing.swift, CostEstimator.swift
    LimitAlerts.swift, NotificationBundler.swift, QuietHours.swift, UpcomingResets.swift
    DailyAllowance.swift, CacheEfficiency.swift, ModelBurn.swift, ModelRecap.swift
    ModelDownshiftSuggestion.swift, CompactSuggestion.swift, WeeklyResetRecap.swift
    WeeklyReview.swift, NotificationLog.swift, SessionCoach.swift, Advice.swift
    Budget.swift, ModelTier.swift
  Services/                # stateful orchestration / I/O
    ClaudeDataReader.swift, OAuthUsageClient.swift, UsageStore.swift
    UsageHistory.swift, WeeklyHistory.swift, Notifier.swift, LoginItem.swift
    CommandRunner.swift, PowerAssertion.swift
  Views/    MenuContentView.swift, SettingsView.swift, Components.swift
  Util/     Formatters.swift, SettingsOpener.swift
Tests/ClaudeBarTests/   unit tests (Models/ logic + the /api/oauth/usage parser)
Resources/AppIcon.icns  app icon (regenerate with Scripts/make_icon.swift)
VERSION                 app version (read by the packaging scripts)
Scripts/  run.sh, install.sh, package_app.sh, make_icon.swift, make_dmg.sh,
          notarize.sh, release.sh
```
