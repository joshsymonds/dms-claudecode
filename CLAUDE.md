# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A plugin for [DMS (Dank Material Shell)](https://github.com/AvengeMedia/DankMaterialShell) — a Quickshell-based desktop shell. The plugin renders a taskbar pill + popout that surfaces Claude Code subscription usage (rate limits, token counts, estimated API costs, daily activity).

There is no compile step. Files are loaded directly by DMS when the plugin is installed at `~/.config/DankMaterialShell/plugins/claudeCodeUsage`.

## Architecture

Two components communicate over `stdout` via simple `KEY=VALUE` lines:

1. **`get-claude-usage`** (bash) — the data collector. Run periodically by the QML widget. Sources:
   - `~/.claude/.credentials.json` → OAuth token + subscription tier
   - `https://api.anthropic.com/api/oauth/usage` → 5-hour and 7-day rate-window utilization (cached 120s in `~/.claude/usage-cache.json`, with stale fallback on errors)
   - `~/.claude/projects/**/*.jsonl` → per-message token consumption (single `find | jq | awk` pipeline, last 31 days only via `-mtime -31`)
   - LiteLLM model price catalog + Frankfurter USD→EUR rate (refreshed once/day, cached in `~/.claude/pricing-cache.json`)
   - `~/.claude/stats-cache.json` → all-time session/message counts (read-only; written by something else)

2. **`claude-usage-summary`** (bash) — per-host, per-profile transcript summarizer. Scans `$HOME/.claude{,-work}/projects/**/*.jsonl` (same `find | jq | awk` shape as `get-claude-usage` but scoped to one profile), emits a single JSON file at `--out PATH`. Invoked by a systemd user timer on each host that runs Claude. The DMS widget on the bar host doesn't run this directly — `get-claude-usage` reads the resulting summary.json files from `/mnt/claude/${HOST}/{personal,work}/summary.json` instead of crawling every host's JSONL itself. Keeps the NAS platter drives quiet during widget polling.

3. **`ClaudeCodeUsageWidget.qml`** — the UI. A `PluginComponent` that runs `get-claude-usage` via `Process` on a timer (`refreshInterval` minutes), parses each stdout line in `parseLine()`, and renders the pill + popout. Imports `qs.Common`, `qs.Services`, `qs.Widgets`, `qs.Modules.Plugins` from DMS — these are not in this repo and only resolve at runtime inside DMS.

3. **`ClaudeCodeUsageSettings.qml`** — settings panel exposing `refreshInterval` (2–15 min).

4. **`translations.js`** — EN/FR strings, loaded via `import "translations.js" as Tr` and `Tr.tr(key, lang)`. Locale detected from `Qt.locale().name`.

5. **`plugin.json`** — DMS plugin manifest (id, version, capabilities, required binaries).

### Bash → QML contract

The bash script's only output that the widget reads is its `KEY=VALUE` stdout lines (see the `echo` block at the bottom of `get-claude-usage` and the `switch` in `parseLine()` in the widget). When adding a field, it must be written in BOTH places, or it will silently be ignored.

`WEEK_MODELS` is encoded `family:tokens,family:tokens,...` and `DAILY` / `DAILY_COSTS` are 7 comma-separated values for **calendar week Monday→Sunday** (not rolling). This is computed in the awk pass using `WEEK_START` derived from `date +%u`.

### Dynamic model pricing

Pricing is **not** hardcoded. `refresh_pricing()` greps the LiteLLM JSON for keys matching `^claude-[a-z]+-[0-9]+-[0-9]+$`, groups by family (the second hyphen-segment, e.g. `opus`/`sonnet`/`haiku`), and keeps the lexicographically-latest version per family. Token usage is bucketed the same way — the awk script extracts `family = mparts[2]` from `claude-{family}-{version}-...` model names. New families work without code changes; the model identifier scheme is the load-bearing assumption.

## Common commands

```bash
# Run the data collector locally (uses real ~/.claude data)
./get-claude-usage

# Run all tests (matches CI)
for t in tests/test-*.sh; do bash "$t"; done

# Run a single test file
bash tests/test-get-claude-usage.sh

# ShellCheck (matches CI)
shellcheck get-claude-usage tests/*.sh
```

Tests are pure bash + Node and require only `jq` and `node`. `test-get-claude-usage.sh` builds an isolated `$HOME` under a `mktemp -d` and prepends a mock `curl` to `$PATH` so no real network calls happen. `test-qml-functions.sh` extracts pure-JS helper functions (`formatTokens`, `formatCost`, `formatTier`, `progressColor`, `shortModelName`) from the QML file and exercises them under Node.

There is no QML runtime in CI. `test-qml-syntax.sh` is text-level only (checks imports, flags suspect millisecond arithmetic). Real QML behavior must be verified by installing the plugin into DMS.

## CI / release flow

`.github/workflows/ci.yml` runs ShellCheck + tests on every push/PR. On `master`, if any of `get-claude-usage`, `*.qml`, `translations.js`, `plugin.json` changed (and the commit isn't already a version bump), a `version-bump` job opens a PR bumping the patch version in `plugin.json`. Don't manually edit `plugin.json.version` — let the workflow do it.

## Conventions worth noting

- Avoid bare millisecond date arithmetic against `Date.now()` — `test-qml-syntax.sh` flags `86400000` outside duration-formatting contexts (`remaining`, `elapsed`, `duration`, `diff`).
- The bash script uses `set -eu` (no `-o pipefail`); failures inside the big `find | jq | awk` pipeline are intentionally tolerated so partial data still renders.
- Shell out to `claude --version` is wrapped in `|| echo "2.0.0"` — assume the user may not have `claude` on `$PATH`.
