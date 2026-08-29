# Health

Grafana dashboard fed by my health data. Screen time first; sleep, runs and
weight plug into the same pipeline later.

---

## 1. Start it on the laptop

```bash
cd health
cp .env.example .env
sed -i '' "s/^INGEST_TOKEN=.*/INGEST_TOKEN=$(openssl rand -hex 32)/" .env
docker compose up -d --build
```

- Dashboard → <http://localhost:3001>
- API docs → <http://localhost:8000/docs>

Want fake data to look at before the phone is wired up:

```bash
export $(grep INGEST_TOKEN .env)
python3 tools/seed_screentime.py --days 120 --token "$INGEST_TOKEN"
```

---

## 2. Get it on the phone

**Install [Android Studio](https://developer.android.com/studio)** — it bundles
the JDK and Android SDK, which this Mac doesn't have. (There's no `gradlew` in
the repo; Android Studio creates it on first sync.)

1. **Phone:** Settings → About phone → tap **Build number** 7 times, then
   Settings → Developer options → enable **USB debugging**. Plug into the Mac
   and accept the pairing prompt.
2. **Android Studio:** File → Open → select `health/android`. Wait for Gradle
   sync, then press **Run** (▶) with your phone selected as the target.
3. **In the app**, fill in:

   | Field | Value |
   |---|---|
   | Endpoint | `http://192.168.2.75:8000/v1/ingest/phone_screentime` |
   | Token | the `INGEST_TOKEN` from `.env` |

   Get the token with `grep INGEST_TOKEN .env`. If your Mac's IP changed, find
   it with `ipconfig getifaddr en0`.
4. Tap **Grant usage access** → find *Chimera Screen Time* → toggle it on.
   (Android only allows this from Settings, never a popup.)
5. Tap **Save & schedule**, then **Sync now**.

Phone and Mac must be on the same wifi. It uploads every 2 hours after that.

### Did it work?

```bash
curl -s localhost:8000/healthz
docker compose exec -T db psql -U health -d health -c \
  "SELECT day::date, round(screen_time_hours::numeric,1) AS hours, unlocks::int
     FROM health.v_screentime_daily ORDER BY day DESC LIMIT 5;"
```

Real data shows up on the dashboard immediately. If nothing arrives, check
`docker compose logs ingest`.

---

## Layout

```
db/migrations/     schema (append-only; add a file, never edit an applied one)
ingest/            FastAPI write API, one module per source
grafana/           datasource + dashboard, provisioned from disk
android/           the phone app
tools/             dashboard generator, seeder, tests
```

Dashboard JSON is **generated** — edit `tools/gen_dashboard.py` and re-run it.
UI edits get overwritten on reload.

Run the tests:

```bash
docker compose exec -T db psql -U health -d health -v ON_ERROR_STOP=1 < tools/test_rollups.sql
```

---

## How the data flows

The phone uploads **raw sessions**, not totals. The server derives hourly and
daily rollups with `health.rebuild_screentime()`, which deletes and rewrites
whatever window you give it. So it's safe to re-run, re-uploads can't
double-count, and changing how usage is bucketed later is a backfill over
existing history instead of a permanent gap.

Same three shapes take every future source: intervals (sleep, runs) →
`sessions`, points (unlocks) → `raw_events`, scalars (weight) →
`observations`.

**Adding a source:** a migration registering it, a module in
`ingest/app/sources/`, one line in that package's `__init__.py`. Routes and
auth generate themselves.

**Why Postgres, not the Influx box on mon01:** InfluxDB 3 Core can only query
the last 72 hours, which kills every multi-month trend. mon01's Influx
container is untouched and unused by this.

---

## Moving to mon01

Local-dev-only settings that must **not** come along:

- `GF_AUTH_ANONYMOUS_*` — exists so localhost opens without a login
- `sslmode=disable`, and the default passwords in `.env.example`

And on the VM:

- Secrets via `environmentFile` (agenix/sops) — anything inline in a `.nix`
  file is world-readable in `/nix/store`
- Bind ingest to the Tailscale IP only: `ports = [ "100.x.y.z:8000:8000" ]`,
  and keep 8000 out of `networking.firewall.allowedTCPPorts`
- Point the phone's endpoint at the tailnet name instead of the LAN IP
- Back up the `db_data` volume — it's the only copy of the health record

Timezone lives in `LOCAL_TIMEZONE` in `.env`; a "day" is local midnight to
local midnight everywhere.
