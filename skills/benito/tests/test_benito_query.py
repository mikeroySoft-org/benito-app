#!/usr/bin/env python3
"""Tests for skills/benito/scripts/benito-query.

  python3 skills/benito/tests/test_benito_query.py
      Fixture checks: loads fixture.sql into a temp DB and checks every subcommand, the
      golden numbers, and that nothing can write to the file.

  python3 skills/benito/tests/test_benito_query.py --server server/target/debug/benito-server
      Also starts that binary on a temp DB and a free loopback port, seeds it through the
      API (seed.py), and checks that `benito-query day` matches GET /summary/daily for
      every day in three time zones.

  ... --server BIN --write-fixture
      Regenerates fixture.sql from the freshly seeded scratch server.

Python 3.9+ standard library only. Never touches a real Benito database.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from typing import Any, Dict, List

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "scripts", "benito-query")
FIXTURE = os.path.join(HERE, "fixture.sql")
PT = "America/Los_Angeles"

failures: List[str] = []
passed = 0


def check(cond: bool, what: str) -> None:
    global passed
    if cond:
        passed += 1
    else:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)


def run(db: str, *args: str, ok: bool = True) -> subprocess.CompletedProcess:
    p = subprocess.run([sys.executable, HELPER, "--db", db, *args], capture_output=True, text=True)
    if ok and p.returncode != 0:
        failures.append(f"benito-query {' '.join(args)} exited {p.returncode}: {p.stderr.strip()}")
        print(f"FAIL: {failures[-1]}", file=sys.stderr)
    return p


def run_json(db: str, *args: str) -> Any:
    p = run(db, "--json", *args)
    return json.loads(p.stdout) if p.returncode == 0 else {}


def sha(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def fixture_now() -> str:
    with open(FIXTURE) as f:
        for line in f:
            if line.startswith("-- seed_now:"):
                return line.split(":", 1)[1].strip()
    raise SystemExit("fixture.sql has no '-- seed_now:' header")


def build_fixture_db(tmp: str) -> str:
    db = os.path.join(tmp, "fixture.db")
    conn = sqlite3.connect(db)
    with open(FIXTURE) as f:
        conn.executescript(f.read())
    conn.close()
    return db


# Golden per-day totals for the seeded week (see seed.py), America/Los_Angeles days.
GOLDEN: Dict[str, Dict[str, Any]] = {
    "2026-10-19": dict(feed_breast_count=2, feed_breast_left=1, feed_breast_right=1, feed_bottle_count=1,
                       bottle_oz_equiv=4.0, feed_seconds=3300.0, nursing_seconds=2400.0, diaper_wet=1,
                       diaper_dirty=1, diaper_both=1, sleep_event_count=2, sleep_hours=3.37,
                       walk_seconds=2400.0, medicine_count=1, total_events=10),
    "2026-10-20": dict(feed_breast_count=2, feed_breast_left=1, feed_breast_right=0, feed_bottle_count=1,
                       bottle_ml_total=120.0, bottle_oz_equiv=4.06, feed_seconds=1800.0, nursing_seconds=600.0,
                       diaper_wet=2, diaper_dirty=1, diaper_both=0, sleep_event_count=1, sleep_hours=5.13,
                       crying_seconds=1380.0, car_ride_seconds=1800.0, pump_count=1, total_events=10),
    "2026-10-21": dict(feed_breast_count=0, nursing_seconds=1200.0, feed_solid_count=1, feed_bottle_count=1,
                       bottle_oz_equiv=3.5, diaper_both=1, sleep_event_count=1, sleep_hours=3.0,
                       crying_seconds=2700.0, total_events=6),
    "2026-10-22": dict(feed_breast_count=2, nursing_seconds=3000.0, diaper_wet=1, diaper_dirty=1,
                       sleep_hours=1.5, total_events=7),
}


def fixture_checks(tmp: str) -> None:
    db = build_fixture_db(tmp)
    before = sha(db)
    now = fixture_now()
    base = ["--tz", PT, "--now", now]
    kid = base + ["--child", "Benito"]

    info = run_json(db, *base, "info")
    check([c["name"] for c in info.get("children", [])] == ["Benito", "Pip"], "info lists both children")

    p = run(db, *base, "today", ok=False)
    check(p.returncode == 2 and "several children" in p.stderr, "two children without --child is a clear error")

    for day, want in GOLDEN.items():
        got = run_json(db, *kid, "day", day)
        for k, v in want.items():
            check(got.get(k) == v, f"day {day} {k}: want {v}, got {got.get(k)}")

    pip = run_json(db, *base, "--child", "pip", "day", "2026-10-22")
    check(pip.get("diaper_wet") == 1 and pip.get("total_events") == 1, "--child matches names case-insensitively")

    timers = {t["kind"]: t for t in run_json(db, *kid, "timers").get("timers", [])}
    check(set(timers) == {"sleep", "feed_breast"}, f"active timers are sleep + feed_breast, got {sorted(timers)}")
    check(timers.get("sleep", {}).get("active_seconds") == 2400, "running sleep timer excludes its 10-min pause")
    check(timers.get("feed_breast", {}).get("active_seconds") == 240, "paused nursing timer excludes the open pause")
    check(timers.get("feed_breast", {}).get("state") == "paused", "nursing timer reports paused")

    crying = [e for e in run_json(db, *kid, "events", "--type", "activity",
                                  "--date", run_json(db, *kid, "today").get("day", "")).get("events", [])
              if e["subtype"] == "crying"]
    check(len(crying) == 1 and crying[0]["paused_seconds"] == 300 and crying[0]["active_seconds"] == 1200,
          "stopped crying timer became an activity/crying event with its pause excluded")

    last = run_json(db, *kid, "last-feed")
    check(last.get("last_feed", {}).get("started_at", "").startswith("2026-10-22T18:00"),
          f"last feed is Oct 22 11:00 PT, got {last.get('last_feed', {}).get('started_at')}")
    check(run(db, *kid, "last-feed").stdout.count("since it started") == 1, "last-feed text says time since start")

    week = run_json(db, *kid, "feeds", "--start", "2026-10-19", "--end", "2026-10-22")
    check([d["day"] for d in week.get("days", [])] == list(GOLDEN), "feeds --start/--end covers each local day")
    for cmd in ("sleep", "diapers", "crying"):
        check(run(db, *kid, cmd, "--days", "5").returncode == 0, f"{cmd} --days 5 runs")
    text = run(db, *kid, "today").stdout
    check("so far" in text and "midnight to midnight" in text, "today labels a partial local day")

    # Tokyo days start at 15:00 UTC: the Oct 19 22:00 PT sleep falls on Oct 20 there.
    tokyo = run_json(db, "--tz", "Asia/Tokyo", "--now", now, "--child", "Benito", "day", "2026-10-20")
    check(tokyo.get("from") == "2026-10-19T15:00:00+00:00", "Tokyo day starts at local midnight")

    p = run(db, *kid, "export-csv", "--start", "2026-10-19", "--end", "2026-10-22")
    rows = p.stdout.strip().splitlines()
    check(rows[0].startswith("id,child_id,type,subtype,started_at,ended_at"), "CSV header matches /export.csv")
    check(len(rows) == 1 + 32, f"CSV has 32 events Oct 19-22 (deleted excluded), got {len(rows) - 1}")

    p = run(db, *kid, "sql", "SELECT type, COUNT(*) AS n FROM events WHERE deleted_at IS NULL GROUP BY type ORDER BY type")
    check(p.stdout.startswith("type\tn\n") and "diaper\t" in p.stdout, "sql runs a SELECT")

    for stmt in ("DELETE FROM events", "UPDATE events SET notes = 'x'", "INSERT INTO server_meta VALUES ('a','b')",
                 "CREATE TABLE t (x)", "DROP TABLE events", "PRAGMA journal_mode = DELETE",
                 "ATTACH DATABASE '" + os.path.join(tmp, "other.db") + "' AS other", "VACUUM",
                 "PRAGMA query_only = OFF"):
        p = run(db, "sql", stmt, ok=False)
        check(p.returncode == 2 and "refused" in p.stderr, f"write refused: {stmt} (rc={p.returncode} {p.stderr.strip()})")
    check(not os.path.exists(os.path.join(tmp, "other.db")), "ATTACH did not create a file")
    check(sha(db) == before, "database file is byte-for-byte unchanged")
    check(not os.path.exists(db + "-wal") and not os.path.exists(db + "-journal"), "no journal files created")

    missing = os.path.join(tmp, "nope.db")
    p = run(missing, "info", ok=False)
    check(p.returncode == 2 and not os.path.exists(missing), "missing DB is an error and is not created")


# --------------------------------------------------------------------------- live server


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def server_checks(binary: str, tmp: str, write_fixture: bool) -> None:
    sys.path.insert(0, HERE)
    import seed  # noqa: E402

    db = os.path.join(tmp, "scratch.db")
    port = free_port()
    env = dict(os.environ, BIND_ADDR=f"127.0.0.1:{port}", DATABASE_PATH=db, BENITO_BONJOUR="0",
               SESSION_SECRET="scratch-test-only", BENITO_ENV_FILE=os.path.join(tmp, "none.env"),
               RUST_LOG="warn")
    proc = subprocess.Popen([os.path.abspath(binary)], env=env, cwd=tmp,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(base + "/health", timeout=1).read()
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise SystemExit("scratch server did not become healthy")
        now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        seeded = seed.seed(base, now)
        api, child = seeded["api"], seeded["child"]

        # The helper must work against a live WAL database the server holds open.
        before = sha(db)
        compared = 0
        for tz in (PT, "UTC", "Asia/Tokyo"):
            days = run_json(db, "--tz", tz, "--child", "Benito", "sleep", "--start", "2026-10-18").get("days", [])
            for d in days:
                q = urllib.parse.urlencode({"child_id": child, "from": d["from"], "to": d["to"]})
                srv = api.call("GET", f"/summary/daily?{q}")
                for k, v in srv.items():
                    if k in ("child_id", "from", "to", "day"):
                        continue
                    check(abs(float(d[k]) - float(v)) < 0.011, f"{tz} {d['day']} {k}: helper {d[k]} vs server {v}")
                compared += 1
        check(compared >= 15, f"compared {compared} day summaries with the server")
        check(sha(db) == before, "helper did not modify the live database")
        state = api.call("GET", f"/state?child_id={child}")
        last = run_json(db, "--child", "Benito", "last-feed")
        check(last.get("last_feed", {}).get("id") == state["last_feed"]["id"], "last-feed matches GET /state")
        print(f"server: compared {compared} days against /summary/daily on 127.0.0.1:{port}")

        if write_fixture:
            dump_fixture(db, now)
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def dump_fixture(db: str, now: dt.datetime) -> None:
    src = sqlite3.connect(db)
    conn = sqlite3.connect(":memory:")
    src.backup(conn)
    src.close()
    # Bearer tokens and password hashes never belong in the repo, even scratch ones.
    conn.executescript("DELETE FROM sessions; DELETE FROM live_activity_tokens;"
                       "UPDATE users SET password_hash = 'fixture-no-password';")
    lines = [
        "-- Benito server DB fixture for skills/benito tests. Generated by",
        "--   python3 skills/benito/tests/test_benito_query.py --server BIN --write-fixture",
        "-- from a scratch server seeded by seed.py (demo data, no real family). Do not edit by hand.",
        f"-- seed_now: {now.isoformat()}",
        *conn.iterdump(),
    ]
    conn.close()
    with open(FIXTURE, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {FIXTURE}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--server", help="benito-server binary to cross-check against")
    ap.add_argument("--write-fixture", action="store_true", help="regenerate fixture.sql (needs --server)")
    a = ap.parse_args()
    if a.write_fixture and not a.server:
        ap.error("--write-fixture needs --server")
    with tempfile.TemporaryDirectory(prefix="benito-query-test-") as tmp:
        if a.server:
            server_checks(a.server, tmp, a.write_fixture)
        if os.path.exists(FIXTURE):
            fixture_checks(tmp)
        else:
            failures.append("fixture.sql missing; run with --server BIN --write-fixture")
    print(f"{passed} checks passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
