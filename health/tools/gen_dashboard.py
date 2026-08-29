"""Generate the screen-time dashboard JSON.

Kept as a generator because the panel list is repetitive and hand-editing 900
lines of Grafana JSON is how dashboards rot. The committed artifact is the
JSON it emits; regenerate with `python3 tools/gen_dashboard.py`.
"""
import json

DS = {"type": "grafana-postgresql-datasource", "uid": "health-postgres"}

# Validated dark-mode categorical palette (dataviz slots 1-6) + neutral Other.
APP_COLORS = {
    "YouTube":   "#3987e5",
    "Instagram": "#d95926",
    "Chrome":    "#199e70",
    "Reddit":    "#c98500",
    "Messages":  "#d55181",
    "Slack":     "#008300",
    "Other":     "#7c7b74",
}
ACCENT = "#3987e5"

# A hidden legend still carries displayMode/placement so the panel round-trips
# cleanly through Grafana's UI editor without gaining spurious diffs.
HIDDEN_LEGEND = {"showLegend": False, "displayMode": "list",
                 "placement": "bottom", "calcs": []}


def sql(q, fmt="time_series"):
    return [{"datasource": DS, "editorMode": "code", "format": fmt,
             "rawQuery": True, "rawSql": q.strip(), "refId": "A"}]


def gp(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}


def stat(title, q, unit, gridPos, desc, decimals=1, color=ACCENT):
    return {
        "type": "stat", "title": title, "description": desc,
        "datasource": DS, "gridPos": gridPos, "targets": sql(q, "table"),
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": decimals,
            "color": {"mode": "fixed", "fixedColor": color},
            "mappings": [], "thresholds": {"mode": "absolute",
                                           "steps": [{"color": color, "value": None}]},
        }, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "orientation": "auto", "textMode": "auto", "colorMode": "value",
                    "graphMode": "none", "justifyMode": "auto"},
    }


panels = []

# ---------------------------------------------------------------- headline row
panels += [
    stat("Today", """
SELECT screen_time_hours AS "Today"
FROM health.v_screentime_daily
WHERE day = health.local_day(now())
""", "h", gp(0, 0, 6, 4),
         "Screen time so far today, local midnight to now. Independent of the "
         "dashboard time range."),
    stat("7-day average", """
SELECT AVG(screen_time_hours) AS "7-day average"
FROM health.v_screentime_daily
WHERE day >= health.local_day(now()) - interval '7 days'
  AND day <  health.local_day(now())
""", "h", gp(6, 0, 6, 4),
         "Mean daily screen time over the 7 complete days before today."),
    stat("30-day average", """
SELECT AVG(screen_time_hours) AS "30-day average"
FROM health.v_screentime_daily
WHERE day >= health.local_day(now()) - interval '30 days'
  AND day <  health.local_day(now())
""", "h", gp(12, 0, 6, 4),
         "Mean daily screen time over the 30 complete days before today. The "
         "baseline the 7-day figure should be read against."),
    stat("Unlocks per day", """
SELECT AVG(unlocks) AS "Unlocks per day"
FROM health.v_screentime_daily
WHERE day >= health.local_day(now()) - interval '7 days'
  AND day <  health.local_day(now())
""", "short", gp(18, 0, 6, 4),
         "Mean pickups per day over the last 7 complete days. Tracks compulsive "
         "checking separately from time spent.", decimals=0),
]

