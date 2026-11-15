#!/usr/bin/env python3
"""Classify the license of every package in pubspec.lock (dev tool, offline).

Reads LICENSE files from the local pub cache ($PUB_CACHE or ~/.pub-cache) and
the Flutter SDK for sdk packages. Flags copyleft and unknown licenses.
Usage: license_check.py [pubspec.lock] [--allow-unknown]
Exit: 0 all permissive, 1 non-permissive or unknown found, 2 setup error.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osv_check import parse_lock  # noqa: E402

PERMISSIVE = ["MIT", "BSD-3-Clause", "BSD-2-Clause", "Apache-2.0", "ISC", "Zlib", "Unlicense", "BSL-1.0"]
WEAK_COPYLEFT = ["MPL-2.0"]  # file-level copyleft: acceptable if unmodified, flagged for review
COPYLEFT = ["AGPL", "LGPL", "GPL"]


def classify(text: str) -> str:
    t = re.sub(r"\s+", " ", text)
    # MPL-2.0 text itself names the GPL family ("Secondary Licenses"): check it first.
    if re.search(r"Mozilla Public License,? (Version|v\.?) ?2\.0", t, re.I):
        return "MPL-2.0"
    if re.search(r"GNU AFFERO GENERAL PUBLIC LICENSE", t, re.I):
        return "AGPL"
    if re.search(r"GNU LESSER GENERAL PUBLIC LICENSE|GNU LIBRARY GENERAL PUBLIC", t, re.I):
        return "LGPL"
    if re.search(r"GNU GENERAL PUBLIC LICENSE", t, re.I):
        return "GPL"
    if re.search(r"Apache License,? Version 2\.0", t, re.I):
        return "Apache-2.0"
    if re.search(r"Permission is hereby granted, free of charge", t, re.I):
        return "MIT"
    if re.search(r"Redistribution and use in source and binary forms", t, re.I):
        return "BSD-3-Clause" if re.search(r"(names? of (its|the)? ?contributors|endorse or promote)", t, re.I) \
            else "BSD-2-Clause"
    if re.search(r"Permission to use, copy, modify, and/or distribute this software", t, re.I):
        return "ISC"
    if re.search(r"This software is provided 'as-is'", t, re.I):
        return "Zlib"
    if re.search(r"This is free and unencumbered software released into the public domain", t, re.I):
        return "Unlicense"
    if re.search(r"Boost Software License", t, re.I):
        return "BSL-1.0"
    return "UNKNOWN"


def license_text(pkg_dir: Path) -> str | None:
    for name in ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "LICENCE"):
        f = pkg_dir / name
        if f.is_file():
            return f.read_text(encoding="utf-8", errors="replace")
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("lockfile", nargs="?", default="pubspec.lock")
    ap.add_argument("--allow-unknown", action="store_true")
    args = ap.parse_args()

    cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache")) / "hosted" / "pub.dev"
    flutter_root = os.environ.get("FLUTTER_ROOT")
    pkgs = parse_lock(Path(args.lockfile).read_text(encoding="utf-8"))
    bad, review, unknown = [], [], []
    for name, version, source in pkgs:
        if source == "sdk":
            # Flutter SDK packages (flutter, flutter_test, sky_engine...) are BSD-3-Clause.
            lic = "BSD-3-Clause (Flutter SDK)"
            if flutter_root:
                for d in (Path(flutter_root) / "packages" / name, Path(flutter_root) / "bin" / "cache" / "pkg" / name):
                    txt = license_text(d)
                    if txt:
                        lic = classify(txt)
                        break
        else:
            txt = license_text(cache / f"{name}-{version}")
            lic = classify(txt) if txt else "MISSING (run flutter pub get)"
        mark = ""
        if any(lic.startswith(c) for c in COPYLEFT):
            bad.append(name)
            mark = "  <-- COPYLEFT"
        elif lic in WEAK_COPYLEFT:
            review.append(name)
            mark = "  <-- review (weak copyleft)"
        elif lic.startswith("UNKNOWN") or lic.startswith("MISSING"):
            unknown.append(name)
            mark = "  <-- unknown"
        print(f"{name:40} {version:16} {lic}{mark}")
    print(f"\n{len(pkgs)} packages: {len(bad)} copyleft, {len(review)} weak-copyleft, {len(unknown)} unknown.")
    if bad or (unknown and not args.allow_unknown):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
