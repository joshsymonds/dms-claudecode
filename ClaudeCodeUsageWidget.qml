import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "translations.js" as Tr

PluginComponent {
    id: root

    // i18n
    property string lang: Qt.locale().name.split(/[_-]/)[0]
    function tr(key) { return Tr.tr(key, lang) }

    // Calendar week labels: Monday to Sunday (fixed order)
    property int refreshEpoch: 0
    property var dayLabels: lang === "fr"
        ? ["Lu", "Ma", "Me", "Je", "Ve", "Sa", "Di"]
        : ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    // Settings
    property int refreshInterval: (pluginData.refreshInterval || 2) * 60000
    // When true, the bar pill appends today's work-spend dollar amount
    // after the rings. Showing $0.00 is intentional — the toggle is the
    // user's signal that they want the tracker live regardless of value.
    property bool showWorkCostPill: pluginData.showWorkCostPill || false

    // API usage data
    property string subscriptionType: ""
    property string rateLimitTier: ""
    property real fiveHourUtil: 0
    property string fiveHourReset: ""
    property real sevenDayUtil: 0
    property string sevenDayReset: ""
    property bool extraUsageEnabled: false

    // Weekly state
    property int weekMessages: 0
    property int weekSessions: 0
    property real weekTokens: 0

    // Monthly state
    property real monthTokens: 0

    // All-time state
    property int alltimeSessions: 0
    property int alltimeMessages: 0
    property string firstSession: ""

    // Daily breakdown (rolling 7 days, computed from JSONL files)
    property var dailyTokens: [0, 0, 0, 0, 0, 0, 0]

    // Cross-host aggregation from /mnt/claude/*/personal/summary.json
    // (emitted by get-claude-usage). hostBreakdown is the raw
    // "host:tokens,host:tokens,..." string, hostBreakdownList is the
    // parsed [{host, tokens}, ...] array used by the popout row.
    property string hostBreakdown: ""
    property var hostBreakdownList: []

    // 7-day projection (linear extrapolation of utilization to reset).
    // projectedSevenDay is a percentage; sevenDayDelta is (projected - 100)
    // so positive = over the cap, negative = headroom.
    property real projectedSevenDay: 0
    property real sevenDayDelta: 0
    property real sevenDayElapsedFrac: 0

    // Estimated API cost (in USD)
    property real todayCost: 0
    property real weekCost: 0
    property real monthCost: 0

    // Work-profile costs aggregated across all hosts' work/summary.json
    // by get-claude-usage. Always present (zero when no work data).
    property real workTodayCost: 0
    property real workWeekCost: 0
    property real workMonthCost: 0

    // Backend-split work costs. Bedrock = real AWS $ (us. cross-region
    // rate). API = Anthropic list price — a real charge only on an API key;
    // under a flat subscription (workAnthropicBilling === "subscription")
    // the marginal cost is $0, so the charged total counts Bedrock only.
    property real workBedrockTodayCost: 0
    property real workBedrockWeekCost: 0
    property real workBedrockMonthCost: 0
    property real workApiTodayCost: 0
    property real workApiWeekCost: 0
    property real workApiMonthCost: 0
    property string workAnthropicBilling: "unknown"
    property string workSubscriptionType: ""
    property bool workApiIsFree: workAnthropicBilling === "subscription"
    // What you're actually billed: Bedrock always, plus the API side only
    // when it isn't covered by a flat subscription.
    property real workChargedTodayCost: workBedrockTodayCost + (workApiIsFree ? 0 : workApiTodayCost)
    property real workChargedWeekCost: workBedrockWeekCost + (workApiIsFree ? 0 : workApiWeekCost)
    property real workChargedMonthCost: workBedrockMonthCost + (workApiIsFree ? 0 : workApiMonthCost)

    property var dailyCosts: [0, 0, 0, 0, 0, 0, 0]
    property real usdEurRate: 0

    // Chart hover state
    property int hoveredDay: -1

    // Model list
    ListModel { id: modelListData }

    // Today's index in the calendar week (0=Monday, 6=Sunday)
    property int todayIndex: {
        void(countdownNow)
        var dow = new Date().getDay() // 0=Sunday, 6=Saturday
        return dow === 0 ? 6 : dow - 1
    }

    // Derived
    property real maxDaily: Math.max.apply(null, dailyTokens) || 1
    property bool isLoading: true

    // Live countdown
    property real countdownNow: Date.now()

    property string fiveHourCountdown: {
        if (!fiveHourReset) return ""
        var resetMs = new Date(fiveHourReset).getTime()
        var remaining = Math.max(0, resetMs - countdownNow)
        if (remaining <= 0) return tr("Resetting...")
        var hours = Math.floor(remaining / 3600000)
        var mins = Math.floor((remaining % 3600000) / 60000)
        return hours + "h " + (mins < 10 ? "0" : "") + mins + "m"
    }

    property string sevenDayCountdown: {
        if (!sevenDayReset) return ""
        var resetMs = new Date(sevenDayReset).getTime()
        var remaining = Math.max(0, resetMs - countdownNow)
        if (remaining <= 0) return tr("Resetting...")
        var days = Math.floor(remaining / 86400000)
        var hours = Math.floor((remaining % 86400000) / 3600000)
        var mins = Math.floor((remaining % 3600000) / 60000)
        if (days > 0) return days + "d " + hours + "h " + (mins < 10 ? "0" : "") + mins + "m"
        return hours + "h " + (mins < 10 ? "0" : "") + mins + "m"
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var now = Date.now()
            var elapsed = now - root.countdownNow
            root.countdownNow = now
            // Large gap (>2min) indicates wake from sleep — force immediate refresh
            if (elapsed > 120000 && !usageProcess.running) {
                usageProcess.running = true
            }
        }
    }

    // Script path via PluginService
    property string scriptPath: PluginService.pluginDirectory + "/claudeCodeUsage/get-claude-usage"

    popoutWidth: 380

    // Initial popoutHeight is just a first-frame hint. PluginPopout.qml
    // rebinds contentHeight = Qt.binding(() => item.implicitHeight + ...)
    // on Loader.onLoaded, so the real popup size tracks the PopoutComponent
    // Column's implicitHeight. That works as long as the inner cards
    // Column doesn't use anchors against its Column parent — see below.
    popoutHeight: 800

    // --- Helpers ---

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
        if (pct > 80) return Theme.error
        if (pct > 50) return Theme.warning
        return Theme.primary
    }

    function formatCost(usd) {
        var useEur = lang === "fr" && usdEurRate > 0
        var n = useEur ? usd * usdEurRate : usd
        var sym = useEur ? "" : "$"
        var suffix = useEur ? " €" : ""
        if (n >= 1000) return sym + (n / 1000).toFixed(1) + "K" + suffix
        if (n >= 100) return sym + Math.round(n) + suffix
        if (n >= 10) return sym + n.toFixed(1) + suffix
        return sym + n.toFixed(2) + suffix
    }

    // Glance-format for the bar pill — never more than 5 chars including
    // the symbol so the vertical pill stays the same width as the rings.
    // Examples: "$0", "$5", "$34", "$487", "$1.2k", "$12k", "$487k".
    function formatCostCompact(usd) {
        var useEur = lang === "fr" && usdEurRate > 0
        var n = useEur ? usd * usdEurRate : usd
        var sym = useEur ? "" : "$"
        var suffix = useEur ? "€" : ""
        if (n >= 1000000) return sym + Math.round(n / 1000000) + "M" + suffix
        if (n >= 10000)   return sym + Math.round(n / 1000) + "k" + suffix
        if (n >= 1000)    return sym + (n / 1000).toFixed(1) + "k" + suffix
        return sym + Math.round(n) + suffix
    }

    function formatTier(tier) {
        if (tier.indexOf("max_20x") >= 0) return "Max 20x"
        if (tier.indexOf("max_5x") >= 0) return "Max 5x"
        if (tier.indexOf("pro") >= 0) return "Pro"
        if (tier.indexOf("free") >= 0) return "Free"
        return tier
    }

    // Compact countdown for the ring centers. mode picks the natural
    // unit: "hours-or-mins" for the 5h ring, "days-or-hours" for the
    // 7d ring. Always <=4 chars so it stays legible at ~28px.
    function formatCompactCountdown(remainingMs, mode) {
        if (!remainingMs || remainingMs <= 0) return "0"
        if (mode === "hours-or-mins") {
            var h = Math.floor(remainingMs / 3600000)
            if (h > 0) return h + "h"
            var m = Math.floor(remainingMs / 60000)
            return m + "m"
        }
        // "days-or-hours"
        var d = Math.floor(remainingMs / 86400000)
        if (d > 0) return d + "d"
        var hh = Math.floor(remainingMs / 3600000)
        return hh + "h"
    }

    // Compact countdown text bound to the live countdownNow tick.
    property string fiveHourCompact: {
        if (!fiveHourReset) return ""
        var remaining = Math.max(0, new Date(fiveHourReset).getTime() - countdownNow)
        return formatCompactCountdown(remaining, "hours-or-mins")
    }
    property string sevenDayCompact: {
        if (!sevenDayReset) return ""
        var remaining = Math.max(0, new Date(sevenDayReset).getTime() - countdownNow)
        return formatCompactCountdown(remaining, "days-or-hours")
    }

    // Color for the 7-day projection headline. Tighter thresholds than
    // progressColor() because the projection is a forward-looking number
    // and 90-100% means "barely making it" — worth surfacing in amber.
    function projectionColor(projected) {
        if (projected > 100) return Theme.error
        if (projected > 90) return Theme.warning
        return Theme.primary
    }

    function parseLine(line) {
        var idx = line.indexOf("=")
        if (idx < 0) return
        var key = line.substring(0, idx)
        var val = line.substring(idx + 1)

        switch (key) {
        case "SUBSCRIPTION_TYPE": subscriptionType = val; break
        case "RATE_LIMIT_TIER": rateLimitTier = val; break
        case "FIVE_HOUR_UTIL": fiveHourUtil = parseFloat(val) || 0; break
        case "FIVE_HOUR_RESET": fiveHourReset = val; break
        case "SEVEN_DAY_UTIL": sevenDayUtil = parseFloat(val) || 0; break
        case "SEVEN_DAY_RESET": sevenDayReset = val; break
        case "EXTRA_USAGE_ENABLED": extraUsageEnabled = (val === "true"); break
        case "WEEK_MESSAGES": weekMessages = parseInt(val) || 0; break
        case "WEEK_SESSIONS": weekSessions = parseInt(val) || 0; break
        case "WEEK_TOKENS": weekTokens = parseFloat(val) || 0; break
        case "MONTH_TOKENS": monthTokens = parseFloat(val) || 0; break
        case "ALLTIME_SESSIONS": alltimeSessions = parseInt(val) || 0; break
        case "ALLTIME_MESSAGES": alltimeMessages = parseInt(val) || 0; break
        case "FIRST_SESSION": firstSession = val; break
        case "WEEK_MODELS":
            modelListData.clear()
            if (val.length > 0) {
                var pairs = val.split(",")
                for (var i = 0; i < pairs.length; i++) {
                    var kv = pairs[i].split(":")
                    if (kv.length === 2)
                        modelListData.append({ modelName: kv[0], modelTokens: parseInt(kv[1]) || 0 })
                }
            }
            break
        case "DAILY":
            var parts = val.split(",")
            var arr = []
            for (var j = 0; j < 7; j++)
                arr.push(j < parts.length ? (parseFloat(parts[j]) || 0) : 0)
            dailyTokens = arr
            break
        case "TODAY_COST": todayCost = parseFloat(val) || 0; break
        case "WEEK_COST": weekCost = parseFloat(val) || 0; break
        case "MONTH_COST": monthCost = parseFloat(val) || 0; break
        case "WORK_TODAY_COST": workTodayCost = parseFloat(val) || 0; break
        case "WORK_WEEK_COST": workWeekCost = parseFloat(val) || 0; break
        case "WORK_MONTH_COST": workMonthCost = parseFloat(val) || 0; break
        case "WORK_BEDROCK_TODAY_COST": workBedrockTodayCost = parseFloat(val) || 0; break
        case "WORK_BEDROCK_WEEK_COST": workBedrockWeekCost = parseFloat(val) || 0; break
        case "WORK_BEDROCK_MONTH_COST": workBedrockMonthCost = parseFloat(val) || 0; break
        case "WORK_API_TODAY_COST": workApiTodayCost = parseFloat(val) || 0; break
        case "WORK_API_WEEK_COST": workApiWeekCost = parseFloat(val) || 0; break
        case "WORK_API_MONTH_COST": workApiMonthCost = parseFloat(val) || 0; break
        case "WORK_ANTHROPIC_BILLING": workAnthropicBilling = val; break
        case "WORK_SUBSCRIPTION_TYPE": workSubscriptionType = val; break
        case "USD_EUR_RATE": usdEurRate = parseFloat(val) || 0; break
        case "DAILY_COSTS":
            var cparts = val.split(",")
            var carr = []
            for (var k = 0; k < 7; k++)
                carr.push(k < cparts.length ? (parseFloat(cparts[k]) || 0) : 0)
            dailyCosts = carr
            break
        case "HOST_BREAKDOWN":
            hostBreakdown = val
            var hl = []
            if (val.length > 0) {
                var hp = val.split(",")
                for (var hi = 0; hi < hp.length; hi++) {
                    var hkv = hp[hi].split(":")
                    if (hkv.length === 2)
                        hl.push({host: hkv[0], tokens: parseInt(hkv[1]) || 0})
                }
            }
            hostBreakdownList = hl
            break
        case "PROJECTED_SEVEN_DAY": projectedSevenDay = parseFloat(val) || 0; break
        case "SEVEN_DAY_DELTA": sevenDayDelta = parseFloat(val) || 0; break
        case "SEVEN_DAY_ELAPSED_FRAC": sevenDayElapsedFrac = parseFloat(val) || 0; break
        }
    }

    // --- Data fetching ---

    Process {
        id: usageProcess
        command: ["bash", root.scriptPath]
        running: false

        stdout: SplitParser {
            onRead: data => root.parseLine(data.trim())
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root.isLoading = false
                root.refreshEpoch++
            }
        }
    }

    Timer {
        interval: root.refreshInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!usageProcess.running)
                usageProcess.running = true
        }
    }

    // --- Taskbar pills (two labeled rings, "5h" + "1w") ---
    //
    // Each ring shows one rate window: outer arc fills clockwise as
    // utilization climbs, color ramps green→amber→red via
    // progressColor(). The window name sits centered inside the ring —
    // the visual fill is the metric, the label is the legend, the
    // exact percentage lives in the popout. Concentric rings were
    // abandoned because at 22px the inner ring was visually
    // indistinguishable from the outer.

    component LabeledRing: Item {
        id: lr
        property real percent: 0
        property string label: ""
        property int ringSize: 28
        property int ringStroke: 3

        implicitWidth: ringSize
        implicitHeight: ringSize

        Canvas {
            anchors.fill: parent
            renderStrategy: Canvas.Cooperative

            property real ringPercent: lr.percent
            onRingPercentChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var cx = width / 2, cy = height / 2
                var lw = lr.ringStroke
                var r = Math.min(width, height) / 2 - lw / 2 - 0.5

                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                ctx.lineWidth = lw
                ctx.strokeStyle = Theme.surfaceVariant
                ctx.stroke()

                var pct = ringPercent / 100
                if (pct > 0) {
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.min(pct, 1))
                    ctx.lineWidth = lw
                    ctx.strokeStyle = root.progressColor(ringPercent)
                    ctx.lineCap = "round"
                    ctx.stroke()
                }
            }
        }

        StyledText {
            anchors.centerIn: parent
            text: lr.label
            font.pixelSize: Math.max(9, Math.round(lr.ringSize * 0.38))
            font.weight: Font.Medium
            color: Theme.surfaceText
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            LabeledRing {
                anchors.verticalCenter: parent.verticalCenter
                percent: root.fiveHourUtil
                // Top/leading ring is always the 5h window; center shows
                // countdown until the window resets in the shortest
                // useful unit ("2h" or "14m").
                label: root.fiveHourCompact || "5h"
            }

            LabeledRing {
                anchors.verticalCenter: parent.verticalCenter
                percent: root.sevenDayUtil
                // Trailing ring is always the 7d window ("3d" or "12h").
                label: root.sevenDayCompact || "7d"
            }

            // Today's work-spend trailer. Gated by the showWorkCostPill
            // setting (default off). When enabled, intentionally shows
            // $0 on quiet days — the toggle is the user's signal that
            // they want the tracker visible regardless of value. The
            // leftPadding/rightPadding gives the dollar text breathing
            // room from the adjacent ring instead of butting against it.
            StyledText {
                visible: root.showWorkCostPill
                text: root.formatCostCompact(root.workChargedTodayCost)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Theme.spacingS
                rightPadding: Theme.spacingS
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            LabeledRing {
                anchors.horizontalCenter: parent.horizontalCenter
                percent: root.fiveHourUtil
                label: root.fiveHourCompact || "5h"
            }

            LabeledRing {
                anchors.horizontalCenter: parent.horizontalCenter
                percent: root.sevenDayUtil
                label: root.sevenDayCompact || "7d"
            }

            // topPadding/bottomPadding give the dollar text vertical
            // breathing room on the vertical bar where the trailer sits
            // directly beneath the 7d ring. spacingS adds ~4px of
            // dead space top and bottom on top of the Column spacing.
            StyledText {
                visible: root.showWorkCostPill
                text: root.formatCostCompact(root.workChargedTodayCost)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
                topPadding: Theme.spacingS
                bottomPadding: Theme.spacingS
            }
        }
    }

    // --- Popout ---

    // Wrap PopoutComponent (a Column positioner whose implicitHeight is
    // read-only and reassignment errors with `"implicitHeight" is a read-only
    // property`) in an Item we control. The framework's
    // PluginPopout.onLoaded binds `contentHeight = item.implicitHeight + ...`
    // against THIS Item, so we drive `implicitHeight` from cardsCol's
    // deterministic sum directly — bypasses the auto-cascade timing
    // window that intermittently captured a stale value on first paint.
    // closePopout and parentPopout must be forwarded so the framework's
    // wiring still reaches the inner PopoutComponent's close button.
    popoutContent: Component {
        Item {
            id: popoutWrapper
            property var closePopout: null
            property var parentPopout: null
            implicitWidth: popoutRoot.implicitWidth
            implicitHeight: cardsCol.implicitHeight + popoutRoot.headerHeight + popoutRoot.detailsHeight + Theme.spacingL * 2

            PopoutComponent {
                id: popoutRoot
                anchors.fill: parent
                headerText: root.tr("Claude Code Usage")
                detailsText: root.rateLimitTier ? root.tr("Subscription") + " : " + root.formatTier(root.rateLimitTier) : ""
                showCloseButton: true
                closePopout: popoutWrapper.closePopout
                parentPopout: popoutWrapper.parentPopout

                // Inner cards Column. Uses x/width positioning instead of
                // anchors.horizontalCenter because the parent PopoutComponent
                // is itself a Column positioner: anchoring inside a positioner
                // makes Qt drop this child from the parent's implicitHeight
                // computation, which would break the auto-sizing path.
                Column {
                    id: cardsCol
                    width: parent.width - Theme.spacingM * 2
                    x: Theme.spacingM
                    spacing: Theme.spacingL

                // --- 5h Rate Window card ---
                StyledRect {
                    width: parent.width
                    height: fiveHourContent.implicitHeight + Theme.spacingS * 2
                    color: Theme.surfaceContainerHigh

                    Row {
                        id: fiveHourContent
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingM

                        Canvas {
                            id: fiveHourRing
                            width: 100
                            height: 100
                            anchors.verticalCenter: parent.verticalCenter
                            renderStrategy: Canvas.Cooperative

                            property real percent: root.fiveHourUtil
                            onPercentChanged: requestPaint()

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.reset()
                                var cx = width / 2, cy = height / 2, r = 38, lw = 8

                                ctx.beginPath()
                                ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                                ctx.lineWidth = lw
                                ctx.strokeStyle = Theme.surfaceVariant
                                ctx.stroke()

                                var pct = percent / 100
                                if (pct > 0) {
                                    ctx.beginPath()
                                    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.min(pct, 1))
                                    ctx.lineWidth = lw
                                    ctx.strokeStyle = root.progressColor(percent)
                                    ctx.lineCap = "round"
                                    ctx.stroke()
                                }
                            }

                            StyledText {
                                anchors.centerIn: parent
                                text: Math.round(root.fiveHourUtil) + "%"
                                font.pixelSize: Theme.fontSizeXLarge
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            StyledText {
                                text: root.tr("5h Rate Window")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }
                            StyledText {
                                text: Math.round(root.fiveHourUtil) + "% " + root.tr("used")
                                font.pixelSize: Theme.fontSizeMedium
                                color: root.progressColor(root.fiveHourUtil)
                            }
                            StyledText {
                                text: root.fiveHourCountdown ? root.tr("Resets in") + " " + root.fiveHourCountdown : ""
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceVariantText
                                visible: root.fiveHourCountdown !== ""
                            }
                        }
                    }
                }

                // --- 7-Day Usage card ---
                StyledRect {
                    width: parent.width
                    height: sevenDayContent.implicitHeight + Theme.spacingM * 2
                    color: Theme.surfaceContainerHigh

                    Row {
                        id: sevenDayContent
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingM

                        Canvas {
                            id: weeklySmallRing
                            width: 72
                            height: 72
                            anchors.verticalCenter: parent.verticalCenter
                            renderStrategy: Canvas.Cooperative

                            property real percent: root.sevenDayUtil
                            onPercentChanged: requestPaint()

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.reset()
                                var cx = width / 2, cy = height / 2, r = 28, lw = 6

                                ctx.beginPath()
                                ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                                ctx.lineWidth = lw
                                ctx.strokeStyle = Theme.surfaceVariant
                                ctx.stroke()

                                var pct = percent / 100
                                if (pct > 0) {
                                    ctx.beginPath()
                                    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.min(pct, 1))
                                    ctx.lineWidth = lw
                                    ctx.strokeStyle = root.progressColor(percent)
                                    ctx.lineCap = "round"
                                    ctx.stroke()
                                }
                            }

                            StyledText {
                                anchors.centerIn: parent
                                text: Math.round(root.sevenDayUtil) + "%"
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXS

                            StyledText {
                                text: root.tr("7-Day Usage") + " · " + Math.round(root.sevenDayUtil) + "%"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }
                            StyledText {
                                text: {
                                    var parts = []
                                    if (root.weekSessions > 0) parts.push(root.weekSessions + " " + root.tr("sessions"))
                                    if (root.weekMessages > 0) parts.push(root.weekMessages + " " + root.tr("msgs"))
                                    return parts.join(" · ")
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                            StyledText {
                                text: root.sevenDayCountdown ? root.tr("Resets in") + " " + root.sevenDayCountdown : ""
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                visible: root.sevenDayCountdown !== ""
                            }
                        }
                    }
                }

                // --- 7-Day Projection card ---
                // Linear extrapolation of seven_day.utilization to the
                // reset, computed in get-claude-usage. Hidden until at
                // least 1% of the window has elapsed (~100 min) since
                // earlier than that the extrapolation is wildly noisy.
                StyledRect {
                    width: parent.width
                    height: projectionCol.implicitHeight + Theme.spacingM * 2
                    color: Theme.surfaceContainerHigh
                    visible: root.sevenDayElapsedFrac >= 0.01

                    Column {
                        id: projectionCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        StyledText {
                            text: root.tr("On track for ~") + Math.round(root.projectedSevenDay) + "%"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.DemiBold
                            color: root.projectionColor(root.projectedSevenDay)
                        }
                        StyledText {
                            // delta > 0 = over the cap (slow down by N%)
                            // delta < 0 = headroom (X% under)
                            text: root.sevenDayDelta > 0
                                ? root.tr("Slow down") + " ~" + Math.round(root.sevenDayDelta) + "%"
                                : Math.round(-root.sevenDayDelta) + "% " + root.tr("headroom")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                // --- Token Consumption card ---
                StyledRect {
                    width: parent.width
                    height: consumptionCol.implicitHeight + Theme.spacingM * 2
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: consumptionCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingM

                        StyledText {
                            text: root.tr("Token Consumption")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        Row {
                            width: parent.width

                            Column {
                                width: parent.width / 3
                                spacing: 4

                                StyledText {
                                    text: root.tr("Today")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatTokens(root.dailyTokens[root.todayIndex])
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.DemiBold
                                    color: Theme.primary
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatCost(root.todayCost)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    visible: root.todayCost > 0
                                }
                            }

                            Column {
                                width: parent.width / 3
                                spacing: 4

                                StyledText {
                                    text: root.tr("Week")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatTokens(root.weekTokens)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatCost(root.weekCost)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    visible: root.weekCost > 0
                                }
                            }

                            Column {
                                width: parent.width / 3
                                spacing: 4

                                StyledText {
                                    text: root.tr("Month")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatTokens(root.monthTokens)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatCost(root.monthCost)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    visible: root.monthCost > 0
                                }
                            }
                        }

                        // Per-host today breakdown. Only show when ≥2 hosts
                        // have non-zero today data — for the common single-
                        // host case the aggregate row above already conveys it.
                        Flow {
                            width: parent.width
                            spacing: Theme.spacingM
                            visible: root.hostBreakdownList.length >= 2

                            Repeater {
                                model: root.hostBreakdownList
                                StyledText {
                                    text: modelData.host + " " + root.formatTokens(modelData.tokens)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }
                }

                // --- Work Spend card ---
                // Aggregates today/week/month dollar cost from every host's
                // work/summary.json (~/Work/attain cwd-classified projects).
                // Month is highlighted because that's the billing-cycle
                // signal; Today/Week are reference.
                StyledRect {
                    width: parent.width
                    height: workSpendCol.implicitHeight + Theme.spacingM * 2
                    color: Theme.surfaceContainerHigh
                    visible: root.workTodayCost > 0 || root.workWeekCost > 0 || root.workMonthCost > 0

                    Column {
                        id: workSpendCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingM

                        StyledText {
                            text: root.tr("Work Spend")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        Row {
                            width: parent.width

                            Column {
                                width: parent.width / 3
                                spacing: 4

                                StyledText {
                                    text: root.tr("Today")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatCost(root.workChargedTodayCost)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }

                            Column {
                                width: parent.width / 3
                                spacing: 4

                                StyledText {
                                    text: root.tr("Week")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatCost(root.workChargedWeekCost)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }

                            Column {
                                width: parent.width / 3
                                spacing: 4

                                StyledText {
                                    text: root.tr("Month")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StyledText {
                                    text: root.formatCost(root.workChargedMonthCost)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.DemiBold
                                    color: Theme.primary
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }
                        }

                        // Backend breakdown: what those charged totals are
                        // made of. Bedrock is real AWS $; the Anthropic side
                        // is "included" under a flat subscription (so it's
                        // excluded from the charged totals above) or a real
                        // API charge otherwise. Today's figures.
                        StyledText {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            text: {
                                var parts = []
                                if (root.workBedrockTodayCost > 0)
                                    parts.push(root.tr("Bedrock (AWS)") + " " + root.formatCost(root.workBedrockTodayCost))
                                if (root.workApiTodayCost > 0) {
                                    if (root.workApiIsFree)
                                        parts.push(root.tr("Anthropic") + " "
                                            + (root.workSubscriptionType ? root.workSubscriptionType.toUpperCase() : root.tr("subscription"))
                                            + " — " + root.tr("included"))
                                    else
                                        parts.push(root.tr("Anthropic API") + " " + root.formatCost(root.workApiTodayCost))
                                }
                                return parts.join("  ·  ")
                            }
                            visible: text.length > 0
                        }
                    }
                }

                // --- Daily activity card ---
                StyledRect {
                    width: parent.width
                    height: dailyCol.implicitHeight + Theme.spacingM * 2
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: dailyCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        StyledText {
                            text: root.tr("Daily Activity")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        Item {
                            width: parent.width
                            height: 70

                            Row {
                                id: chartRow
                                anchors.fill: parent
                                spacing: 4

                                Repeater {
                                    model: 7
                                    delegate: Column {
                                        width: (chartRow.width - 6 * 4) / 7
                                        height: chartRow.height
                                        spacing: 2

                                        Item {
                                            width: parent.width
                                            height: parent.height - dayLabel.height - 2

                                            Rectangle {
                                                anchors.bottom: parent.bottom
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                width: Math.max(parent.width - 4, 4)
                                                height: root.maxDaily > 0
                                                    ? Math.max(root.dailyTokens[index] / root.maxDaily * parent.height, root.dailyTokens[index] > 0 ? 3 : 0)
                                                    : 0
                                                radius: 2
                                                color: index === root.hoveredDay
                                                    ? Theme.primary
                                                    : index === root.todayIndex ? Theme.primary : Theme.surfaceVariant
                                                opacity: root.hoveredDay >= 0 && index !== root.hoveredDay ? 0.4 : 1.0

                                                Behavior on opacity {
                                                    NumberAnimation { duration: 120 }
                                                }
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                enabled: root.dailyTokens[index] > 0
                                                onEntered: root.hoveredDay = index
                                                onExited: root.hoveredDay = -1
                                            }
                                        }

                                        StyledText {
                                            id: dayLabel
                                            text: root.dayLabels[index]
                                            font.pixelSize: 11
                                            color: index === root.hoveredDay
                                                ? Theme.primary
                                                : index === root.todayIndex ? Theme.primary : Theme.surfaceVariantText
                                            anchors.horizontalCenter: parent.horizontalCenter
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Tooltip on hover — child of StyledRect to avoid clip issues
                    Rectangle {
                        id: chartTooltip
                        visible: root.hoveredDay >= 0 && root.dailyTokens[root.hoveredDay] > 0
                        z: 10

                        x: {
                            var colW = (chartRow.width - 6 * 4) / 7
                            var cx = root.hoveredDay * (colW + 4) + colW / 2 - width / 2
                            var chartX = chartRow.mapToItem(chartTooltip.parent, 0, 0).x
                            var raw = chartX + cx
                            return Math.max(Theme.spacingM, Math.min(raw, parent.width - width - Theme.spacingM))
                        }
                        y: {
                            var chartY = chartRow.mapToItem(chartTooltip.parent, 0, 0).y
                            return chartY - height - 2
                        }

                        width: tooltipCol.width + Theme.spacingS * 2
                        height: tooltipCol.height + Theme.spacingXS * 2
                        radius: 4
                        color: Theme.surfaceContainer

                        Column {
                            id: tooltipCol
                            anchors.centerIn: parent
                            spacing: 1

                            StyledText {
                                text: root.hoveredDay >= 0 ? root.formatTokens(root.dailyTokens[root.hoveredDay]) : ""
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            StyledText {
                                visible: root.hoveredDay >= 0 && root.dailyCosts[root.hoveredDay] > 0
                                text: root.hoveredDay >= 0 ? root.formatCost(root.dailyCosts[root.hoveredDay]) : ""
                                font.pixelSize: 11
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                }

                // --- Model breakdown card ---
                StyledRect {
                    width: parent.width
                    height: modelCardCol.implicitHeight + Theme.spacingM * 2
                    color: Theme.surfaceContainerHigh
                    visible: modelListData.count > 0

                    Column {
                        id: modelCardCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        StyledText {
                            text: root.tr("Models This Week")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        Column {
                            id: modelCol
                            width: parent.width
                            spacing: Theme.spacingS

                            Repeater {
                                model: modelListData
                                delegate: Column {
                                    width: modelCol.width
                                    spacing: 3

                                    Row {
                                        width: parent.width
                                        spacing: Theme.spacingXS

                                        StyledText {
                                            text: root.shortModelName(modelName)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                        }
                                        StyledText {
                                            text: root.formatTokens(modelTokens)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 4
                                        radius: 2
                                        color: Theme.surfaceVariant

                                        Rectangle {
                                            width: root.weekTokens > 0
                                                ? parent.width * Math.min(modelTokens / root.weekTokens, 1)
                                                : 0
                                            height: parent.height
                                            radius: 2
                                            color: Theme.primary
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // --- All-time footer card ---
                StyledRect {
                    width: parent.width
                    height: allTimeRow.implicitHeight + Theme.spacingM * 2
                    color: Theme.surfaceContainerHigh
                    visible: root.alltimeSessions > 0 || root.alltimeMessages > 0

                    Row {
                        id: allTimeRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "calendar_today"
                            size: 14
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: {
                                var parts = []
                                if (root.firstSession && root.firstSession !== "unknown")
                                    parts.push(root.tr("Since") + " " + root.firstSession)
                                parts.push(root.alltimeSessions + " " + root.tr("sessions"))
                                parts.push(root.alltimeMessages.toLocaleString() + " " + root.tr("msgs"))
                                return parts.join("  ·  ")
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                    // Bottom padding to match sides (compensates Column spacing)
                    Item { width: 1; height: 1 }
                }
            }
        }
    }
}
