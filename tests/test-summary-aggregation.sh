#!/usr/bin/env bash
# Tests for the cross-host aggregation in get-claude-usage:
# - reading multiple summary.json files from CLAUDE_SUMMARIES_DIR
# - summing into WEEK/MONTH/DAILY/HOST_BREAKDOWN
# - 7-day projection math (PROJECTED_SEVEN_DAY / DELTA / ELAPSED_FRAC)
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/get-claude-usage"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi; }
get_kv() { echo "$1" | grep "^${2}=" | head -1 | cut -d= -f2-; }

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Mock curl: empty API response, forces all OAuth-derived fields to defaults.
cat > "$TMPDIR_ROOT/curl" << 'EOF'
#!/usr/bin/env bash
echo '{}'
EOF
chmod +x "$TMPDIR_ROOT/curl"

# Helper: write a summary.json with the given fields.
# Args: host today_tokens today_cost week_tokens week_cost week_msgs week_sess
#       month_tokens month_cost daily_tokens_csv daily_costs_csv week_models_json
write_summary() {
    local host="$1" out="$2"
    local today_t="$3" today_c="$4" week_t="$5" week_c="$6" week_m="$7" week_s="$8"
    local month_t="$9" month_c="${10}" daily_t="${11}" daily_c="${12}" models="${13}"
    mkdir -p "$(dirname "$out")"
    cat > "$out" << EOF
{
  "host": "$host",
  "profile": "personal",
  "generated_at": "2026-05-23T20:00:00Z",
  "today_tokens": $today_t,
  "today_cost_usd": $today_c,
  "today_per_model": {},
  "week_tokens": $week_t,
  "week_cost_usd": $week_c,
  "week_messages": $week_m,
  "week_sessions": $week_s,
  "week_per_model": $models,
  "month_tokens": $month_t,
  "month_cost_usd": $month_c,
  "daily_tokens": [$daily_t],
  "daily_costs": [$daily_c]
}
EOF
}

run_with_summaries() {
    local sum_dir="$1" home_dir="$2"
    mkdir -p "$home_dir/.claude/projects"  # empty, so local JSONL pass is no-op
    HOME="$home_dir" PATH="$TMPDIR_ROOT:$PATH" \
        CLAUDE_SUMMARIES_DIR="$sum_dir" \
        bash "$SCRIPT" 2>/dev/null
}

# ============================================================
echo "=== Test 1: empty CLAUDE_SUMMARIES_DIR — fields default to 0/empty ==="
# ============================================================
ENV1="$TMPDIR_ROOT/test1"
SUM1="$TMPDIR_ROOT/sum1-empty"
mkdir -p "$SUM1"
OUT1=$(run_with_summaries "$SUM1" "$ENV1")
assert_eq "$(get_kv "$OUT1" WEEK_TOKENS)" "0" "WEEK_TOKENS = 0"
assert_eq "$(get_kv "$OUT1" HOST_BREAKDOWN)" "" "HOST_BREAKDOWN empty"
assert_eq "$(get_kv "$OUT1" PROJECTED_SEVEN_DAY)" "0" "PROJECTED_SEVEN_DAY = 0 without API data"

# ============================================================
echo "=== Test 2: three hosts, sums and breakdown ==="
# ============================================================
SUM2="$TMPDIR_ROOT/sum2"
write_summary "aaa" "$SUM2/aaa/personal/summary.json" \
    100 0.50 700 3.50 10 2 1000 5.00 \
    "100,200,300,100,0,0,0" "0.50,1.00,1.50,0.50,0,0,0" '{"opus":700}'
write_summary "bbb" "$SUM2/bbb/personal/summary.json" \
    50 0.25 350 1.75 5 1 500 2.50 \
    "50,100,150,50,0,0,0" "0.25,0.50,0.75,0.25,0,0,0" '{"opus":300,"sonnet":50}'
write_summary "ccc" "$SUM2/ccc/personal/summary.json" \
    0 0 0 0 0 0 0 0 \
    "0,0,0,0,0,0,0" "0,0,0,0,0,0,0" '{}'

OUT2=$(run_with_summaries "$SUM2" "$TMPDIR_ROOT/test2")

assert_eq "$(get_kv "$OUT2" WEEK_TOKENS)" "1050" "WEEK_TOKENS = 700+350+0"
assert_eq "$(get_kv "$OUT2" WEEK_MESSAGES)" "15" "WEEK_MESSAGES = 10+5"
assert_eq "$(get_kv "$OUT2" WEEK_SESSIONS)" "3" "WEEK_SESSIONS = 2+1"
assert_eq "$(get_kv "$OUT2" MONTH_TOKENS)" "1500" "MONTH_TOKENS = 1000+500"
assert_eq "$(get_kv "$OUT2" WEEK_COST)" "5.25" "WEEK_COST = 3.50+1.75"
assert_eq "$(get_kv "$OUT2" MONTH_COST)" "7.50" "MONTH_COST = 5.00+2.50"
assert_eq "$(get_kv "$OUT2" DAILY)" "150,300,450,150,0,0,0" "DAILY sums element-wise"
assert_eq "$(get_kv "$OUT2" DAILY_COSTS)" "0.75,1.50,2.25,0.75,0.00,0.00,0.00" "DAILY_COSTS sums element-wise"

