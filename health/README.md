# Health

Screen time dashboard. Postgres + Grafana on mon01, phone uploads over Tailscale.

## look at it

<http://mon01:3000> — no login, it opens straight to the dashboard.

It currently has 90 days of **fake** demo data in it. Wipe it when the phone
starts reporting for real:

```
ssh matt@mon01 "sudo -u postgres psql -d health -c \
  'TRUNCATE health.observations, health.sessions, health.raw_events, health.ingest_batches'"
```

Put fake data back any time:

```
python3 tools/seed_screentime.py --days 90 \
  --url http://mon01:8000/v1/ingest/phone_screentime \
  --token "$(ssh matt@mon01 'sudo grep INGEST_TOKEN /var/lib/health/secrets.env' | cut -d= -f2)"
```

## put it on the phone

The phone is on the tailnet, so this works from anywhere — not just home wifi.

**1. Install the app.** The APK was sent to the phone with Taildrop. To send
it again:

```
tailscale file cp chimera-screentime.apk galaxy-s26:
```

On the phone: open the Tailscale notification → tap the APK → allow
"install unknown apps" if asked.

**2. Get the token:**

```
ssh matt@mon01 'sudo grep INGEST_TOKEN /var/lib/health/secrets.env'
```

**3. Open *Chimera Screen Time* and fill in:**

| field    | value                                            |
|----------|--------------------------------------------------|
| Endpoint | `http://mon01:8000/v1/ingest/phone_screentime`    |
| Token    | the one from step 2                              |

**4. Tap "Grant usage access"** → find *Chimera Screen Time* → turn it on.
Android only allows this from Settings, never a popup.

**5. Tap "Save & schedule", then "Sync now".**

Uploads every 2 hours after that.

### did it work

```
curl http://mon01:8000/healthz

ssh matt@mon01 "sudo -u postgres psql -d health -c \
  'SELECT day::date, round(screen_time_hours::numeric,1) hours, unlocks::int \
     FROM health.v_screentime_daily ORDER BY day DESC LIMIT 5'"
```

Nothing arriving? `ssh matt@mon01 'sudo journalctl -u health-ingest -n 50'`

## rebuild the apk

No JDK or Android SDK on the Mac, so build it on nix02 in Docker:

```
tar czf - android | ssh matt@nix02 'mkdir -p ~/apkbuild && tar xzf - -C ~/apkbuild'
# then run health/tools/build-apk.sh inside eclipse-temurin:17-jdk on nix02
scp matt@nix02:~/apkbuild/android/app/build/outputs/apk/debug/app-debug.apk .
```

Two things that break this build:

- `gradle.properties` must set `android.useAndroidX=true`. The app uses
  `androidx.work`; without it nothing compiles, in Studio or anywhere else.
- Never `yes | sdkmanager --licenses` — it deadlocks when stdout is not a
  tty. Write the licence hashes into `$ANDROID_HOME/licenses/` instead.

## deploy

```
nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#mon01 --target-host matt@mon01 --build-host matt@mon01 --sudo
```

All of it is `nix/hosts/mon01/health.nix`: Postgres + TimescaleDB, the ingest
API under uvicorn, Grafana provisioned from `grafana/`.

Nothing is open to the LAN — only port 22. Grafana and ingest are reachable
over the tailnet only, which is what makes the no-login dashboard reasonable.
The ingest token still gates every write.

Secrets are generated on the box into `/var/lib/health/`, never in the Nix
store. Back up `/var/lib/postgresql` — it is the only copy of the health record.

## layout

```
db/migrations/  schema, append-only — add a file, never edit an applied one
ingest/         FastAPI write API, one module per source
grafana/        datasource + dashboard, provisioned from disk
android/        the phone app
tools/          dashboard generator, seeder, tests
```

Dashboard JSON is generated — edit `tools/gen_dashboard.py` and re-run it. UI
edits get overwritten on reload.

## adding a source

A migration registering it, a module in `ingest/app/sources/`, one line in
that package's `__init__.py`. Routes and auth generate themselves.

The phone uploads raw sessions, not totals. `health.rebuild_screentime()`
derives the rollups and is safe to re-run, so re-uploads can't double-count
and changing how usage is bucketed is a backfill, not a gap.

**Why Postgres, not the influx box:** InfluxDB 3 Core only queries the last
72 hours, which kills every multi-month trend. The influxdb3 unit on mon01 is
untouched and unused by this.
