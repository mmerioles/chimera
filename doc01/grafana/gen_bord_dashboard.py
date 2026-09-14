"""Generate the bord dashboard JSON for grafana on doc01.

Same idea as health/tools/gen_dashboard.py: the committed artifact is the JSON
this emits, hand-editing it is how dashboards rot. Regenerate with

    python3 doc01/grafana/gen_bord_dashboard.py

then `cd tofu && tofu apply` pushes it to grafana through the API.

Reads the bord Supabase project through the `grafana_ro` role (bord-reader.sql).

The live project has migrations 0001-0004 applied. 0005-0008 (regions,
referrals + link clicks, standing week, ops outbox, support) are written in the
bord repo but not pushed. A panel against a missing table errors, so sections
that need later migrations are behind flags here - flip one on, regenerate,
re-run bord-reader.sql (new tables need the read policy), `tofu apply`.
"""
import json
from pathlib import Path

INVITES = False   # needs 0007_referrals.sql: invite_codes, referrals, link_clicks

DS = {"type": "grafana-postgresql-datasource", "uid": "bord-supabase"}

# Validated dark-mode categorical palette (dataviz slots 1-6), fixed order, plus
# a neutral for "other". Identity follows the entity, never its rank.
C1, C2, C3, C4, C5, C6, NEUTRAL = (
    "#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#7c7b74")
ACCENT = C1
GOOD, WARN = "#199e70", "#c98500"

LEGEND_HIDDEN = {"showLegend": False, "displayMode": "list",
                 "placement": "bottom", "calcs": []}
LEGEND = {"showLegend": True, "displayMode": "list",
          "placement": "bottom", "calcs": []}


def sql(q, fmt="time_series"):
    return [{"datasource": DS, "editorMode": "code", "format": fmt,
             "rawQuery": True, "rawSql": q.strip(), "refId": "A"}]


def gp(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}


def fixed(color):
    return {"color": {"mode": "fixed", "fixedColor": color},
            "thresholds": {"mode": "absolute",
                           "steps": [{"color": color, "value": None}]}}


def stat(title, q, grid, desc, unit="none", decimals=0, color=ACCENT):
    return {
        "type": "stat", "title": title, "description": desc,
        "datasource": DS, "gridPos": grid, "targets": sql(q, "table"),
        "fieldConfig": {"defaults": {"unit": unit, "decimals": decimals,
                                     "mappings": [], **fixed(color)},
                        "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "",
                                      "values": False},
                    "orientation": "auto", "textMode": "auto",
                    "colorMode": "value", "graphMode": "none",
                    "justifyMode": "auto"},
    }


def timeseries(title, q, grid, desc, unit="short", color=ACCENT, bars=False,
               legend=LEGEND_HIDDEN, overrides=None, stack=False):
    custom = {"drawStyle": "bars" if bars else "line", "lineWidth": 2,
              "fillOpacity": 70 if bars else 12, "pointSize": 5,
              "showPoints": "never", "spanNulls": False,
              "lineInterpolation": "linear", "barAlignment": 0,
              "stacking": {"mode": "normal" if stack else "none", "group": "A"},
              "axisBorderShow": False, "gradientMode": "none"}
    return {
        "type": "timeseries", "title": title, "description": desc,
        "datasource": DS, "gridPos": grid, "targets": sql(q),
        "fieldConfig": {"defaults": {"unit": unit, "decimals": 0,
                                     "custom": custom, **fixed(color)},
                        "overrides": overrides or []},
        "options": {"legend": legend,
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }


def barchart(title, q, grid, desc, unit="short", color=ACCENT,
             orientation="horizontal", overrides=None):
    return {
        "type": "barchart", "title": title, "description": desc,
        "datasource": DS, "gridPos": grid, "targets": sql(q, "table"),
        "fieldConfig": {"defaults": {"unit": unit, "decimals": 0,
                                     "custom": {"fillOpacity": 85,
                                                "lineWidth": 0,
                                                "axisBorderShow": False},
                                     **fixed(color)},
                        "overrides": overrides or []},
        "options": {"orientation": orientation, "showValue": "auto",
                    "barWidth": 0.7, "groupWidth": 0.7, "xTickLabelSpacing": 0,
                    "legend": LEGEND_HIDDEN,
                    "tooltip": {"mode": "single", "sort": "none"}},
    }


def table(title, q, grid, desc, overrides=None):
    return {
        "type": "table", "title": title, "description": desc,
        "datasource": DS, "gridPos": grid, "targets": sql(q, "table"),
        "fieldConfig": {"defaults": {"custom": {"align": "auto",
                                                "cellOptions": {"type": "auto"}}},
                        "overrides": overrides or []},
        "options": {"showHeader": True, "cellHeight": "sm",
                    "footer": {"show": False}},
    }


def series_color(name, color):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": "color",
                            "value": {"mode": "fixed", "fixedColor": color}}]}


