#!/usr/bin/env bash
# Tests for QML widget JavaScript functions
# Extracts pure JS functions from ClaudeCodeUsageWidget.qml and tests them via Node.js
set -eu

# Check for Node.js
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: Node.js not available, skipping QML function tests"
    exit 0
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# Run a JS expression and capture stdout
run_js() {
    node -e "$1" 2>/dev/null
}

# Build JS test harness with functions extracted from the QML widget
JS_HARNESS='
// --- Functions extracted from ClaudeCodeUsageWidget.qml ---

function formatTokens(n) {
    if (n >= 1000000000) return (n / 1000000000).toFixed(1) + "B"
    if (n >= 1000000) return (n / 1000000).toFixed(1) + "M"
    if (n >= 1000) return (n / 1000).toFixed(1) + "K"
    return Math.round(n).toString()
}

function shortModelName(name) {
    if (!name || name.length === 0) return name
    return name.charAt(0).toUpperCase() + name.slice(1)
}

function progressColor(pct) {
    if (pct > 80) return "error"
    if (pct > 50) return "warning"
    return "primary"
}

function formatCompactCountdown(remainingMs, mode) {
    if (!remainingMs || remainingMs <= 0) return "0"
    if (mode === "hours-or-mins") {
        var h = Math.floor(remainingMs / 3600000)
        if (h > 0) return h + "h"
        var m = Math.floor(remainingMs / 60000)
        return m + "m"
    }
    var d = Math.floor(remainingMs / 86400000)
    if (d > 0) return d + "d"
    var hh = Math.floor(remainingMs / 3600000)
    return hh + "h"
}

function projectionColor(projected) {
    if (projected > 100) return "error"
    if (projected > 90) return "warning"
    return "primary"
}

function formatTier(tier) {
    if (tier.indexOf("max_20x") >= 0) return "Max 20x"
    if (tier.indexOf("max_5x") >= 0) return "Max 5x"
    if (tier.indexOf("pro") >= 0) return "Pro"
    if (tier.indexOf("free") >= 0) return "Free"
    return tier
}

function formatCost(usd, lang, usdEurRate) {
    var useEur = lang === "fr" && usdEurRate > 0
    var n = useEur ? usd * usdEurRate : usd
    var sym = useEur ? "" : "$"
    var suffix = useEur ? " €" : ""
    if (n >= 1000) return sym + (n / 1000).toFixed(1) + "K" + suffix
    if (n >= 100) return sym + Math.round(n) + suffix
    if (n >= 10) return sym + n.toFixed(1) + suffix
    return sym + n.toFixed(2) + suffix
}

function todayIndex() {
    var dow = new Date().getDay() // 0=Sunday, 6=Saturday
    return dow === 0 ? 6 : dow - 1
}

