#!/usr/bin/env python3
"""Check pubspec.lock against the OSV vulnerability database.

DEVELOPER / CI TOOL ONLY - never shipped in the app. It contacts the network
at audit time on the developer machine or CI runner:

  1. https://api.osv.dev/v1/querybatch  (preferred), or, if unreachable,
  2. the OSV Pub ecosystem dump
     https://storage.googleapis.com/osv-vulnerabilities/Pub/all.zip
     matched locally (ECOSYSTEM/SEMVER ranges and explicit version lists).

Usage: osv_check.py [pubspec.lock] [--offline-db PATH_TO_all.zip] [--json]
Exit codes: 0 = no known vulnerabilities, 1 = vulnerabilities found,
            2 = could not check (network / parse error).
Stdlib only (Python 3.9+).
"""
from __future__ import annotations

import argparse
import io
import json
import re
import sys
import urllib.error
import urllib.request
import zipfile

API = "https://api.osv.dev/v1/querybatch"
DUMP = "https://storage.googleapis.com/osv-vulnerabilities/Pub/all.zip"
UA = "pdfreader-security-audit"


def parse_lock(text: str) -> list[tuple[str, str, str]]:
    """Returns (name, version, source) for every package in a pubspec.lock."""
    pkgs = []
    cur = None
    in_packages = False
    for line in text.splitlines():
        if line.startswith("packages:"):
            in_packages = True
            continue
        if in_packages and line and not line.startswith(" "):
            in_packages = False
        if not in_packages:
            continue
        m = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if m:
            cur = {"name": m.group(1)}
            pkgs.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r'^    (source|version):\s*"?([^"\s]+)"?\s*$', line)
        if m:
            cur[m.group(1)] = m.group(2)
    return [(p["name"], p.get("version", ""), p.get("source", "")) for p in pkgs]


# ---- semver (pub flavour) ---------------------------------------------------
def _key(v: str):
    v = v.split("+", 1)[0]
    main, _, pre = v.partition("-")
    nums = [int(x) if x.isdigit() else 0 for x in main.split(".")]
    while len(nums) < 3:
        nums.append(0)
    pre_key = ()
    if pre:
        pre_key = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    # A release sorts after all its pre-releases.
    return (tuple(nums), 0 if pre else 1, pre_key)


def _affected(version: str, affected: dict) -> bool:
    if version in (affected.get("versions") or []):
        return True
    k = _key(version)
    for rng in affected.get("ranges") or []:
        if rng.get("type") not in ("ECOSYSTEM", "SEMVER"):
            continue
        hit = False
        for ev in rng.get("events", []):
            if "introduced" in ev:
                intro = ev["introduced"]
                if intro == "0" or k >= _key(intro):
                    hit = True
            elif "fixed" in ev and k >= _key(ev["fixed"]):
                hit = False
            elif "last_affected" in ev and k > _key(ev["last_affected"]):
                hit = False
            elif "limit" in ev and k >= _key(ev["limit"]):
                hit = False
        if hit:
            return True
    return False


def _http(url: str, data: bytes | None = None, timeout: int = 60) -> bytes:
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (fixed https URLs)
        return r.read()


def check_api(pkgs):
    queries = [{"package": {"name": n, "ecosystem": "Pub"}, "version": v} for n, v, _ in pkgs]
    out = {}
    for i in range(0, len(queries), 500):
        chunk = queries[i:i + 500]
        res = json.loads(_http(API, json.dumps({"queries": chunk}).encode()))
        for q, r in zip(chunk, res.get("results", [])):
            ids = [v["id"] for v in r.get("vulns", [])]
            if ids:
                out[(q["package"]["name"], q["version"])] = ids
    return out, "api.osv.dev"


def check_dump(pkgs, zip_bytes: bytes):
    by_name: dict[str, list[tuple[str, dict]]] = {}
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        for f in z.namelist():
            if not f.endswith(".json"):
                continue
            rec = json.loads(z.read(f))
            if rec.get("withdrawn"):
                continue
            for aff in rec.get("affected", []):
                pkg = aff.get("package", {})
                if pkg.get("ecosystem") == "Pub":
                    by_name.setdefault(pkg.get("name"), []).append((rec["id"], aff))
    out = {}
    for n, v, _ in pkgs:
        ids = sorted({vid for vid, aff in by_name.get(n, []) if _affected(v, aff)})
        if ids:
            out[(n, v)] = ids
    return out, f"OSV Pub dump ({sum(len(x) for x in by_name.values())} advisories)"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("lockfile", nargs="?", default="pubspec.lock")
    ap.add_argument("--offline-db", help="path to a downloaded OSV Pub all.zip")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    try:
        with open(args.lockfile, encoding="utf-8") as f:
            all_pkgs = parse_lock(f.read())
    except OSError as e:
        print(f"osv_check: cannot read {args.lockfile}: {e}", file=sys.stderr)
        return 2
    # SDK packages (flutter, sky_engine, ...) are versioned with the Flutter SDK, not pub.
    pkgs = [(n, v, s) for n, v, s in all_pkgs if s in ("hosted", "git") and v]
    if not pkgs:
        print("osv_check: no hosted packages found in lockfile", file=sys.stderr)
        return 2

    try:
        if args.offline_db:
            with open(args.offline_db, "rb") as f:
                found, src = check_dump(pkgs, f.read())
        else:
            try:
                found, src = check_api(pkgs)
            except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
                print(f"osv_check: OSV API unreachable ({e}); falling back to the Pub dump", file=sys.stderr)
                found, src = check_dump(pkgs, _http(DUMP, timeout=120))
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, zipfile.BadZipFile) as e:
        print(f"osv_check: could not query OSV: {e}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps({"source": src, "checked": len(pkgs),
                          "vulnerable": [{"package": n, "version": v, "ids": ids}
                                         for (n, v), ids in sorted(found.items())]}, indent=2))
    else:
        print(f"OSV check via {src}: {len(pkgs)} hosted packages checked "
              f"({len(all_pkgs) - len(pkgs)} SDK packages skipped).")
        for (n, v), ids in sorted(found.items()):
            print(f"  VULNERABLE {n} {v}: {', '.join(ids)}")
        if not found:
            print("  No known vulnerabilities.")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