def row(title, y):
    return {"type": "row", "title": title, "collapsed": False,
            "gridPos": gp(0, y, 24, 1), "panels": []}


panels = []
y = 0

# ---------------------------------------------------------------- headline
panels += [
    stat("Players", """
SELECT count(*) AS "Players" FROM profiles
""", gp(0, y, 4, 4),
         "Everyone with a completed profile. Not affected by the time range."),
    stat("New players", """
SELECT count(*) AS "New players" FROM profiles WHERE $__timeFilter(created_at)
""", gp(4, y, 4, 4), "Profiles created in the selected range.", color=C3),
    stat("Session sign-ups", """
SELECT count(*) AS "Session sign-ups" FROM slot_signups WHERE $__timeFilter(created_at)
""", gp(8, y, 4, 4), "Seats taken at a venue night in the selected range.",
         color=C2),
    stat("Seats filled", """
SELECT CASE WHEN sum(seats_total) = 0 THEN 0
       ELSE 100.0 * sum(seats_total - seats_left) / sum(seats_total) END AS "Seats filled"
FROM venue_slots
""", gp(12, y, 4, 4),
         "Share of all standing-night seats currently taken, across every "
         "venue. Live, not range-bound.", unit="percent", decimals=0, color=C4),
]
if INVITES:
    panels += [
        stat("Referred sign-ups", """
SELECT count(*) AS "Referred sign-ups" FROM referrals WHERE $__timeFilter(signed_up)
""", gp(16, y, 4, 4), "Accounts created through a friend's invite code in "
             "the range.", color=C5),
        stat("Referred & seated", """
SELECT count(*) AS "Referred & seated" FROM referrals
WHERE status = 'seated' AND $__timeFilter(seated_at)
""", gp(20, y, 4, 4), "Invitees who actually sat down at a table in the "
             "range. The number the referral ladder is built on.", color=GOOD),
    ]
else:
    panels += [
        stat("Drink tokens ready", """
SELECT count(*) AS "Drink tokens ready" FROM drink_tokens WHERE status = 'ready'
""", gp(16, y, 4, 4), "Tokens minted by matches and not yet redeemed at the "
             "bar. Live.", color=C5),
        stat("Friendships", """
SELECT count(*) AS "Friendships" FROM friendships WHERE status = 'accepted'
""", gp(20, y, 4, 4), "Accepted friend pairs, all time.", color=GOOD),
    ]
y += 4

# ---------------------------------------------------------------- growth
panels.append(row("Growth", y)); y += 1
panels += [
    timeseries("New players per day", """
SELECT $__timeGroupAlias(created_at, '1d'), count(*) AS "New players"
FROM profiles WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 1
""", gp(0, y, 12, 8), "Profiles completed per day.", bars=True, color=C3),
    timeseries("Session sign-ups per day", """
SELECT $__timeGroupAlias(created_at, '1d'), count(*) AS "Sign-ups"
FROM slot_signups WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 1
""", gp(12, y, 12, 8), "Seats taken per day, all venues.", bars=True,
               color=C2),
]
y += 8

# ---------------------------------------------------------------- sessions
panels.append(row("Sessions", y)); y += 1
panels += [
    table("Standing week", """
SELECT v.name AS "Venue", v.neighborhood AS "Area", s.day AS "Day", s.time AS "Time",
       s.seats_total AS "Seats", s.seats_left AS "Left",
       (SELECT count(*) FROM slot_signups ss WHERE ss.slot_id = s.id) AS "Signed up"
FROM venue_slots s JOIN venues v ON v.id = s.venue_id
WHERE v.state = 'approved'
ORDER BY v.name,
  array_position(ARRAY['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'], s.day)
""", gp(0, y, 14, 9),
          "Every approved venue's nights, live seat counts, and how many "
          "people have signed up. Left = seats still open.",
          overrides=[{"matcher": {"id": "byName", "options": "Left"},
                      "properties": [{"id": "custom.cellOptions",
                                      "value": {"type": "color-text"}},
                                     {"id": "thresholds",
                                      "value": {"mode": "absolute",
                                                "steps": [{"color": WARN, "value": None},
                                                          {"color": GOOD, "value": 1}]}}]}]),
    barchart("Sign-ups by venue", """
SELECT v.name AS "Venue", count(ss.*) AS "Sign-ups"
FROM venues v
LEFT JOIN venue_slots s ON s.venue_id = v.id
LEFT JOIN slot_signups ss ON ss.slot_id = s.id AND $__timeFilter(ss.created_at)
WHERE v.state = 'approved'
GROUP BY v.name ORDER BY 2 DESC, 1
""", gp(14, y, 10, 9), "Seats taken per venue in the selected range.",
             color=C2),
]
y += 9