# --------------------------------------------------------------- daily trend
panels.append({
    "type": "timeseries", "title": "Daily screen time",
    "description": "Total foreground time per local day, with a trailing 7-day "
                   "mean. The mean is computed over the visible range, so the "
                   "first six points of any range are partial windows.",
    "datasource": DS, "gridPos": gp(0, 4, 16, 9),
    "targets": sql("""
SELECT day AS time,
       screen_time_hours AS "Daily",
       AVG(screen_time_hours) OVER (
         ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
       ) AS "7-day mean"
FROM health.v_screentime_daily
WHERE $__timeFilter(day)
ORDER BY day
"""),
    "fieldConfig": {
        "defaults": {
            "unit": "h", "decimals": 1,
            "color": {"mode": "fixed", "fixedColor": ACCENT},
            "custom": {"drawStyle": "bars", "fillOpacity": 70, "lineWidth": 0,
                       "barAlignment": 0, "barWidthFactor": 0.7,
                       "axisLabel": "hours", "axisPlacement": "left",
                       "gradientMode": "none", "showPoints": "never",
                       "scaleDistribution": {"type": "linear"}},
        },
        "overrides": [{
            "matcher": {"id": "byName", "options": "7-day mean"},
            "properties": [
                {"id": "color", "value": {"mode": "fixed", "fixedColor": "#d95926"}},
                {"id": "custom.drawStyle", "value": "line"},
                {"id": "custom.lineWidth", "value": 2},
                {"id": "custom.fillOpacity", "value": 0},
                {"id": "custom.lineInterpolation", "value": "smooth"},
            ],
        }],
    },
    "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                "tooltip": {"mode": "multi", "sort": "none"}},
})

# ------------------------------------------------------------------ top apps
panels.append({
    "type": "barchart", "title": "Top apps in range",
    "description": "Total foreground hours per app across the selected range.",
    "datasource": DS, "gridPos": gp(16, 4, 8, 9),
    "targets": sql("""
SELECT app AS "App",
       SUM(seconds) / 3600.0 AS "Hours"
FROM health.v_screentime_daily_app
WHERE $__timeFilter(day)
GROUP BY app
ORDER BY 2 DESC
LIMIT 10
""", "table"),
    "fieldConfig": {"defaults": {
        # "short", not "h": Grafana's hour unit auto-scales past 24h into
        # "3.2 days", so a bar axis in hours ends up mixing units.
        "unit": "short", "decimals": 1,
        "color": {"mode": "fixed", "fixedColor": ACCENT},
        "custom": {"fillOpacity": 85, "lineWidth": 0, "axisLabel": "hours",
                   "gradientMode": "none", "thresholdsStyle": {"mode": "off"}},
        "thresholds": {"mode": "absolute", "steps": [{"color": ACCENT, "value": None}]},
    }, "overrides": []},
    "options": {"orientation": "horizontal", "xField": "App",
                "showValue": "always", "stacking": "none",
                "legend": {"showLegend": False},
                "tooltip": {"mode": "single", "sort": "none"},
                "xTickLabelRotation": 0, "xTickLabelSpacing": 0},
})

# -------------------------------------------------------------- hour of day
panels.append({
    "type": "barchart", "title": "When the phone gets used",
    "description": "Average minutes of screen time per hour of the local day, "
                   "averaged across every day in the selected range.",
    "datasource": DS, "gridPos": gp(0, 13, 12, 9),
    "targets": sql("""
WITH span AS (
  SELECT GREATEST(COUNT(DISTINCT day), 1) AS n_days
  FROM health.v_screentime_hourly
  WHERE $__timeFilter(ts)
)
SELECT lpad(h.hour_of_day::text, 2, '0') AS "Hour",
       SUM(h.seconds) / 60.0 / span.n_days AS "Avg minutes"
FROM health.v_screentime_hourly h
CROSS JOIN span
WHERE $__timeFilter(h.ts)
GROUP BY h.hour_of_day, span.n_days
ORDER BY 1
""", "table"),
    "fieldConfig": {"defaults": {
        "unit": "short", "decimals": 1,
        "color": {"mode": "fixed", "fixedColor": ACCENT},
        "custom": {"fillOpacity": 85, "lineWidth": 0,
                   "axisLabel": "avg minutes", "gradientMode": "none"},
    }, "overrides": []},
    "options": {"orientation": "vertical", "xField": "Hour",
                "showValue": "never", "stacking": "none",
                "legend": {"showLegend": False},
                "tooltip": {"mode": "single", "sort": "none"},
                "xTickLabelRotation": 0},
})