// parseLine: simulates the QML property-setting logic
function parseLine(line, state) {
    var idx = line.indexOf("=")
    if (idx < 0) return state
    var key = line.substring(0, idx)
    var val = line.substring(idx + 1)

    switch (key) {
    case "SUBSCRIPTION_TYPE": state.subscriptionType = val; break
    case "RATE_LIMIT_TIER": state.rateLimitTier = val; break
    case "FIVE_HOUR_UTIL": state.fiveHourUtil = parseFloat(val) || 0; break
    case "FIVE_HOUR_RESET": state.fiveHourReset = val; break
    case "SEVEN_DAY_UTIL": state.sevenDayUtil = parseFloat(val) || 0; break
    case "SEVEN_DAY_RESET": state.sevenDayReset = val; break
    case "EXTRA_USAGE_ENABLED": state.extraUsageEnabled = (val === "true"); break
    case "WEEK_MESSAGES": state.weekMessages = parseInt(val) || 0; break
    case "WEEK_SESSIONS": state.weekSessions = parseInt(val) || 0; break
    case "WEEK_TOKENS": state.weekTokens = parseFloat(val) || 0; break
    case "MONTH_TOKENS": state.monthTokens = parseFloat(val) || 0; break
    case "ALLTIME_SESSIONS": state.alltimeSessions = parseInt(val) || 0; break
    case "ALLTIME_MESSAGES": state.alltimeMessages = parseInt(val) || 0; break
    case "FIRST_SESSION": state.firstSession = val; break
    case "WEEK_MODELS":
        state.models = []
        if (val.length > 0) {
            var pairs = val.split(",")
            for (var i = 0; i < pairs.length; i++) {
                var kv = pairs[i].split(":")
                if (kv.length === 2)
                    state.models.push({ modelName: kv[0], modelTokens: parseInt(kv[1]) || 0 })
            }
        }
        break
    case "DAILY":
        var parts = val.split(",")
        var arr = []
        for (var j = 0; j < 7; j++)
            arr.push(j < parts.length ? (parseFloat(parts[j]) || 0) : 0)
        state.dailyTokens = arr
        break
    case "TODAY_COST": state.todayCost = parseFloat(val) || 0; break
    case "WEEK_COST": state.weekCost = parseFloat(val) || 0; break
    case "MONTH_COST": state.monthCost = parseFloat(val) || 0; break
    case "WORK_TODAY_COST": state.workTodayCost = parseFloat(val) || 0; break
    case "WORK_WEEK_COST": state.workWeekCost = parseFloat(val) || 0; break
    case "WORK_MONTH_COST": state.workMonthCost = parseFloat(val) || 0; break
    case "USD_EUR_RATE": state.usdEurRate = parseFloat(val) || 0; break
    case "DAILY_COSTS":
        var cparts = val.split(",")
        var carr = []
        for (var k = 0; k < 7; k++)
            carr.push(k < cparts.length ? (parseFloat(cparts[k]) || 0) : 0)
        state.dailyCosts = carr
        break
    case "HOST_BREAKDOWN":
        state.hostBreakdown = val
        state.hostBreakdownList = []
        if (val.length > 0) {
            var hp = val.split(",")
            for (var hi = 0; hi < hp.length; hi++) {
                var hkv = hp[hi].split(":")
                if (hkv.length === 2)
                    state.hostBreakdownList.push({host: hkv[0], tokens: parseInt(hkv[1]) || 0})
            }
        }
        break
    case "PROJECTED_SEVEN_DAY": state.projectedSevenDay = parseFloat(val) || 0; break
    case "SEVEN_DAY_DELTA": state.sevenDayDelta = parseFloat(val) || 0; break
    case "SEVEN_DAY_ELAPSED_FRAC": state.sevenDayElapsedFrac = parseFloat(val) || 0; break
    }
    return state
}
'

# ============================================================
echo "=== Test 1: formatTokens ==="
# ============================================================