# ---------------------------------------------------------------- invites
if INVITES:
  panels.append(row("Invites & links", y)); y += 1
  panels += [
    timeseries("Link clicks per day", """
SELECT $__timeGroupAlias(created_at, '1d'),
       count(*) FILTER (WHERE ua_class = 'ios')     AS "iOS",
       count(*) FILTER (WHERE ua_class = 'android') AS "Android",
       count(*) FILTER (WHERE ua_class IS NULL OR ua_class NOT IN ('ios','android')) AS "Other"
FROM link_clicks WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 1
""", gp(0, y, 12, 8), "Opens of bordgame.app/i/... links by device class.",
               bars=True, stack=True, legend=LEGEND,
               overrides=[series_color("iOS", C1), series_color("Android", C3),
                          series_color("Other", NEUTRAL)]),
    barchart("Clicks by source", """
SELECT coalesce(src, '(none)') AS "Source", count(*) AS "Clicks"
FROM link_clicks WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 2 DESC LIMIT 12
""", gp(12, y, 6, 8), "Where invite links get opened from, per the src "
             "parameter. (none) is a bare link.", color=C1),
    barchart("Invite funnel", """
SELECT 'Clicked' AS "Step", count(*) AS "n" FROM link_clicks WHERE $__timeFilter(created_at)
UNION ALL
SELECT 'Signed up', count(*) FROM referrals WHERE $__timeFilter(signed_up)
UNION ALL
SELECT 'Seated', count(*) FROM referrals WHERE status = 'seated' AND $__timeFilter(seated_at)
""", gp(18, y, 6, 8), "Link opened, account created through a code, invitee "
             "seated at a table. Same range for all three.", color=C5),
  ]
  y += 8

# ---------------------------------------------------------------- queue
panels.append(row("Queue & matches (parked, but live in the DB)", y)); y += 1
panels += [
    stat("Waiting now", """
SELECT count(*) AS "Waiting now" FROM queue_members WHERE status = 'waiting'
""", gp(0, y, 4, 4), "People in the live queue right now, all venues.",
         color=C4),
    stat("Matches", """
SELECT count(*) AS "Matches" FROM matches WHERE $__timeFilter(created_at)
""", gp(4, y, 4, 4), "Matches created in the range, any outcome.", color=C1),
    barchart("Match outcomes", """
SELECT status AS "Status", count(*) AS "Matches"
FROM matches WHERE $__timeFilter(created_at)
GROUP BY status
ORDER BY array_position(ARRAY['accepting','set','released','done'], status)
""", gp(8, y, 8, 4), "accepting = waiting on players, set = everyone in, "
             "released = someone bailed, done = played.", color=C1,
             orientation="horizontal"),
    barchart("Drink tokens", """
SELECT status AS "Status", count(*) AS "Tokens" FROM drink_tokens GROUP BY status ORDER BY status
""", gp(16, y, 8, 4), "Tokens minted by matches: ready to redeem vs used at "
             "the bar. Live, all time.", color=C6),
]
y += 4

# ---------------------------------------------------------------- community
panels.append(row("Community", y)); y += 1
panels += [
    timeseries("Karma given per day", """
SELECT $__timeGroupAlias(created_at, '1d'),
       sum(delta) FILTER (WHERE delta > 0) AS "Earned",
       sum(delta) FILTER (WHERE delta < 0) AS "Lost"
FROM karma_events WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 1
""", gp(0, y, 12, 8), "Net karma movement per day. Lost is drawn below zero.",
               bars=True, legend=LEGEND,
               overrides=[series_color("Earned", GOOD), series_color("Lost", C2)]),
    barchart("Karma distribution", """
SELECT (karma / 10) * 10 AS "Karma", count(*) AS "Players"
FROM profiles GROUP BY 1 ORDER BY 1
""", gp(12, y, 6, 8), "Players by karma decile. Everyone starts at 70.",
             color=C4, orientation="vertical"),
    stat("Reports", """
SELECT count(*) AS "Reports" FROM postgame WHERE report
""", gp(18, y, 6, 4), "Post-game reports filed, all time. Should stay near "
         "zero; each one is a conversation.", color=WARN),
    stat("Play again", """
SELECT count(*) AS "Play again" FROM postgame WHERE play_again
""", gp(18, y + 4, 6, 4), "Post-game 'would play again' votes, all time.",
         color=GOOD),
]
y += 8

dashboard = {
    "uid": "bord",
    "title": "bord",
    "description": "Players, nights, invites. Read straight from the Supabase "
                   "project through the grafana_ro role.",
    "tags": ["bord", "supabase"],
    "timezone": "browser",
    "editable": True,
    "graphTooltip": 1,
    "refresh": "5m",
    "time": {"from": "now-30d", "to": "now"},
    "timepicker": {"refresh_intervals": ["1m", "5m", "15m", "1h"]},
    "schemaVersion": 39,
    "version": 1,
    "panels": panels,
    "templating": {"list": []},
    "annotations": {"list": []},
    "links": [],
}

out = Path(__file__).parent / "dashboards" / "bord.json"
out.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {out} ({len(panels)} panels)")