# -------------------------------------------------------------- late night
panels.append({
    "type": "timeseries", "title": "Late-night use (22:00 - 02:00)",
    "description": "Minutes of screen time in the four hours around bedtime, "
                   "attributed to the night it started - so 00:30 counts "
                   "toward the previous day. This is the panel to overlay "
                   "against ResMed sleep onset once that source lands.",
    "datasource": DS, "gridPos": gp(12, 13, 12, 9),
    "targets": sql("""
SELECT CASE WHEN hour_of_day < 2 THEN day - interval '1 day' ELSE day END AS time,
       SUM(seconds) / 60.0 AS "Late-night minutes"
FROM health.v_screentime_hourly
WHERE $__timeFilter(ts)
  AND (hour_of_day >= 22 OR hour_of_day < 2)
GROUP BY 1
ORDER BY 1
"""),
    "fieldConfig": {"defaults": {
        "unit": "short", "decimals": 0,
        "color": {"mode": "fixed", "fixedColor": "#9085e9"},
        "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 15,
                   "showPoints": "auto", "pointSize": 5,
                   "lineInterpolation": "smooth", "axisLabel": "minutes",
                   "gradientMode": "none",
                   "spanNulls": False},
    }, "overrides": []},
    "options": {"legend": HIDDEN_LEGEND,
                "tooltip": {"mode": "single", "sort": "none"}},
})

# ------------------------------------------------------ per-app stacked bars
panels.append({
    "type": "timeseries", "title": "Daily breakdown by app",
    "description": "Stacked daily hours for the six largest apps in range; "
                   "everything else folds into Other. Colors are pinned per "
                   "app in the panel overrides, so a series keeps its colour "
                   "when the ranking changes - add an override to pin a new app.",
    "datasource": DS, "gridPos": gp(0, 22, 16, 10),
    "targets": sql("""
WITH top AS (
  SELECT app
  FROM health.v_screentime_daily_app
  WHERE $__timeFilter(day)
  GROUP BY app
  ORDER BY SUM(seconds) DESC
  LIMIT 6
)
SELECT a.day AS time,
       CASE WHEN a.app IN (SELECT app FROM top) THEN a.app ELSE 'Other' END AS metric,
       SUM(a.seconds) / 3600.0 AS value
FROM health.v_screentime_daily_app a
WHERE $__timeFilter(a.day)
GROUP BY 1, 2
ORDER BY 1
"""),
    "fieldConfig": {
        "defaults": {
            "unit": "h", "decimals": 1,
            # Stable-by-name so an unpinned app keeps its colour across
            # re-rankings rather than being coloured by position.
            "color": {"mode": "palette-classic-by-name"},
            "custom": {"drawStyle": "bars", "fillOpacity": 80, "lineWidth": 0,
                       "barAlignment": 0, "barWidthFactor": 0.8,
                       "axisLabel": "hours", "gradientMode": "none",
                       "showPoints": "never",
                       "stacking": {"mode": "normal", "group": "A"}},
        },
        "overrides": [
            {"matcher": {"id": "byName", "options": name},
             "properties": [{"id": "color",
                             "value": {"mode": "fixed", "fixedColor": hexv}}]}
            for name, hexv in APP_COLORS.items()
        ],
    },
    "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                "tooltip": {"mode": "multi", "sort": "desc"}},
})

# ---------------------------------------------------------------- unlocks
panels.append({
    "type": "timeseries", "title": "Unlocks per day",
    "description": "Times the phone was unlocked per local day.",
    "datasource": DS, "gridPos": gp(16, 22, 8, 10),
    "targets": sql("""
SELECT day AS time, unlocks AS "Unlocks"
FROM health.v_screentime_daily
WHERE $__timeFilter(day)
ORDER BY day
"""),
    "fieldConfig": {"defaults": {
        "unit": "short", "decimals": 0,
        "color": {"mode": "fixed", "fixedColor": "#c98500"},
        # Bar geometry pinned explicitly rather than left to Grafana's
        # defaults, so a version bump cannot silently restyle the panel.
        "custom": {"drawStyle": "bars", "fillOpacity": 70, "lineWidth": 0,
                   "barAlignment": 0, "barWidthFactor": 0.7,
                   "axisLabel": "unlocks", "gradientMode": "none",
                   "showPoints": "never",
                   "scaleDistribution": {"type": "linear"}},
    }, "overrides": []},
    "options": {"legend": HIDDEN_LEGEND,
                "tooltip": {"mode": "single", "sort": "none"}},
})