test_format_tokens() {
    local input="$1" expected="$2" label="$3"
    local result
    result=$(run_js "${JS_HARNESS} console.log(formatTokens($input))")
    if [ "$result" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$result')"
    fi
}

test_format_tokens 0 "0" "formatTokens(0) = 0"
test_format_tokens 1 "1" "formatTokens(1) = 1"
test_format_tokens 999 "999" "formatTokens(999) = 999"
test_format_tokens 1000 "1.0K" "formatTokens(1000) = 1.0K"
test_format_tokens 1500 "1.5K" "formatTokens(1500) = 1.5K"
test_format_tokens 999999 "1000.0K" "formatTokens(999999) = 1000.0K"
test_format_tokens 1000000 "1.0M" "formatTokens(1M) = 1.0M"
test_format_tokens 1500000 "1.5M" "formatTokens(1.5M) = 1.5M"
test_format_tokens 1000000000 "1.0B" "formatTokens(1B) = 1.0B"
test_format_tokens 2500000000 "2.5B" "formatTokens(2.5B) = 2.5B"

# ============================================================
echo "=== Test 2: shortModelName ==="
# ============================================================

test_short_model() {
    local input="$1" expected="$2" label="$3"
    local result
    result=$(run_js "${JS_HARNESS} console.log(shortModelName('$input'))")
    if [ "$result" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$result')"
    fi
}

test_short_model "opus" "Opus" "shortModelName(opus) = Opus"
test_short_model "sonnet" "Sonnet" "shortModelName(sonnet) = Sonnet"
test_short_model "haiku" "Haiku" "shortModelName(haiku) = Haiku"
test_short_model "a" "A" "shortModelName(a) = A"

# Empty/null cases
RESULT_EMPTY=$(run_js "${JS_HARNESS} console.log(shortModelName(''))")
if [ "$RESULT_EMPTY" = "" ]; then pass "shortModelName('') = empty"; else fail "shortModelName('') expected empty, got '$RESULT_EMPTY'"; fi

RESULT_NULL=$(run_js "${JS_HARNESS} console.log(shortModelName(null))")
if [ "$RESULT_NULL" = "null" ]; then pass "shortModelName(null) = null"; else fail "shortModelName(null) expected null, got '$RESULT_NULL'"; fi

# ============================================================
echo "=== Test 3: progressColor ==="
# ============================================================

test_progress_color() {
    local input="$1" expected="$2" label="$3"
    local result
    result=$(run_js "${JS_HARNESS} console.log(progressColor($input))")
    if [ "$result" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$result')"
    fi
}

test_progress_color 0 "primary" "progressColor(0) = primary"
test_progress_color 50 "primary" "progressColor(50) = primary"
test_progress_color 51 "warning" "progressColor(51) = warning"
test_progress_color 80 "warning" "progressColor(80) = warning"
test_progress_color 81 "error" "progressColor(81) = error"
test_progress_color 100 "error" "progressColor(100) = error"

# ============================================================
echo "=== Test 4: formatTier ==="
# ============================================================

test_format_tier() {
    local input="$1" expected="$2" label="$3"
    local result
    result=$(run_js "${JS_HARNESS} console.log(formatTier('$input'))")
    if [ "$result" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$result')"
    fi
}

test_format_tier "t3_max_20x_something" "Max 20x" "formatTier max_20x"
test_format_tier "t2_max_5x_something" "Max 5x" "formatTier max_5x"
test_format_tier "t1_pro_something" "Pro" "formatTier pro"
test_format_tier "free_tier" "Free" "formatTier free"
test_format_tier "unknown" "unknown" "formatTier unknown passthrough"
test_format_tier "custom_plan" "custom_plan" "formatTier unrecognised passthrough"

# ============================================================
echo "=== Test 5: formatCost ==="
# ============================================================

test_format_cost() {
    local usd="$1" lang="$2" rate="$3" expected="$4" label="$5"
    local result
    result=$(run_js "${JS_HARNESS} console.log(formatCost($usd, '$lang', $rate))")
    if [ "$result" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$result')"
    fi
}

# USD mode (non-French locale)
test_format_cost 0 "en" 0 "\$0.00" "formatCost(0) USD = \$0.00"
test_format_cost 5.5 "en" 0 "\$5.50" "formatCost(5.5) USD = \$5.50"
test_format_cost 15.3 "en" 0 "\$15.3" "formatCost(15.3) USD = \$15.3"
test_format_cost 150 "en" 0 "\$150" "formatCost(150) USD = \$150"
test_format_cost 1500 "en" 0 "\$1.5K" "formatCost(1500) USD = \$1.5K"

# EUR mode (French locale with rate)
test_format_cost 10 "fr" 0.92 "9.20 €" "formatCost(10) EUR = 9.20 €"
test_format_cost 100 "fr" 0.92 "92.0 €" "formatCost(100) EUR = 92.0 € (92<100 → toFixed(1))"
test_format_cost 1500 "fr" 0.92 "1.4K €" "formatCost(1500) EUR = 1.4K €"

# French locale but rate=0 → falls back to USD
test_format_cost 5 "fr" 0 "\$5.00" "formatCost(5) FR no rate = USD fallback"

# ============================================================
echo "=== Test 6: todayIndex ==="
# ============================================================

# todayIndex should match: Monday=0, Tuesday=1, ..., Sunday=6
EXPECTED_INDEX=$(date +%u)  # 1=Monday, 7=Sunday
EXPECTED_INDEX=$((EXPECTED_INDEX - 1))  # 0=Monday, 6=Sunday
ACTUAL_INDEX=$(run_js "${JS_HARNESS} console.log(todayIndex())")

if [ "$ACTUAL_INDEX" = "$EXPECTED_INDEX" ]; then
    pass "todayIndex() = $EXPECTED_INDEX (matches today)"
else
    fail "todayIndex() expected $EXPECTED_INDEX, got $ACTUAL_INDEX"
fi

# Test specific days via mocking
test_today_index_mock() {
    local js_dow="$1" expected="$2" label="$3"
    local result
    result=$(run_js "
        var _getDay = Date.prototype.getDay;
        Date.prototype.getDay = function() { return $js_dow; };
        ${JS_HARNESS}
        console.log(todayIndex());
        Date.prototype.getDay = _getDay;
    ")
    if [ "$result" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$result')"
    fi
}

test_today_index_mock 0 6 "todayIndex Sunday (getDay=0) → 6"
test_today_index_mock 1 0 "todayIndex Monday (getDay=1) → 0"
test_today_index_mock 2 1 "todayIndex Tuesday (getDay=2) → 1"
test_today_index_mock 3 2 "todayIndex Wednesday (getDay=3) → 2"
test_today_index_mock 4 3 "todayIndex Thursday (getDay=4) → 3"
test_today_index_mock 5 4 "todayIndex Friday (getDay=5) → 4"
test_today_index_mock 6 5 "todayIndex Saturday (getDay=6) → 5"

# ============================================================
echo "=== Test 7: parseLine ==="
# ============================================================

test_parse_line() {
    local input="$1" field="$2" expected="$3" label="$4"
    local result
    result=$(run_js "${JS_HARNESS}
        var s = {};
        parseLine('$input', s);
        console.log(typeof s.$field === 'undefined' ? 'UNDEFINED' : JSON.stringify(s.$field));
    ")
    if [ "$result" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$result')"
    fi
}

# Basic key=value parsing
test_parse_line "SUBSCRIPTION_TYPE=pro" "subscriptionType" '"pro"' "parseLine SUBSCRIPTION_TYPE"
test_parse_line "FIVE_HOUR_UTIL=42.5" "fiveHourUtil" '42.5' "parseLine FIVE_HOUR_UTIL float"
test_parse_line "WEEK_MESSAGES=100" "weekMessages" '100' "parseLine WEEK_MESSAGES int"
test_parse_line "EXTRA_USAGE_ENABLED=true" "extraUsageEnabled" 'true' "parseLine EXTRA_USAGE bool true"
test_parse_line "EXTRA_USAGE_ENABLED=false" "extraUsageEnabled" 'false' "parseLine EXTRA_USAGE bool false"

# Empty values default to 0
test_parse_line "WEEK_TOKENS=" "weekTokens" '0' "parseLine empty value defaults to 0"
test_parse_line "FIVE_HOUR_UTIL=" "fiveHourUtil" '0' "parseLine empty float defaults to 0"

# Work-cost properties
test_parse_line "WORK_TODAY_COST=3.75" "workTodayCost" '3.75' "parseLine WORK_TODAY_COST float"
test_parse_line "WORK_WEEK_COST=24.25" "workWeekCost" '24.25' "parseLine WORK_WEEK_COST float"
test_parse_line "WORK_MONTH_COST=110.00" "workMonthCost" '110' "parseLine WORK_MONTH_COST float"
test_parse_line "WORK_TODAY_COST=0.00" "workTodayCost" '0' "parseLine WORK_TODAY_COST zero"
test_parse_line "WORK_WEEK_COST=" "workWeekCost" '0' "parseLine WORK_WEEK_COST empty defaults to 0"
test_parse_line "WORK_MONTH_COST=garbage" "workMonthCost" '0' "parseLine WORK_MONTH_COST non-numeric defaults to 0"

# No equals sign — ignored
RESULT_NOEQUALS=$(run_js "${JS_HARNESS}
    var s = { weekTokens: 99 };
    parseLine('GARBAGE', s);
    console.log(s.weekTokens);
")
if [ "$RESULT_NOEQUALS" = "99" ]; then
    pass "parseLine no equals sign is ignored"
else
    fail "parseLine no equals sign should be ignored (got weekTokens=$RESULT_NOEQUALS)"
fi

# DAILY with fewer than 7 values — padded with zeros
RESULT_SHORT=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('DAILY=100,200', s);
    console.log(JSON.stringify(s.dailyTokens));
")
if [ "$RESULT_SHORT" = "[100,200,0,0,0,0,0]" ]; then
    pass "parseLine DAILY short array padded to 7"
else
    fail "parseLine DAILY short array expected [100,200,0,0,0,0,0], got $RESULT_SHORT"
fi

# DAILY with 7 values
RESULT_FULL=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('DAILY=1,2,3,4,5,6,7', s);
    console.log(JSON.stringify(s.dailyTokens));
")
if [ "$RESULT_FULL" = "[1,2,3,4,5,6,7]" ]; then
    pass "parseLine DAILY full 7 values"
else
    fail "parseLine DAILY full expected [1,2,3,4,5,6,7], got $RESULT_FULL"
fi

# DAILY_COSTS with fewer than 7 values
RESULT_COSTS_SHORT=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('DAILY_COSTS=0.50,1.20', s);
    console.log(JSON.stringify(s.dailyCosts));
")
if [ "$RESULT_COSTS_SHORT" = "[0.5,1.2,0,0,0,0,0]" ]; then
    pass "parseLine DAILY_COSTS short array padded to 7"
else
    fail "parseLine DAILY_COSTS short expected [0.5,1.2,0,0,0,0,0], got $RESULT_COSTS_SHORT"
fi

# WEEK_MODELS with valid pairs
RESULT_MODELS=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('WEEK_MODELS=opus:5000,sonnet:3000', s);
    console.log(JSON.stringify(s.models));
")
if [ "$RESULT_MODELS" = '[{"modelName":"opus","modelTokens":5000},{"modelName":"sonnet","modelTokens":3000}]' ]; then
    pass "parseLine WEEK_MODELS valid pairs"
else
    fail "parseLine WEEK_MODELS expected [{opus,5000},{sonnet,3000}], got $RESULT_MODELS"
fi

# WEEK_MODELS empty value
RESULT_MODELS_EMPTY=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('WEEK_MODELS=', s);
    console.log(JSON.stringify(s.models));
")
if [ "$RESULT_MODELS_EMPTY" = "[]" ]; then
    pass "parseLine WEEK_MODELS empty = empty array"
else
    fail "parseLine WEEK_MODELS empty expected [], got $RESULT_MODELS_EMPTY"
fi

# WEEK_MODELS with malformed entry (no colon) — skipped
RESULT_MODELS_BAD=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('WEEK_MODELS=opus:5000,badentry,sonnet:3000', s);
    console.log(JSON.stringify(s.models));
")
if [ "$RESULT_MODELS_BAD" = '[{"modelName":"opus","modelTokens":5000},{"modelName":"sonnet","modelTokens":3000}]' ]; then
    pass "parseLine WEEK_MODELS malformed entry skipped"
else
    fail "parseLine WEEK_MODELS malformed expected opus+sonnet only, got $RESULT_MODELS_BAD"
fi

# ============================================================
echo "=== Test: formatCompactCountdown ==="
# ============================================================
test_compact() {
    local ms="$1" mode="$2" expected="$3" label="$4"
    local result
    result=$(run_js "${JS_HARNESS} console.log(formatCompactCountdown($ms, '$mode'))")
    if [ "$result" = "$expected" ]; then pass "$label"; else fail "$label (expected '$expected', got '$result')"; fi
}
# hours-or-mins mode (for 5h ring): biggest non-zero unit
test_compact 0           "hours-or-mins" "0"   "0ms → 0"
test_compact -1          "hours-or-mins" "0"   "negative → 0"
test_compact 30000       "hours-or-mins" "0m"  "30s → 0m"
test_compact 60000       "hours-or-mins" "1m"  "1min → 1m"
test_compact 840000      "hours-or-mins" "14m" "14min → 14m"
test_compact 3600000     "hours-or-mins" "1h"  "1h → 1h"
test_compact 7200000     "hours-or-mins" "2h"  "2h → 2h"
test_compact 9000000     "hours-or-mins" "2h"  "2h30m → 2h (truncates)"
test_compact 17999999    "hours-or-mins" "4h"  "4h59m → 4h"
# days-or-hours mode (for 7d ring)
test_compact 3600000     "days-or-hours" "1h"  "1h → 1h"
test_compact 86399999    "days-or-hours" "23h" "23h59m → 23h"
test_compact 86400000    "days-or-hours" "1d"  "exactly 1d"
test_compact 259200000   "days-or-hours" "3d"  "3d"
test_compact 604800000   "days-or-hours" "7d"  "7d"

# ============================================================
echo "=== Test: projectionColor ==="
# ============================================================
test_proj_color() {
    local projected="$1" expected="$2" label="$3"
    local result
    result=$(run_js "${JS_HARNESS} console.log(projectionColor($projected))")
    if [ "$result" = "$expected" ]; then pass "$label"; else fail "$label (expected '$expected', got '$result')"; fi
}
test_proj_color 0     "primary" "0% → primary"
test_proj_color 50    "primary" "50% → primary"
test_proj_color 90    "primary" "90% → primary"
test_proj_color 90.1  "warning" "90.1% → warning"
test_proj_color 100   "warning" "100% → warning (still amber, not over)"
test_proj_color 100.1 "error"   "100.1% → error"
test_proj_color 150   "error"   "150% → error"

# ============================================================
echo "=== Test: parseLine HOST_BREAKDOWN ==="
# ============================================================
RESULT_HB=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('HOST_BREAKDOWN=vermissian:3500000000,ultraviolet:29000000', s);
    console.log(JSON.stringify(s.hostBreakdownList));
")
if [ "$RESULT_HB" = '[{"host":"vermissian","tokens":3500000000},{"host":"ultraviolet","tokens":29000000}]' ]; then
    pass "parseLine HOST_BREAKDOWN two hosts parsed in order"
else
    fail "parseLine HOST_BREAKDOWN expected 2 entries, got $RESULT_HB"
fi
RESULT_HB_EMPTY=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('HOST_BREAKDOWN=', s);
    console.log(JSON.stringify(s.hostBreakdownList));
")
if [ "$RESULT_HB_EMPTY" = "[]" ]; then
    pass "parseLine HOST_BREAKDOWN empty = []"
else
    fail "parseLine HOST_BREAKDOWN empty expected [], got $RESULT_HB_EMPTY"
fi

# ============================================================
echo "=== Test: parseLine projection fields ==="
# ============================================================
RESULT_PROJ=$(run_js "${JS_HARNESS}
    var s = {};
    parseLine('PROJECTED_SEVEN_DAY=77.0', s);
    parseLine('SEVEN_DAY_DELTA=-23.0', s);
    parseLine('SEVEN_DAY_ELAPSED_FRAC=0.286', s);
    console.log(s.projectedSevenDay + ' ' + s.sevenDayDelta + ' ' + s.sevenDayElapsedFrac);
")
if [ "$RESULT_PROJ" = "77 -23 0.286" ]; then
    pass "parseLine projection fields"
else
    fail "parseLine projection expected '77 -23 0.286', got '$RESULT_PROJ'"
fi

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
