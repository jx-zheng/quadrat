#!/usr/bin/env python3
"""Gates for the main --perf report: disk scan, and the real hover path."""
from __future__ import annotations

import json
import sys


def main() -> None:
    report = json.load(open(sys.argv[1]))
    peak = report["rootScan"]["peakRSSBytes"]
    resident = report["rootScan"]["peakResidentBytes"]
    rate = report["directoryScan"]["itemsPerSecond"]
    frames = report["frames"]
    unlabeled = report["rootLayout"]["unlabeled"]
    print(
        f"root footprint {peak} resident {resident}; directory items/s {rate:.0f}; "
        f"hover p99 {frames['hoverP99Ms']:.3f} n={frames['hoverSamples']} "
        f"scale {frames['backingScale']} draws {frames['hoverDrawCount']}"
    )
    assert peak < 100 * 1024 * 1024, "root footprint is over 100 MB"
    assert resident < 170 * 1024 * 1024, "root resident size regressed"
    assert rate >= 250000, "directory scan is slower than 250k items/s"
    assert frames["hoverSamples"] >= 500
    assert frames["hoverP99Ms"] < 4, "hover p99"
    assert frames["backingScale"] >= 2
    assert frames["hoverDrawCount"] == 0
    assert unlabeled == 0, "unlabeled tiles on the volume"


if __name__ == "__main__":
    main()