# ------------------------------------------------------------------- table
panels.append({
    "type": "table", "title": "App detail",
    "description": "Per-app totals for the selected range. Doubles as the "
                   "table view for the charts above, so no reading depends on "
                   "colour alone.",
    "datasource": DS, "gridPos": gp(0, 32, 24, 10),
    "targets": sql("""
WITH totals AS (
  SELECT SUM(seconds) AS all_seconds,
         GREATEST(COUNT(DISTINCT day), 1) AS n_days
  FROM health.v_screentime_daily_app
  WHERE $__timeFilter(day)
),
opens AS (
  SELECT e.display_name AS app, SUM(o.value) AS opens
  FROM health.observations o
  JOIN health.metrics  m ON m.id = o.metric_id
  JOIN health.entities e ON e.id = o.entity_id
  WHERE m.key = 'app_session_count' AND $__timeFilter(o.ts)
  GROUP BY 1
)
SELECT a.app                                        AS "App",
       SUM(a.seconds) / 3600.0                      AS "Total hours",
       SUM(a.seconds) / 60.0 / t.n_days             AS "Avg min/day",
       100.0 * SUM(a.seconds) / NULLIF(t.all_seconds, 0) AS "Share %",
       COALESCE(op.opens, 0)                        AS "Opens",
       SUM(a.seconds) / 60.0 / NULLIF(op.opens, 0)  AS "Avg min/open"
FROM health.v_screentime_daily_app a
CROSS JOIN totals t
LEFT JOIN opens op ON op.app = a.app
WHERE $__timeFilter(a.day)
GROUP BY a.app, t.n_days, t.all_seconds, op.opens
ORDER BY 2 DESC
""", "table"),
    "fieldConfig": {
        "defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}},
                     "decimals": 1},
        "overrides": [
            {"matcher": {"id": "byName", "options": "Total hours"},
             "properties": [
                 {"id": "unit", "value": "short"},
                 {"id": "custom.cellOptions",
                  "value": {"type": "gauge", "mode": "gradient"}},
                 {"id": "color", "value": {"mode": "fixed", "fixedColor": ACCENT}},
             ]},
            {"matcher": {"id": "byName", "options": "Share %"},
             "properties": [{"id": "unit", "value": "percent"}]},
            {"matcher": {"id": "byName", "options": "Opens"},
             "properties": [{"id": "decimals", "value": 0}]},
        ],
    },
    "options": {"showHeader": True, "cellHeight": "sm",
                "footer": {"show": False, "reducer": ["sum"], "countRows": False},
                "sortBy": [{"desc": True, "displayName": "Total hours"}]},
})

# Stable panel ids so ?viewPanel=N deep-links survive regeneration.
for i, panel in enumerate(panels, start=1):
    panel["id"] = i

dashboard = {
    "uid": "health-screentime",
    "title": "Screen Time",
    "tags": ["health", "screentime"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "editable": True,
    "refresh": "5m",
    "time": {"from": "now-30d", "to": "now"},
    "timepicker": {"refresh_intervals": ["5m", "15m", "1h", "6h", "1d"]},
    "graphTooltip": 1,          # shared crosshair across panels
    "panels": panels,
}

with open("grafana/dashboards/screentime.json", "w") as fh:
    json.dump(dashboard, fh, indent=2)
    fh.write("\n")
print(f"wrote {len(panels)} panels")
