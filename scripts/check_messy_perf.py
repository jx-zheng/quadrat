#!/usr/bin/env python3
"""Assert the messy-fixture perf report. Prints the numbers the gate checks."""
from __future__ import annotations

import json
import sys


def main() -> None:
    path = sys.argv[1]
    report = json.load(open(path))
    scan = report["scan"]
    print(f"hover p99 {report['hoverP99Ms']:.3f} ms n={report['hoverSamples']}")
    print(f"zoom p99 {report['zoomP99Ms']:.3f} ms n={report['zoomSamples']}")
    print(f"layout {report['layoutMs']:.3f} ms")
    print(
        f"footprint {report['peakRSSBytes']} resident {report['peakResidentBytes']} "
        f"items/s {scan['itemsPerSecond']:.0f}"
    )
    print(f"backing scale {report.get('backingScale')} hover draws {report.get('hoverDrawCount')}")
    assert report["hoverSamples"] >= 500
    assert report["hoverP99Ms"] < 4, "hover p99"
    assert report["zoomP99Ms"] < 16, "zoom p99"
    assert report["peakRSSBytes"] < 100 * 1024 * 1024, "footprint"
    assert scan["itemsPerSecond"] >= 250_000, "scan rate"
    assert report["layoutMs"] < 50, "layout"
    assert report["backingScale"] >= 2, "backing scale"
    assert report["hoverDrawCount"] == 0, "hover redrew tiles"


if __name__ == "__main__":
    main()
