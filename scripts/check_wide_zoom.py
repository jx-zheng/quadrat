#!/usr/bin/env python3
"""A home-shaped tree with wide directories must zoom in under 8 ms."""
from __future__ import annotations

import json
import sys


def main() -> None:
    report = json.load(open(sys.argv[1]))
    print(
        f"wide zoom p99 {report['zoomP99Ms']:.3f} ms n={report['zoomSamples']} "
        f"children {report['wideChildren']} dirs {report['wideDirectories']}"
    )
    assert report["wideChildren"] >= 50_000
    assert report["wideDirectories"] >= 2
    assert report["zoomSamples"] >= 20
    assert report["zoomP99Ms"] < 8, "wide zoom p99"
    assert report["backingScale"] >= 2
    assert report["hoverDrawCount"] == 0


if __name__ == "__main__":
    main()