# HOST_BREAKDOWN: only hosts with non-zero today_tokens, sorted desc
HB=$(get_kv "$OUT2" HOST_BREAKDOWN)
assert_eq "$HB" "aaa:100,bbb:50" "HOST_BREAKDOWN sorted desc, zero-today excluded"

# WEEK_MODELS: opus from aaa+bbb (700+300=1000), sonnet from bbb (50)
WM=$(get_kv "$OUT2" WEEK_MODELS)
if echo "$WM" | grep -q "opus:1000"; then pass "WEEK_MODELS contains opus:1000"; else fail "WEEK_MODELS opus missing or wrong: $WM"; fi
if echo "$WM" | grep -q "sonnet:50"; then pass "WEEK_MODELS contains sonnet:50"; else fail "WEEK_MODELS sonnet missing: $WM"; fi

# ============================================================
echo "=== Test 3: malformed summary.json is tolerated ==="
# ============================================================
SUM3="$TMPDIR_ROOT/sum3"
write_summary "good" "$SUM3/good/personal/summary.json" \
    42 0 100 0 1 1 100 0 "10,20,30,40,0,0,0" "0,0,0,0,0,0,0" '{}'
mkdir -p "$SUM3/bad/personal"
echo "not json at all {{" > "$SUM3/bad/personal/summary.json"

OUT3=$(run_with_summaries "$SUM3" "$TMPDIR_ROOT/test3")
assert_eq "$(get_kv "$OUT3" WEEK_TOKENS)" "100" "good host counted, bad ignored"

# ============================================================
echo "=== Test 4: projection math via mock API ==="
# ============================================================
# Mock curl returns a non-empty usage response with a known resets_at.
# We'll pick a reset 5 days in the future → window started 2 days ago → elapsed_frac = 2/7
RESET=$(date -d "5 days" -Iseconds)
cat > "$TMPDIR_ROOT/curl" << EOF
#!/usr/bin/env bash
# Mock OAuth /usage response: util=22%, reset=$RESET
echo '{"five_hour":{"utilization":4,"resets_at":"'"$RESET"'"},"seven_day":{"utilization":22,"resets_at":"'"$RESET"'"},"extra_usage":{"is_enabled":true}}'
EOF
chmod +x "$TMPDIR_ROOT/curl"

# We also need .credentials.json present so the API branch runs.
ENV4="$TMPDIR_ROOT/test4"
mkdir -p "$ENV4/.claude/projects"
cat > "$ENV4/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"fake","subscriptionType":"max","rateLimitTier":"max_20x"}}
EOF

OUT4=$(run_with_summaries "$TMPDIR_ROOT/sum1-empty" "$ENV4")

# elapsed = 2 days, frac = 2/7 = 0.286
# projected = 22 / 0.286 = 77.0
FRAC=$(get_kv "$OUT4" SEVEN_DAY_ELAPSED_FRAC)
PROJ=$(get_kv "$OUT4" PROJECTED_SEVEN_DAY)
DELTA=$(get_kv "$OUT4" SEVEN_DAY_DELTA)

# Allow small tolerance on the float math (date arithmetic is ~seconds-precise)
if awk -v f="$FRAC" 'BEGIN{exit (f > 0.28 && f < 0.30) ? 0 : 1}'; then
    pass "SEVEN_DAY_ELAPSED_FRAC ~ 0.286 (got $FRAC)"
else
    fail "SEVEN_DAY_ELAPSED_FRAC out of range: $FRAC"
fi
if awk -v p="$PROJ" 'BEGIN{exit (p > 75 && p < 79) ? 0 : 1}'; then
    pass "PROJECTED_SEVEN_DAY ~ 77 (got $PROJ)"
else
    fail "PROJECTED_SEVEN_DAY out of range: $PROJ"
fi
if awk -v d="$DELTA" 'BEGIN{exit (d > -25 && d < -21) ? 0 : 1}'; then
    pass "SEVEN_DAY_DELTA ~ -23 (got $DELTA)"
else
    fail "SEVEN_DAY_DELTA out of range: $DELTA"
fi

# ============================================================
echo "=== Test 5: projection skipped when elapsed_frac < 1% ==="
# ============================================================
# Reset is right now + 7d (start of window) → elapsed = 0 → projected = 0
RESET=$(date -d "7 days" -Iseconds)
cat > "$TMPDIR_ROOT/curl" << EOF
#!/usr/bin/env bash
echo '{"five_hour":{"utilization":4,"resets_at":"'"$RESET"'"},"seven_day":{"utilization":80,"resets_at":"'"$RESET"'"},"extra_usage":{"is_enabled":true}}'
EOF
chmod +x "$TMPDIR_ROOT/curl"

# Invalidate the 120s usage-cache from Test 4 so the new curl mock runs.
rm -f "$ENV4/.claude/usage-cache.json"
OUT5=$(run_with_summaries "$TMPDIR_ROOT/sum1-empty" "$ENV4")
assert_eq "$(get_kv "$OUT5" PROJECTED_SEVEN_DAY)" "0.0" "PROJECTED_SEVEN_DAY suppressed (elapsed<1%)"

# ============================================================
echo "=========================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ]
