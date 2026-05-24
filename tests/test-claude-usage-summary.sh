#!/usr/bin/env bash
# Tests for claude-usage-summary script.
#
# Uses an isolated $HOME under mktemp, populates fixture JSONL, and
# asserts the emitted JSON has the right shape and aggregate values.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/claude-usage-summary"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# ISO date for today + this week's Monday (matches the script's
# calendar-week semantics).
TODAY=$(date +%Y-%m-%d)
DOW=$(date +%u)

make_jsonl_line() {
    local date="$1" model="$2" inp="$3" out="$4" cr="$5" cw="$6"
    printf '{"type":"assistant","timestamp":"%sT12:00:00Z","sessionId":"sess-1","message":{"model":"%s","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d}}}\n' \
        "$date" "$model" "$inp" "$out" "$cr" "$cw"
}

setup_env() {
    local name="$1"
    local dir="$TMPDIR_ROOT/$name"
    mkdir -p "$dir/.claude/projects/test-project"
    mkdir -p "$dir/.claude-work/projects/work-project"
    echo "$dir"
}

run_script() {
    local home_dir="$1" profile="$2" out="${3:-}"
    if [ -z "$out" ]; then
        HOME="$home_dir" bash "$SCRIPT" --profile "$profile"
    else
        HOME="$home_dir" bash "$SCRIPT" --profile "$profile" --out "$out"
    fi
}

# ============================================================
echo "=== Test 1: empty profile dir produces zero summary ==="
# ============================================================
ENV1=$(setup_env "test1")
OUT1="$TMPDIR_ROOT/test1.json"
run_script "$ENV1" personal "$OUT1"
if [ -f "$OUT1" ]; then pass "summary file written"; else fail "summary file missing"; fi
assert_eq "$(jq -r .today_tokens "$OUT1")" "0" "today_tokens = 0 for empty"
assert_eq "$(jq -r .week_tokens "$OUT1")" "0" "week_tokens = 0 for empty"
assert_eq "$(jq -r '.daily_tokens | length' "$OUT1")" "7" "daily_tokens has 7 entries"
assert_eq "$(jq -r '.daily_costs | length' "$OUT1")" "7" "daily_costs has 7 entries"
assert_eq "$(jq -r .profile "$OUT1")" "personal" "profile field is 'personal'"

# ============================================================
echo "=== Test 2: nonexistent projects dir produces zero summary ==="
# ============================================================
ENV2=$(setup_env "test2")
rm -rf "$ENV2/.claude/projects"
OUT2="$TMPDIR_ROOT/test2.json"
run_script "$ENV2" personal "$OUT2"
assert_eq "$(jq -r .today_tokens "$OUT2")" "0" "missing dir → today_tokens 0"
assert_eq "$(jq -r '.today_per_model | length' "$OUT2")" "0" "missing dir → empty per_model"

# ============================================================
echo "=== Test 3: aggregates today + other-day in same week ==="
# ============================================================
ENV3=$(setup_env "test3")
# pick another in-week day; if today is Monday use Tuesday, else use yesterday
if [ "$DOW" -eq 1 ]; then
    OTHER_DAY=$(date -d "1 day" +%Y-%m-%d)
else
    OTHER_DAY=$(date -d "1 day ago" +%Y-%m-%d)
fi
JSONL="$ENV3/.claude/projects/test-project/sess-1.jsonl"
{
    make_jsonl_line "$TODAY" "claude-opus-4-7-20260101" 1000 500 200 100
    make_jsonl_line "$OTHER_DAY" "claude-sonnet-4-6-20251015" 800 400 100 50
} > "$JSONL"

OUT3="$TMPDIR_ROOT/test3.json"
run_script "$ENV3" personal "$OUT3"
assert_eq "$(jq -r .today_tokens "$OUT3")" "1800" "today: 1000+500+200+100 = 1800"
assert_eq "$(jq -r .week_tokens "$OUT3")" "3150" "week: 1800 + (800+400+100+50) = 3150"
assert_eq "$(jq -r '.today_per_model.opus' "$OUT3")" "1800" "today_per_model.opus = 1800"
assert_eq "$(jq -r '.today_per_model.sonnet // 0' "$OUT3")" "0" "today_per_model.sonnet absent"
assert_eq "$(jq -r '.week_per_model.opus' "$OUT3")" "1800" "week_per_model.opus = 1800"
assert_eq "$(jq -r '.week_per_model.sonnet' "$OUT3")" "1350" "week_per_model.sonnet = 1350"

# ============================================================
echo "=== Test 4: pricing applied when pricing-cache present ==="
# ============================================================
ENV4=$(setup_env "test4")
cat > "$ENV4/.claude/pricing-cache.json" << 'EOF'
{
  "updated": "2026-05-23",
  "models": {
    "opus":   {"input": 1.5e-05, "output": 7.5e-05, "cache_read": 1.5e-06, "cache_write": 1.875e-05},
    "sonnet": {"input": 3e-06,   "output": 1.5e-05, "cache_read": 3e-07,   "cache_write": 3.75e-06}
  }
}
EOF
JSONL="$ENV4/.claude/projects/test-project/sess-1.jsonl"
make_jsonl_line "$TODAY" "claude-opus-4-7-20260101" 1000 500 200 100 > "$JSONL"
OUT4="$TMPDIR_ROOT/test4.json"
run_script "$ENV4" personal "$OUT4"
# cost = 1000*1.5e-5 + 500*7.5e-5 + 200*1.5e-6 + 100*1.875e-5
#      = 0.015 + 0.0375 + 0.0003 + 0.001875 = 0.054675
# Awk truncates to %.4f, so we expect 0.0547.
assert_eq "$(jq -r .today_cost_usd "$OUT4")" "0.0547" "today_cost_usd computed (%.4f) = 0.0547"

# ============================================================
echo "=== Test 5: --profile work reads from ~/.claude-work ==="
# ============================================================
ENV5=$(setup_env "test5")
JSONL_WORK="$ENV5/.claude-work/projects/work-project/sess-1.jsonl"
make_jsonl_line "$TODAY" "claude-opus-4-7-20260101" 100 50 25 10 > "$JSONL_WORK"
# Personal should NOT see this — empty profile dir on personal side
OUT5_WORK="$TMPDIR_ROOT/test5-work.json"
OUT5_PERS="$TMPDIR_ROOT/test5-pers.json"
run_script "$ENV5" work "$OUT5_WORK"
run_script "$ENV5" personal "$OUT5_PERS"
assert_eq "$(jq -r .profile "$OUT5_WORK")" "work" "work profile field"
assert_eq "$(jq -r .today_tokens "$OUT5_WORK")" "185" "work today_tokens = 185"
assert_eq "$(jq -r .today_tokens "$OUT5_PERS")" "0" "personal today_tokens = 0 (isolated)"

# ============================================================
echo "=== Test 6: atomic write (no half-written file on failure) ==="
# ============================================================
ENV6=$(setup_env "test6")
OUT6="$TMPDIR_ROOT/some/nested/test6.json"
run_script "$ENV6" personal "$OUT6"
if [ -f "$OUT6" ]; then pass "writes to nested path (mkdir -p)"; else fail "did not write nested path"; fi
if [ ! -f "$OUT6.tmp" ]; then pass ".tmp cleaned up after rename"; else fail ".tmp leaked"; fi

# ============================================================
echo "=== Test 7: rejects bad args ==="
# ============================================================
if run_script "$TMPDIR_ROOT/test7" personal 2>/dev/null; then
    fail "should error on missing --out"
else
    pass "errors when --out missing"
fi
if run_script "$TMPDIR_ROOT/test7" bogus "$TMPDIR_ROOT/x.json" 2>/dev/null; then
    fail "should error on bad profile"
else
    pass "errors on unknown profile"
fi

# ============================================================
echo "=== Test 8: symlinked PROJECTS dir is followed (find -H) ==="
# ============================================================
ENV8="$TMPDIR_ROOT/test8"
REAL="$TMPDIR_ROOT/test8-real-projects"
mkdir -p "$ENV8/.claude" "$REAL/test-project"
ln -s "$REAL" "$ENV8/.claude/projects"
JSONL="$REAL/test-project/sess-1.jsonl"
make_jsonl_line "$TODAY" "claude-opus-4-7-20260101" 1000 500 200 100 > "$JSONL"
OUT8="$TMPDIR_ROOT/test8.json"
run_script "$ENV8" personal "$OUT8"
assert_eq "$(jq -r .today_tokens "$OUT8")" "1800" "symlinked projects dir is traversed"

# ============================================================
echo "=========================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ]
